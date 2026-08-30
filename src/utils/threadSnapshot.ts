/**
 * 帖级快照（initialKnown）：列表→详情携带已知数据，帖子页首帧渲染
 * "已知主贴区 + 楼层骨架"，不等首包（iOS News/App Store 同款加载状态
 * 转场，2026-08-30 落地——见文章"加载过程=完整状态转场"）。
 *
 * 语义：点击卡片时写入完整 ThreadInfo；帖子页首次渲染消费一次即失效；
 * 60s TTL 防过期残留（深链/冷启无快照=走原整页骨架，行为不变）。
 */

import type { ThreadInfo } from '@/types';

let cached: { id: string; thread: ThreadInfo; at: number } | null = null;
const TTL_MS = 60 * 1000;

export function setThreadSnapshot(thread: ThreadInfo): void {
  const id = String(thread.id ?? '');
  if (!id) return;
  cached = { id, thread, at: Date.now() };
}

/** 帖子页首帧消费：id 匹配且未过期才返回，消费后立即失效（一次性）。 */
export function consumeThreadSnapshot(id: string): ThreadInfo | null {
  const c = cached;
  if (!c) return null;
  cached = null;
  if (c.id !== String(id)) return null;
  if (Date.now() - c.at > TTL_MS) return null;
  return c.thread;
}