/**
 * useSearchHistory — 搜索历史状态机（thermo 2026-08-26 Z5-B：收敛
 * 全站搜索页与吧内搜索页两份逐行同构的 load/append/remove/clear 样板）。
 *
 * - forumId 缺省 = 全站维度（storage 层同键空间）；传入即吧内维度；
 * - save() 自动 trim、空关键词短路，返回最新列表（storage 返回权威序列）；
 * - 失败一律 console.warn 不抛出（历史属 best-effort 数据）。
 */

import { useCallback, useEffect, useState } from 'react';

import {
  appendSearchHistory,
  clearSearchHistory,
  loadSearchHistory,
  removeSearchHistory,
  type SearchHistoryItem,
} from '@/storage/searchHistory';

export function useSearchHistory(forumId?: string, max: number = 20) {
  const [history, setHistory] = useState<SearchHistoryItem[]>([]);

  useEffect(() => {
    let mounted = true;
    loadSearchHistory(forumId, max)
      .then((items) => {
        if (mounted) setHistory(items);
      })
      .catch((e: unknown) => {
        console.warn('[searchHistory] load failed:', e);
      });
    return () => {
      mounted = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- max 由调用方常量传入
  }, [forumId]);

  const save = useCallback(
    async (kw: string) => {
      const trimmed = kw.trim();
      if (!trimmed) return;
      try {
        setHistory(await appendSearchHistory(trimmed, forumId, max));
      } catch (e: unknown) {
        console.warn('[searchHistory] append failed:', e);
      }
    },
    [forumId, max],
  );

  const clear = useCallback(async () => {
    setHistory([]);
    try {
      await clearSearchHistory(forumId);
    } catch (e: unknown) {
      console.warn('[searchHistory] clear failed:', e);
    }
  }, [forumId]);

  const remove = useCallback(
    async (kw: string) => {
      try {
        setHistory(await removeSearchHistory(kw, forumId));
      } catch (e: unknown) {
        console.warn('[searchHistory] remove failed:', e);
      }
    },
    [forumId],
  );

  return { history, save, clear, remove };
}
