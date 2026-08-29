/**
 * imageWarm — 回收复用防闪（配合 LegendList recycleItems / expo-image recyclingKey）。
 *
 * expo-image 在 recyclingKey 变更（行被回收复用到别的贴子/条目）时会从占位符
 * 重新走 transition 过渡；滚动中多行同时回收复用，200ms fade 叠加成"一闪一闪"。
 * 这里在模块级记住本会话已成功加载过的 URI：首次加载保留过渡动画，之后
 * （回收复用、重进视口、冷图第二次出现）一律瞬时换图——保性能又不闪。
 *
 * 时间窗（2026-08-29 beta 增强）：expo-image 内存缓存上限仅 8-32MB（LRU 淘汰），
 * 久远的"已加载"URI 缓存可能已被逐出——若仍判热瞬时替换，会走"旧图→占位→新图"
 * 两跳反而更闪。窗口内（刚加载过，内存缓存大概率仍在）= 真瞬时；窗口外 = 退回
 * 200ms 柔和淡入（磁盘缓存命中，淡入可接受）。120s 覆盖滑动往返的全部回看场景。
 * 内存账：上限 3000 条 × (URI ~80B + 时间戳 8B + Map 开销 ~64B) ≈ 450KB 峰值。
 */

const warmed = new Map<string, number>();
const WARM_CAP = 3000;
const WARM_WINDOW_MS = 120_000;

/** 该 URI 在时间窗内完成过加载（过渡动画不再需要） */
export function isImageWarm(uri: string): boolean {
  const loadedAt = warmed.get(uri);
  return loadedAt !== undefined && Date.now() - loadedAt < WARM_WINDOW_MS;
}

/** 标记 URI 已完成加载（仅记录，无状态更新） */
export function markImageWarm(uri: string): void {
  // 防无限增长：超上限整体清空（后果仅是冷图会再 fade 一次，可接受）
  if (warmed.size >= WARM_CAP) warmed.clear();
  warmed.set(uri, Date.now());
}