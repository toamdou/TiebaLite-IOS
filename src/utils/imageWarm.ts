/**
 * imageWarm — 回收复用防闪（配合 LegendList recycleItems / expo-image recyclingKey）。
 *
 * expo-image 在 recyclingKey 变更（行被回收复用到别的贴子/条目）时会从占位符
 * 重新走 transition 过渡；滚动中多行同时回收复用，200ms fade 叠加成"一闪一闪"。
 * 这里在模块级记住本会话已成功加载过的 URI：首次加载保留过渡动画，之后
 * （回收复用、重进视口、冷图第二次出现）一律瞬时换图——保性能又不闪。
 */

const warmed = new Set<string>();
const WARM_CAP = 3000;

/** 该 URI 本会话已完成过至少一次加载（过渡动画不再需要） */
export function isImageWarm(uri: string): boolean {
  return warmed.has(uri);
}

/** 标记 URI 已完成加载（仅记录，无状态更新） */
export function markImageWarm(uri: string): void {
  // 防无限增长：超上限整体清空（后果仅是冷图会再 fade 一次，可接受）
  if (warmed.size >= WARM_CAP) warmed.clear();
  warmed.add(uri);
}