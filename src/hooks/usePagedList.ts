/**
 * Shared paged-list state machine.
 *
 * Handles items/page/hasMore/loading states, request sequencing and a hard
 * cap on retained rows so long pagination cannot grow memory forever.
 *
 * State semantics (consumed by tabs cluster):
 * - `loading`    — true while an 'initial'/'jump' mode run is in flight.
 * - `refreshing` — true only while a 'refresh' (pull-to-refresh) run is
 *                  in flight; used to drive RefreshControl.spinner. It is
 *                  cleared when the latest run settles, even if an earlier
 *                  refresh was superseded (seq guard).
 * - `loadingMore` — true while a 'more' (pagination) run is in flight.
 * - `error`      — set only when the very first page fails (stale errors
 *                  after partial data are dropped).
 *
 * Cancellation is instance-scoped: each hook owns its AbortController and
 * passes `signal` to the fetcher explicitly. The module-global
 * `activeRequestSignal` (client.ts) is intentionally NOT used here — it is
 * shared across hook instances and causes cross-instance signal races.
 */

import {
  useCallback,
  useEffect,
  useRef,
  useState,
  type Dispatch,
  type SetStateAction,
} from 'react';

export interface PagedResult<T, E = any> {
  items: T[];
  hasMore: boolean;
  nextPage?: number;
  extra?: E;
}

export interface UsePagedListOptions<T, P, E> {
  fetcher: (page: number, params: P, signal?: AbortSignal) => Promise<PagedResult<T, E>>;
  params?: P;
  initialPage?: number;
  maxItems?: number;
  /** 首屏 seed（SWR 快照/预热缓存）：仅用于 useState 初值，网络首屏返回后整体替换。 */
  initialItems?: T[];
}

export interface PagedList<T, P = undefined, E = any> {
  items: T[];
  page: number;
  hasMore: boolean;
  loading: boolean;
  refreshing: boolean;
  loadingMore: boolean;
  error: string | null;
  extra: E | null;
  load: (page?: number, params?: P, mode?: 'initial' | 'refresh' | 'jump' | 'more') => Promise<void>;
  refresh: () => Promise<void>;
  loadMore: () => Promise<void>;
  reset: () => void;
  setItems: Dispatch<SetStateAction<T[]>>;
  setExtra: Dispatch<SetStateAction<E | null>>;
}

export function usePagedList<T, P = undefined, E = any>({
  fetcher,
  params,
  initialPage = 1,
  // 列表驻留上限：按页容量（~30-50/页）折算，保留约 4-6 页即可，
  // 避免长分页把 JS 内存无限撑大（原 400 条过高）。
  maxItems = 200,
  initialItems,
}: UsePagedListOptions<T, P, E>): PagedList<T, P, E> {
  const [items, setItems] = useState<T[]>(initialItems ?? []);
  const [page, setPage] = useState(initialPage);
  const [hasMore, setHasMore] = useState(true);
  // 有 seed 时首帧直接渲染内容，不闪骨架屏；网络首屏返回后沿用原替换路径。
  const [loading, setLoading] = useState(initialItems === undefined);
  const [refreshing, setRefreshing] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [extra, setExtra] = useState<E | null>(null);
  const seqRef = useRef(0);
  const controllerRef = useRef<AbortController | null>(null);
  // 同步镜像 state 的 ref，供 loadMore 入口做同步守卫：
  // loadingMore 经 setState 异步生效，LegendList 同帧二次 onEndReached 时
  // 闭包里的 loadingMore 仍是旧值，导致同页重复发起 run(page, 'more')。
  const loadingMoreRef = useRef(false);
  // hasMore 同镜像：onEndReached 在贴底时会反复触发，仅靠 state 里的 hasMore
  // 异步生效，翻到底之后仍会继续发请求（thread 页曾有 8 连发 pb/page 风暴，
  // 越界页回吐重复楼层把 LegendList 键冲突渲染成全屏灰）。
  const hasMoreRef = useRef(true);
  // 冷却守卫：一批加载完成后留出短暂安静期（~900ms），期间即使 onEndReached
  // 因内容变化/贴底悬停再次触发也忽略——避免"加载一批立刻又连发一批"的无停顿
  // 刷页。用户稍作滚动（离开底部）后再接近底部时自然命中下一批。
  const lastLoadMoreAtRef = useRef(0);
  const LOAD_MORE_COOLDOWN_MS = 900;
  const pageRef = useRef(initialPage);
  const paramsRef = useRef(params);
  // items 的同步镜像（供分批 append 规划用；功能上仍以 setItems 函数式去重为准）
  const itemsRef = useRef<T[]>(initialItems ?? []);
  useEffect(() => {
    itemsRef.current = items;
  }, [items]);
  useEffect(() => {
    paramsRef.current = params;
  }, [params]);
  // fetcher 也走 ref：调用方传内联箭头时（每渲染新身份），run 的 useCallback
  // 依赖不含 fetcher 就不重建 → 页面 useEffect([load]) 不会反复触发 →
  // 杜绝"同一请求 abort+重发"的请求风暴（thread/[id] 曾因此每秒发 10+ 次）。
  const fetcherRef = useRef(fetcher);
  useEffect(() => {
    fetcherRef.current = fetcher;
  }, [fetcher]);

  const run = useCallback(
    async (targetPage: number, mode: 'initial' | 'refresh' | 'more' | 'jump', overrideParams?: P) => {
      const seq = ++seqRef.current;
      controllerRef.current?.abort();
      const controller = new AbortController();
      controllerRef.current = controller;
      // 取消信号按实例管理：每个 usePagedList 实例持有自己的 AbortController，
      // 不再向模块级全局 activeRequestSignal 写入（原实现跨实例共享，
      // 两个列表并发时会互相覆盖/回滚对方的 signal）。
      // 页面 fetcher 均显式接收 signal，全局回退机制对本集群已无用途。
      if (mode === 'refresh') setRefreshing(true);
      else if (mode === 'initial') setLoading(true);
      else {
        setLoadingMore(true);
        loadingMoreRef.current = true;
      }
      setError(null);
      try {
        const result = await fetcherRef.current(
          targetPage,
          overrideParams ?? paramsRef.current as P,
          controller.signal,
        );
        if (seq !== seqRef.current) return;
        if (mode === 'more') {
          // 按 id 去重：越界翻页时服务端会回吐与既有列表重复的楼层，重复
          // key 会让 LegendList 虚拟化错乱并渲染成全屏灰。无 id 的项不去重。
          const idOf = (it: any) => {
            const id = it?.id;
            return id === undefined || id === null ? null : String(id);
          };
          const seen = new Set(itemsRef.current.map(idOf).filter(Boolean) as string[]);
          const appended = result.items.filter((it: any) => {
            const key = idOf(it);
            if (key === null) return true;
            if (seen.has(key)) return false;
            seen.add(key);
            return true;
          });
          // 分批 append（2026-08-29）：整页一次 setItems 会合成一次大 commit
          //（滚动中连续掉帧的元凶之一）。按帧分片插入，摊平渲染峰值；
          // seq 守卫保证中途被 refresh/reset/new run 抢占时停止追加。
          const APPEND_CHUNK = 8;
          if (appended.length <= APPEND_CHUNK) {
            setItems((prev) => {
              const seenAll = new Set(prev.map(idOf).filter(Boolean) as string[]);
              const merged = [...prev, ...appended.filter((it: any) => {
                const key = idOf(it);
                return key === null || !seenAll.has(key);
              })];
              return merged.slice(-maxItems);
            });
          } else {
            let offset = 0;
            const appendChunk = () => {
              if (seq !== seqRef.current) return;
              const slice = appended.slice(offset, offset + APPEND_CHUNK);
              if (slice.length === 0) return;
              offset += slice.length;
              setItems((prev) => {
                const seenAll = new Set(prev.map(idOf).filter(Boolean) as string[]);
                const merged = [...prev, ...slice.filter((it: any) => {
                  const key = idOf(it);
                  return key === null || !seenAll.has(key);
                })];
                return merged.slice(-maxItems);
              });
              if (offset < appended.length) requestAnimationFrame(appendChunk);
            };
            appendChunk();
          }
        } else {
          setItems(result.items.slice(0, maxItems));
        }
        setPage(result.nextPage ?? targetPage);
        pageRef.current = result.nextPage ?? targetPage;
        setHasMore(result.hasMore);
        hasMoreRef.current = result.hasMore;
        setExtra(result.extra ?? null);
      } catch (e: any) {
        if (controller.signal.aborted || seq !== seqRef.current) return;
        if (targetPage === 1) {
          setError(e?.message || '加载失败');
        } else if (mode === 'more') {
          // 非首屏失败不置 error（保留已渲染内容）；至少留一条可排查日志
          //（见全量审查 #9：守卫链与既有语义不变，仅补告警）。
          console.warn('[usePagedList] loadMore failed, page:', targetPage, e?.message ?? e);
        }
      } finally {
        // 同步守卫必须无条件复位：若本次 loadMore 被后续 load/refresh 抢占
        // （seq 不匹配提前 return），loadingMoreRef 若保持 true 会永久拦截
        // 之后的 loadMore —— "刷新一次就再也翻不了页"的根因。
        loadingMoreRef.current = false;
        if (controllerRef.current === controller) controllerRef.current = null;
        if (seq !== seqRef.current) return;
        setLoading(false);
        setRefreshing(false);
        setLoadingMore(false);
      }
    },
    // fetcher 经 fetcherRef 读取，不参与依赖 —— 内联 fetcher 不再引发 run 重建
    [maxItems],
  );

  const load = useCallback(
    (targetPage?: number, overrideParams?: P, mode: 'initial' | 'refresh' | 'jump' | 'more' = 'initial') =>
      run(targetPage ?? 1, mode, overrideParams),
    [run],
  );
  const refresh = useCallback(() => run(1, 'refresh'), [run]);
  // loadMore 直接请求当前 `page`：setPage 已把 page 推进到 nextPage
  // （fetcher 的 nextPage 语义是"下一次应请求的页号"，均为 p+1）。
  // 若这里用 page + 1 会双重递增，每次翻页都跳过一页。
  // 同步守卫：loadingMore 经 setState 异步生效，LegendList 快速滚动时同帧
  // 二次 onEndReached 会拿旧闭包再跑一次；用 loadingMoreRef 同步拦截。
  // hasMore 守卫：已翻到底后（hasMore=false）贴底触发 onEndReached 不应当
  // 再发请求——否则每个越界页都会回吐重复数据并再次触发 onEndReached，
  // 形成停不下来的翻页风暴。
  // 同理 page 也走 pageRef，保证两次调用读取同一真实页号。
  const loadMore = useCallback(() => {
    if (!hasMoreRef.current || loadingMoreRef.current) return Promise.resolve();
    const now = Date.now();
    if (now - lastLoadMoreAtRef.current < LOAD_MORE_COOLDOWN_MS) return Promise.resolve();
    lastLoadMoreAtRef.current = now;
    loadingMoreRef.current = true;
    return run(pageRef.current, 'more');
  }, [run]);
  const reset = useCallback(() => {
    seqRef.current += 1;
    controllerRef.current?.abort();
    controllerRef.current = null;
    // 冷却守卫一并复位：reset 后立即 loadMore 不应被上一次的冷却时间拦截
    //（见全量审查 #9）
    lastLoadMoreAtRef.current = 0;
    setItems([]);
    setPage(initialPage);
    pageRef.current = initialPage;
    setHasMore(true);
    hasMoreRef.current = true;
    setLoading(true);
    setRefreshing(false);
    setLoadingMore(false);
    loadingMoreRef.current = false;
    setError(null);
    setExtra(null);
  }, [initialPage]);

  useEffect(() => {
    return () => {
      controllerRef.current?.abort();
    };
  }, []);

  return {
    items,
    page,
    hasMore,
    loading,
    refreshing,
    loadingMore,
    error,
    extra,
    load,
    refresh,
    loadMore,
    reset,
    setItems,
    setExtra,
  };
}
