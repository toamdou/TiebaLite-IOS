// ============================================================
// Favorite images snapshot (本地快照)
//
// 服务端 store_list（threadstore）不返回帖子图片，收藏列表要显示缩略图
// 只能靠本地快照：用户在某帖点「收藏」时，把该帖正文解析出的图片 URL
// 落到 unified kv（tid → images），收藏列表渲染时合并显示；取消收藏时
// 一并清理。图片本体仍走 expo-image / TiebaImageIO 缓存，这里只存 URL。
// ============================================================

import { kvGet, kvSet } from '@/services/storage/unifiedDb';

const FAV_IMAGES_KEY = '@tiebalite:favorite_images_v1';
// kv 表启动时全量载入内存：快照只近似保留最近 200 个收藏帖的图片 URL
// （键序有界，不严格按收藏时间排序，见 saveFavoriteImages 注释），
// 防止收藏数长期累积把 kv 值撑成几百 KB 的常驻内存。
const MAX_FAV_ENTRIES = 200;

type FavImagesMap = Record<string, string[]>;

export async function getFavoriteImagesMap(): Promise<FavImagesMap> {
  try {
    const raw = await kvGet(FAV_IMAGES_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw) as Record<string, unknown>;
    const result: FavImagesMap = {};
    for (const [tid, value] of Object.entries(parsed)) {
      if (Array.isArray(value)) result[tid] = value.filter((v) => typeof v === 'string') as string[];
    }
    return result;
  } catch {
    return {};
  }
}

export async function saveFavoriteImages(tid: string, images: string[]): Promise<void> {
  const clean = (images ?? []).filter(Boolean).slice(0, 6);
  if (clean.length === 0) return;
  try {
    const map = await getFavoriteImagesMap();
    map[String(tid)] = clean;
    // 超限时按键序淘汰最早写入的键：键序只保证容量有界，不保证严格按
    // 收藏时间排序——语义精确表述为「近似最近 N 帖」（纯数字 tid 按整数
    // 序、其余按插入序，均为确定序，容量语义至此成立）
    const keys = Object.keys(map);
    if (keys.length > MAX_FAV_ENTRIES) {
      for (const key of keys.slice(0, keys.length - MAX_FAV_ENTRIES)) delete map[key];
    }
    await kvSet(FAV_IMAGES_KEY, JSON.stringify(map));
  } catch {
    // 快照失败不影响收藏本身
  }
}

export async function removeFavoriteImages(tid: string): Promise<void> {
  try {
    const map = await getFavoriteImagesMap();
    if (!(String(tid) in map)) return;
    delete map[String(tid)];
    await kvSet(FAV_IMAGES_KEY, JSON.stringify(map));
  } catch {
    // 清理失败静默
  }
}

/** 从帖子 content runs 里抽取图片 URL（与 PostContent/subposts 同源逻辑）。 */
export function imagesFromContent(content: unknown[] | null | undefined): string[] {
  if (!Array.isArray(content)) return [];
  const runs = content as Array<{ type?: string; src?: string; cdnSrc?: string } | null | undefined>;
  return runs
    .filter((c) => !!c && c.type === 'image')
    .map((c) => c!.src || c!.cdnSrc || '')
    .filter(Boolean);
}
