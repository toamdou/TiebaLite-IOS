import { useEffect, useState } from 'react';
import { TiebaNative } from '../../modules/tieba-native/src/TiebaNative';
import { sanitizeUrl } from '@/utils';

const pendingThumbnails = new Map<string, Promise<string>>();
const TIEBA_REFERER = 'https://tieba.baidu.com/';

/**
 * Resolve a remote image through native ImageIO downsampling once per source
 * URI. The local JPEG is cached by TiebaImageIO and reused on later visits.
 * 入参统一升级为 https（ATS 禁止明文 HTTP，native URLSession 同样受约束）。
 *
 * enabled=false 时不发起原生下载/解码（大图查看器缩略条窗口化：仅当前±1 格
 * 显示缩略图，非激活格挂载即拉原图是纯浪费——翻页激活后 effect 重跑自动补拉）。
 */
export function useNativeThumbnail(
  sourceUri: string,
  width = 56,
  height = 56,
  enabled = true,
): string {
  const [uri, setUri] = useState('');

  useEffect(() => {
    if (!sourceUri || !enabled) return;
    let cancelled = false;
    const safeUri = sanitizeUrl(sourceUri);
    // 并发去重键含目标尺寸：同一源图按不同尺寸降采样结果不可互换，
    // 各自持有独立 Promise（此前仅按 URI 去重会串尺寸）。
    const dedupKey = `${safeUri}@${width}x${height}`;

    let promise = pendingThumbnails.get(dedupKey);
    if (!promise) {
      promise = TiebaNative.makeThumbnail(
        safeUri,
        width,
        height,
        safeUri,
        TIEBA_REFERER,
      ).then((result) => {
        // 成功路径也释放条目：Map 只做并发去重，不驻留已完成 promise（原生侧已有磁盘缓存）
        pendingThumbnails.delete(dedupKey);
        return result;
      }).catch((error: unknown) => {
        pendingThumbnails.delete(dedupKey);
        if (__DEV__) {
          console.warn(
            '[TiebaImageIO] thumbnail failed:',
            error instanceof Error ? error.message : String(error),
          );
        }
        // Keep the thumbnail usable when the native downloader is offline.
        return safeUri;
      });
      if (pendingThumbnails.size >= 256) {
        const oldest = pendingThumbnails.keys().next().value;
        if (oldest) pendingThumbnails.delete(oldest);
      }
      pendingThumbnails.set(dedupKey, promise);
    }

    promise.then((result) => {
      if (!cancelled) setUri(result);
    });
    return () => {
      cancelled = true;
    };
  }, [sourceUri, width, height, enabled]);

  return uri;
}
