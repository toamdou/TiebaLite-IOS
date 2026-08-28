/**
 * Single-shot async data hook（2026-08-25 抽取自吧页四个子页 detail / rules /
 * members / bawu 的「单次加载」样板）。
 *
 * 封装 loading / refreshing / error + load / refresh + 首载 effect + 竞态守卫，
 * 语义对齐 usePagedList：
 * - `loading`  — 首载（含 load()）在途；初始值 = enabled（enabled 为 false 时
 *               不发起请求、不卡骨架）。
 * - `refreshing` — 仅下拉刷新（refresh()）在途，驱动 RefreshControl 转圈。
 * - `error`    — 仅在「尚无数据时失败」置位（首屏失败 → 整页错误态）；
 *               刷新失败保留旧数据，仅 console.warn（不置 error、不清空）。
 * - 竞态守卫：seq 计数，较晚启动的 load/refresh 会压制先前在途请求的落地
 *   （含 loading/refreshing 复位），与 usePagedList run() 同款。
 * - fetcher 走 ref：调用方传内联箭头（每渲染新身份）时不会因依赖重建反复触发
 *   首载 effect，杜绝请求风暴。
 */
import { useCallback, useEffect, useRef, useState } from 'react';

export interface UseAsyncDataOptions<T> {
  fetcher: () => Promise<T>;
  /** 是否允许发起请求（如 forumId 路由参数缺失时为 false：不请求、不卡骨架） */
  enabled?: boolean;
}

export interface AsyncDataResult<T> {
  data: T | null;
  loading: boolean;
  refreshing: boolean;
  error: string | null;
  /** 首次加载（首载 effect 会基于 enabled 自动调用一次） */
  load: () => Promise<void>;
  /** 下拉刷新：失败时保留旧数据（仅 warn），不置 error */
  refresh: () => Promise<void>;
}

const errMessage = (e: unknown): string =>
  e instanceof Error ? e.message : typeof e === 'string' ? e : '加载失败';

export function useAsyncData<T>({ fetcher, enabled = true }: UseAsyncDataOptions<T>): AsyncDataResult<T> {
  const [data, setData] = useState<T | null>(null);
  const [loading, setLoading] = useState(enabled);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const seqRef = useRef(0);
  const dataRef = useRef<T | null>(null);
  const fetcherRef = useRef(fetcher);
  useEffect(() => {
    fetcherRef.current = fetcher;
  }, [fetcher]);

  const run = useCallback(async (mode: 'initial' | 'refresh') => {
    const seq = ++seqRef.current;
    if (mode === 'refresh') setRefreshing(true);
    else setLoading(true);
    setError(null);
    try {
      const result = await fetcherRef.current();
      if (seq !== seqRef.current) return;
      dataRef.current = result;
      setData(result);
    } catch (e: unknown) {
      if (seq !== seqRef.current) return;
      if (dataRef.current == null) {
        // 首屏失败：置 error 供整页错误态展示
        setError(errMessage(e));
      } else {
        // 刷新失败：保留旧数据，留一条可排查日志（对齐 usePagedList 规则）
        console.warn('[useAsyncData] load failed, keeping previous data:', errMessage(e));
      }
    } finally {
      if (seq !== seqRef.current) return;
      setLoading(false);
      setRefreshing(false);
    }
  }, []);

  // 首载 effect（竞态守卫在 run 内由 seq 完成）
  useEffect(() => {
    if (!enabled) {
      // loading 初值 = enabled，此处直接留空即可（不请求 → 不卡骨架，供
      // forumId 缺失时正常渲染空态/默认页）
      return;
    }
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data fetch; state updates happen after the async boundary.
    void run('initial');
  }, [enabled, run]);

  const load = useCallback(() => run('initial'), [run]);
  const refresh = useCallback(() => run('refresh'), [run]);

  return { data, loading, refreshing, error, load, refresh };
}
