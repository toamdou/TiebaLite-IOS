// ============================================================
// 缓存维护：最大缓存大小 + 定期自动清理
//
// 两处缓存都在 Library/Caches/（系统可回收）：
// - expo-image（SDWebImage）：磁盘上限由 maxDiskSize 控制；
// - 原生缩略图（TiebaImageIO）：磁盘上限由 setThumbnailCacheLimit 控制。
// 定期清理按"距上次清理 ≥ N 天"在启动时执行一次（0 = 关闭），
// 只清图片缓存，不动历史头像引用与任何用户数据。
// ============================================================

import { Image } from 'expo-image';
import { Directory, Paths } from 'expo-file-system';
import { TiebaNative } from '../../../modules/tieba-native/src/TiebaNative';
import { kvGetSync, kvSetSync } from '@/services/storage/unifiedDb';
import { usePreferencesStore } from '@/stores/preferencesStore';

const LAST_AUTO_CLEAN_KEY = '@tiebalite:cache_auto_clean_at';

/** 尽力而为执行器：吞掉一切异常并返回 undefined（缓存清理全部 best-effort）。
 *  同时兼容同步操作（如 Directory.delete）。 */
export async function safe<T>(operation: () => T | Promise<T>): Promise<T | undefined> {
  try {
    return await operation();
  } catch {
    return undefined;
  }
}

/** 设置 → 最大缓存大小：同步套用 expo-image 磁盘/内存上限 + 原生缩略图上限。
*  磁盘缓存为用户可调档位（默认 400MB，存图片文件，不占 RAM）；
 *  内存缓存是解码后的位图，直接吃 RAM，必须与磁盘解耦并压低——
 *  首屏 feed 解码峰值曾把进程推到 500MB+（macOS/iOS 都按"脏字节"记账，
 *  真机上会被 jetsam 警告）。按磁盘档位的 1/16 取 8–32MB：
 *  32MB 大约够 8–12 张 3x 屏宽图的解码量，配合滚动逐出足够顺滑。 */
export function applyCacheMaxSize(mb: number): void {
  const safeMb = Math.max(0, Math.floor(mb) || 0);
  const bytes = safeMb * 1024 * 1024;
  try {
    Image.configureCache({
      maxDiskSize: bytes,
      maxMemoryCost: Math.min(32, Math.max(8, Math.round(safeMb / 16))) * 1024 * 1024,
    });
  } catch {
    // configureCache 仅 iOS 实现，其他平台静默忽略
  }
  try {
    TiebaNative.setThumbnailCacheLimit(bytes);
  } catch {
    // 原生旧构建可能没有该方法
  }
}

/** 仅清理图片类缓存（手动按钮与自动清理共用；不动历史头像/数据/登录态）。
 *  全部子步骤 best-effort，永不抛错——调用方无需再包 try/catch。
 *  重叠清理收敛：expo-image（SDWebImage）磁盘缓存位于 Paths.cache 下，被下方
 *  目录删除覆盖，不再单独调 Image.clearDiskCache()（避免重复 IO）。内存位图
 *  缓存不在磁盘路径上，必须保留 clearMemoryCache()。 */
export async function clearImageCaches(): Promise<void> {
  await safe(() => Image.clearMemoryCache());
  // Paths.cache 下只有图片/临时媒体文件，删除即全清（含 NSURLCache、expo-image
  // SDWebImage 磁盘缓存、TiebaImageIO 缩略图文件）
  await safe(() => new Directory(Paths.cache).delete());
  // 原生缩略图缓存文件同样位于 Paths.cache 下（已被目录删除覆盖）；
  // 保留调用：原生侧可能维护 JS 不可见的内部状态（索引/统计），防御性二次清理。
  await safe(() => TiebaNative.clearThumbnailCache());
}

/** 启动时调用：开启定期清理（>0 天）且距上次清理超期时自动清一次。永不抛错。 */
export async function maybeAutoCleanCache(): Promise<void> {
  const days = usePreferencesStore.getState().preferences.cacheAutoCleanDays ?? 0;
  if (days <= 0) return;
  const last = Number(kvGetSync(LAST_AUTO_CLEAN_KEY) ?? 0) || 0;
  if (last > 0 && Date.now() - last < days * 86400000) return;
  await clearImageCaches();
  kvSetSync(LAST_AUTO_CLEAN_KEY, String(Date.now()));
}