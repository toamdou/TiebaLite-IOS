// ============================================================
// blockFilterSync — shared in-memory cache for blocked words/users.
//
// PostContent and thread lists subscribe to one snapshot instead of
// every row calling BlockManager/unified storage independently.
// ============================================================

import type { BlockedWord, BlockedUser } from '@/types';
import { BlockManager } from './BlockManager';
import { subscribeBlockEvents } from './blockEvents';

export interface BlockFilterSnapshot {
  loaded: boolean;
  blockedWords: BlockedWord[];
  blockedUsers: BlockedUser[];
}

let snapshot: BlockFilterSnapshot = {
  loaded: false,
  blockedWords: [],
  blockedUsers: [],
};
let refreshPromise: Promise<void> | null = null;
const listeners = new Set<() => void>();

function emit(): void {
  for (const listener of listeners) listener();
}

export function getBlockFilterSnapshot(): BlockFilterSnapshot {
  return snapshot;
}

export function subscribeBlockFilter(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** Reload the shared cache at most once per event burst. */
export async function refreshBlockFilter(): Promise<void> {
  if (refreshPromise) return refreshPromise;
  refreshPromise = (async () => {
    // dirty 循环（最多 2 轮）：单轮读完后若期间又发生写入，本次读取的数组
    // 引用与当前缓存引用不等——而该次写入触发的 refreshBlockFilter 会被
    // refreshPromise 去重吞掉，直接收敛会丢更新。比较引用决定是否再跑一轮，
    // 第 2 轮无论结果如何都收敛（防死循环）。
    for (let round = 0; round < 2; round++) {
      const [words, users] = await Promise.all([
        BlockManager.getBlockedWordsSnapshot(),
        BlockManager.getBlockedUsersSnapshot(),
      ]);
      snapshot = { loaded: true, blockedWords: words, blockedUsers: users };
      const [latestWords, latestUsers] = await Promise.all([
        BlockManager.getBlockedWordsSnapshot(),
        BlockManager.getBlockedUsersSnapshot(),
      ]);
      if (latestWords === words && latestUsers === users) break;
    }
    emit();
  })().finally(() => {
    refreshPromise = null;
  });
  return refreshPromise;
}

// One global listener for every write made through BlockManager.
subscribeBlockEvents(() => {
  refreshBlockFilter();
});
