import { Image } from 'expo-image';
import { thumbnailUrl, THUMB_CARD } from '@/utils/thumbnail';

/**
 * 媒体总线可见性 key：楼层内容段里的视频/音频 src 在帖内唯一，
 * 与 ActiveVideo（v:）/ ActiveAudio（a:）注册的总线 key 一致。
 */
export function mediaKeysOf(content: { type: string; src?: string }[]): string[] {
  const keys: string[] = [];
  for (const seg of content) {
    if (seg.type === 'video' || seg.type === 'audio') {
      if (seg.src) keys.push(`${seg.type === 'video' ? 'v' : 'a'}:${seg.src}`);
    }
  }
  return keys;
}

/** 从信息流项提取缩略图源（与 TweetCard 的 images 提取一致） */
export function threadThumbs(t: { mediaList?: { type: string; src?: string; originSrc?: string }[] }): string[] {
  return (t.mediaList ?? [])
    .filter((m) => m.type === 'image' && (m.src || m.originSrc))
    .map((m) => m.originSrc || m.src || '')
    .filter(Boolean);
}

/**
 * 视口尾预取：列表滚动时对「当前可见尾之后 count 条」的缩略图发起
 * prefetch，滚动到页尾时首图基本无等待。按数据数组引用（WeakMap）记录
 * 已预取到的尾下标：viewability 回调在快速滑动时高频触发，只处理增量
 * 尾部（上滑/原地触发直接短路），count 内已预取过的 URL 由 expo-image
 * 内部去重（低开销）。下拉刷新换新数组 → 新 WeakMap 键自动全量重来。
 *
 * 内存：cachePolicy 必须 'disk'——贴吧 CDN 缩略图即 ~960px 原图
 *（thumbnailUrl 已无尺寸注入），默认 memory-disk 会把每次滚动 6 张
 * 全尺寸解码图灌进 25MB 内存缓存（浏览循环内存爬升主因）；只落盘则
 * 滚到再显示时才解码进内存，缓存压力大幅下降。
 */
const lastPrefetchedTail = new WeakMap<object[], number>();

export function prefetchNextThreads<T>(
  data: T[],
  tailIndex: number,
  extractThumbs: (item: T) => string[],
  count = 6,
): void {
  if (tailIndex < 0 || data.length === 0) return;
  const prevTail = lastPrefetchedTail.get(data as object[]) ?? -1;
  if (tailIndex <= prevTail) return;
  // 先推进游标再处理：快速滑动中回调连发时不会对同一区间重复入队；
  // 从 prevTail+1 起步覆盖跳跃式前进的区间缺口。
  lastPrefetchedTail.set(data as object[], tailIndex);
  const end = Math.min(tailIndex + count, data.length - 1);
  for (let i = prevTail + 1; i <= end; i++) {
    for (const origin of extractThumbs(data[i])) {
      const thumb = origin ? thumbnailUrl(origin, THUMB_CARD) : '';
      if (thumb) Image.prefetch(thumb, { cachePolicy: 'disk' });
    }
  }
}