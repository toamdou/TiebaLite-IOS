import { useCallback, useEffect, useSyncExternalStore } from 'react';
import type { PostContent } from '@/types';
import { BlockManager } from '@/utils/BlockManager';
import { contentToText } from '@/utils';
import {
  getBlockFilterSnapshot,
  refreshBlockFilter,
  subscribeBlockFilter,
} from '@/utils/blockFilterSync';

export function useBlockFilter() {
  const { blockedWords, blockedUsers } = useSyncExternalStore(
    subscribeBlockFilter,
    getBlockFilterSnapshot,
  );

  useEffect(() => {
    refreshBlockFilter().catch(() => {});
  }, []);

  // 保留导出（无当前消费方，grep 确认）——后续若需要"手动刷新屏蔽词"入口可直接用；
  // 日常增量更新已由 blockFilterSync 的全局订阅覆盖。
  const refresh = useCallback(() => refreshBlockFilter(), []);

  const filterPosts = useCallback(
    <T extends { content?: PostContent[] | string; authorId?: string; authorName?: string }>(
      posts: T[],
    ): T[] => {
      if (blockedWords.length === 0 && blockedUsers.length === 0) return posts;
      return posts.filter((post) => {
        const contentText = contentToText(post.content);
        if (BlockManager.shouldBlockContent(contentText, blockedWords)) return false;
        if (post.authorId && BlockManager.shouldBlockUser(post.authorId, post.authorName || null, blockedUsers)) return false;
        return true;
      });
    },
    [blockedWords, blockedUsers],
  );

  /** Check if a single content element (text/emoji) is blocked. Aligns with Kotlin BlockableContent. */
  const isContentBlocked = useCallback(
    // 收窄为 PostContent 段或字符串（字符串保留接收：部分调用方直接传文本）。
    (contentItem: PostContent | string | null | undefined): boolean => {
      if (blockedWords.length === 0) return false;
      if (typeof contentItem === 'string') {
        if (!contentItem) return false;
        return BlockManager.shouldBlockContent(contentItem, blockedWords);
      }
      // 非文本段（image/video/audio/linebreak/poll 等）无 text，直接放行
      if (!contentItem || !('text' in contentItem) || !contentItem.text) return false;
      return BlockManager.shouldBlockContent(contentItem.text, blockedWords);
    },
    [blockedWords],
  );

  return {
    blockedWords,
    blockedUsers,
    filterPosts,
    isContentBlocked,
    refresh,
  };
}
