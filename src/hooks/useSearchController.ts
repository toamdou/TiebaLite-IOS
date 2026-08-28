/**
 * useSearchController — 全站搜索页状态机（综合/贴/吧/人 三桶 + 分页 + 竞态闸）
 *
 * 收敛搜索页全部结果状态与请求编排：
 * - threads/forums/users 三桶 + loading/error + 贴子分页（threadPage/threadHasMore/loadingMore）
 * - doSearch / loadMoreThreads / selectTab / commitKeyword / 请求序号 seq
 * - 竞态防护：
 *   1) searchSeqRef 序号闸：新搜索使旧响应作废（tab 切换/排序变更/换关键词）；
 *   2) loadingMoreRef 同步闸：loadMoreThreads 进入即置位、finally 复位，
 *      与 seq 检查并存——旧版用 loadingMore state 做闸，onEndReached 同帧双发时
 *      闭包里的 state 是旧的，两道请求都会穿过闸门（双发竞态）；
 *   3) threadPageRef 推进页码：loadMore 期间重渲染未落定的同帧续发，不会用
 *      过期 threadPage 重请求同一页。
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import {
  searchForum,
  searchThread,
  searchUser,
} from '@/services/api/endpoints/search';
import { SearchThreadOrder } from '@/types';
import type {
  SearchForumResult,
  SearchThreadResult,
  SearchUserResult,
} from '@/types';

export type SearchTab = 'thread' | 'forum' | 'user';

const MAX_SEARCH_RESULTS = 300;

export interface SearchControllerOptions {
  /** 关键词真正落地（通过重复搜索短路）后回调：页面在此重置建议/写历史 */
  onKeywordCommit?: (keyword: string) => void;
}

export function useSearchController(options: SearchControllerOptions = {}) {
  // 回调经 ref 转发，避免 hook 内部 useCallback 依赖页面回调身份；
  // 同步放 useEffect：不在渲染期写 ref（commitKeyword 只在事件回调里读，
  // effect 先于事件刷新，读到的一定是最新回调）
  const onKeywordCommitRef = useRef(options.onKeywordCommit);
  useEffect(() => {
    onKeywordCommitRef.current = options.onKeywordCommit;
  }, [options.onKeywordCommit]);

  const [activeTab, setActiveTab] = useState<SearchTab>('thread');
  const [sortOrder, setSortOrder] = useState<string>(String(SearchThreadOrder.NEW_FIRST));
  const [searchedKeyword, setSearchedKeyword] = useState('');
  const [hasSearched, setHasSearched] = useState(false);

  // 搜索结果（按 tab 分桶）
  const [threads, setThreads] = useState<SearchThreadResult[]>([]);
  const [forums, setForums] = useState<SearchForumResult[]>([]);
  const [users, setUsers] = useState<SearchUserResult[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  // 贴子分页
  const [threadHasMore, setThreadHasMore] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);

  // ── 竞态闸 ──
  /** 请求序号：每次 doSearch 自增，响应回来时序号不符即丢弃（旧搜索作废新搜索） */
  const searchSeqRef = useRef(0);
  /** loadMore 同步闸：进入即 true、finally 复位（杜绝 onEndReached 同帧双发） */
  const loadingMoreRef = useRef(false);
  /** 已加载到的页码（同步推进，避免 state 闭包过期导致同页重请求） */
  const threadPageRef = useRef(1);
  /** 每个 tab 是否已为当前关键词搜过（pager 滑到未搜过的 tab 才发起请求）；懒初始化 */
  const searchedTabsRef = useRef<Set<SearchTab> | null>(null);
  if (searchedTabsRef.current === null) {
    searchedTabsRef.current = new Set(['thread']);
  }

  const doSearch = useCallback(
    async (kw: string, tab: SearchTab, orderOverride?: number) => {
      const seq = ++searchSeqRef.current;
      // 新搜索作废任何在途 loadMore
      loadingMoreRef.current = false;
      setLoadingMore(false);
      setLoading(true);
      setError('');
      // 先让 loading=true 提交一帧：本地缓存/极快响应时 React 会把
      // setLoading(true) 与 finally 的 setLoading(false) 合并，骨架屏永不出现
      await new Promise((r) => setTimeout(r, 0));
      try {
        if (tab === 'thread') {
          const res = await searchThread(kw, 1, orderOverride ?? parseInt(sortOrder, 10));
          if (seq !== searchSeqRef.current) return;
          threadPageRef.current = 1;
          setThreads(res.items.slice(0, MAX_SEARCH_RESULTS));
          setThreadHasMore(res.hasMore);
        } else if (tab === 'forum') {
          const res = await searchForum(kw);
          if (seq !== searchSeqRef.current) return;
          setForums(res);
        } else {
          const res = await searchUser(kw);
          if (seq !== searchSeqRef.current) return;
          setUsers(res);
        }
        searchedTabsRef.current!.add(tab);
      } catch (e: unknown) {
        if (seq !== searchSeqRef.current) return;
        setError(e instanceof Error ? e.message : '搜索失败');
      } finally {
        if (seq !== searchSeqRef.current) return;
        setLoading(false);
      }
    },
    [sortOrder],
  );

  /** 贴子加载更多（ref 同步闸 + seq 检查并存） */
  const loadMoreThreads = useCallback(async () => {
    if (!threadHasMore || loadingMoreRef.current || loading || !searchedKeyword) return;
    const seq = searchSeqRef.current;
    loadingMoreRef.current = true;
    setLoadingMore(true);
    try {
      const nextPage = threadPageRef.current + 1;
      const res = await searchThread(searchedKeyword, nextPage, parseInt(sortOrder, 10));
      if (seq !== searchSeqRef.current) return;
      threadPageRef.current = nextPage;
      setThreads((prev) => [...prev, ...res.items].slice(-MAX_SEARCH_RESULTS));
      setThreadHasMore(res.hasMore);
    } catch {
      // 静默失败，保留已有结果
    } finally {
      // 仅当仍是当前代次才复位闸：过期请求的 finally 不得清掉在途新请求持有的锁
      //（否则第三个 loadMore 可在第二个仍在途时穿透闸门，与它请求同一页）。
      if (seq === searchSeqRef.current) {
        loadingMoreRef.current = false;
        setLoadingMore(false);
      }
    }
  }, [threadHasMore, loading, searchedKeyword, sortOrder]);

  /**
   * 关键词落地：三桶全清（旧关键词数据作废），当前 tab 立即搜。
   * 同关键词重复搜索短路（保留排序变更路径——排序走 doSearch 不经此处）。
   */
  const commitKeyword = useCallback(
    (kw: string, tab: SearchTab) => {
      const trimmed = kw.trim();
      if (!trimmed) return;
      if (trimmed === searchedKeyword && hasSearched) return;
      onKeywordCommitRef.current?.(trimmed);
      searchedTabsRef.current = new Set([tab]);
      setThreads([]);
      setForums([]);
      setUsers([]);
      setSearchedKeyword(trimmed);
      setHasSearched(true);
      doSearch(trimmed, tab);
    },
    [searchedKeyword, hasSearched, doSearch],
  );

  /** segment 点击 / pager 滑动共用：切 tab，未搜过的 tab 补搜 */
  const selectTab = useCallback(
    (tab: SearchTab) => {
      setActiveTab(tab);
      if (searchedKeyword && !searchedTabsRef.current!.has(tab)) {
        doSearch(searchedKeyword, tab);
      }
    },
    [searchedKeyword, doSearch],
  );

  /** 搜索页取消（未出结果分支）：清空结果与在途请求，回到搜索前状态 */
  const resetForCancel = useCallback(() => {
    searchSeqRef.current += 1; // 作废在途请求，防迟到响应回填空桶
    loadingMoreRef.current = false;
    setLoadingMore(false);
    setLoading(false);
    setError('');
    searchedTabsRef.current = new Set(['thread']);
    setThreads([]);
    setForums([]);
    setUsers([]);
    setSearchedKeyword('');
    setHasSearched(false);
  }, []);

  return {
    // tab / 排序 / 关键词
    activeTab,
    sortOrder,
    setSortOrder,
    searchedKeyword,
    hasSearched,
    // 结果三桶 + 加载态
    threads,
    forums,
    users,
    loading,
    error,
    threadHasMore,
    loadingMore,
    /** 搜索卡乐观点赞直接写桶（TweetCard 化的贴结果卡用） */
    setThreads,
    // 动作
    doSearch,
    loadMoreThreads,
    commitKeyword,
    selectTab,
    resetForCancel,
  };
}