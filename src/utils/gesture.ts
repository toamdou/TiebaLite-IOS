import type { GestureResponderEvent } from 'react-native';

/**
 * 事件冒泡阻断：子元素按压不触发整卡（Pressable 祖先）的按压态/点击。
 * 全应用统一实现（TweetCard / CompactFeedRow 共用；此前的本地副本形态各异，
 * 有的写 stop(e: any)、有的写 stopPropagation，语义相同 —— 见
 * 全量审查 #17）。参数可空安全跳过。
 */
export function stopPropagation(e?: GestureResponderEvent | null): void {
  e?.stopPropagation?.();
}