// 已关注吧列表统一数据源，对齐 Kotlin HomeViewModel.allForumGuideFlow()。

import { forumGuide } from '@/services/api/endpoints/forum';
import { mapForumInfo } from '@/services/api/endpoints/helpers';
import { setBackgroundForums } from '@/services/nativeBackground';
import { kvGetSync, kvRemoveSync, kvSetSync } from '@/services/storage/unifiedDb';
import type { ForumInfo } from '@/types';

const PAGE_SIZE = 50;
const MAX_PAGES = 20;
const MAX_TOTAL = 1000;
const CONCURRENCY = 4;
const ROUND_TIMEOUT_MS = 60 * 1000;
/** 内存缓存 TTL：会话内热更判新鲜（下拉刷新/签到后立即可见）。 */
const CACHE_TTL_MS = 5 * 60 * 1000;
/** 磁盘缓存 TTL：冷启动秒显专用。关注吧列表低频变化（吧名/顺序），
 * 等级/签到状态是次要字段、进吧或下拉会刷新；24h 内冷启动直接出列表，
 * 预热请求随后覆盖。2026-08-27：原 5min 太短，冷启动几乎总过期。
 * 2026-08-28：1h→24h——隔夜冷启动命中率近零，关注/取关/签到由
 * invalidateFollowedForumsCache 即时失效，不必靠短 TTL 自愈。 */
const DISK_CACHE_TTL_MS = 24 * 60 * 60 * 1000;
/** 单页请求硬超时：网络层挂起时 Promise.all 永不返回 → 下拉刷新一直转（2026-08-27 修）。 */
const PAGE_TIMEOUT_MS = 10 * 1000;
/** 磁盘缓存键（冷启动秒显；失效/登出/切号时清除）。 */
const DISK_CACHE_KEY = 'followed_forums_cache_v1';

interface FollowedCache {
  expiresAt: number;
  forums: ForumInfo[];
}

let followedCache: FollowedCache | null = null;
let inflightFetch: Promise<ForumInfo[]> | null = null;

/** 磁盘缓存写（列表 ≤ 数百 KB，MMKV 同步无害）。 */
function writeDiskCache(cache: FollowedCache): void {
  try {
    kvSetSync(DISK_CACHE_KEY, JSON.stringify(cache));
  } catch {
    // best-effort：磁盘写失败仅失去冷启动加速
  }
}

/** 磁盘缓存读（损坏/过期由调用方判弃）。 */
function readDiskCache(): FollowedCache | null {
  try {
    const raw = kvGetSync(DISK_CACHE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as FollowedCache;
    if (!Array.isArray(parsed.forums)) return null;
    return { expiresAt: Number(parsed.expiresAt) || 0, forums: parsed.forums };
  } catch {
    return null;
  }
}

/** 单页硬超时守卫：超时即 reject（挂起请求不再拖死整批刷新）。 */
function withPageTimeout<T>(promise: Promise<T>, label: string): Promise<T> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`${label} 请求超时`)), PAGE_TIMEOUT_MS);
    promise.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (error) => {
        clearTimeout(timer);
        reject(error);
      },
    );
  });
}

async function fetchPage(
  pageNo: number,
  signal: AbortSignal,
): Promise<{ forums: ForumInfo[]; hasMore: boolean }> {
  if (signal.aborted) {
    throw new Error('获取关注贴吧列表已取消');
  }

  // Kotlin allForumGuideFlow: sortType=3, callFrom=3, pageNo 从 1 开始。
  const response = await withPageTimeout(
    forumGuide(3, 3, pageNo, PAGE_SIZE, signal),
    `关注列表第 ${pageNo} 页`,
  );
  const data = response?.data ?? response;
  const forumList = data?.like_forum ?? data?.likeForum ?? [];
  return {
    forums: forumList.map((item: any) => mapForumInfo(item)),
    hasMore: forumList.length >= PAGE_SIZE,
  };
}

async function fetchAllPages(signal: AbortSignal): Promise<ForumInfo[]> {
  const pageMap = new Map<number, ForumInfo[]>();
  const seenForumIds = new Set<string>();
  const startedAt = Date.now();
  let total = 0;
  let pageNo = 1;

  while (pageNo <= MAX_PAGES) {
    if (signal.aborted) {
      throw new Error('获取关注贴吧列表已取消');
    }
    if (Date.now() - startedAt > ROUND_TIMEOUT_MS) {
      throw new Error('获取关注贴吧列表超时，请稍后重试');
    }

    const batchPages = Array.from(
      { length: Math.min(CONCURRENCY, MAX_PAGES - pageNo + 1) },
      (_, index) => pageNo + index,
    );
    const batch = await Promise.all(
      batchPages.map((page) => fetchPage(page, signal)),
    );

    let batchHasMore = false;
    batch.forEach((result, index) => {
      const currentPage = batchPages[index];
      const pageForums: ForumInfo[] = [];
      for (const item of result.forums) {
        if (!item.forumId || seenForumIds.has(item.forumId)) continue;
        seenForumIds.add(item.forumId);
        pageForums.push(item);
        total += 1;
        if (total >= MAX_TOTAL) break;
      }
      pageMap.set(currentPage, pageForums);
      if (result.hasMore) batchHasMore = true;
    });

    if (!batchHasMore || total >= MAX_TOTAL) break;
    pageNo += CONCURRENCY;
  }

  const allForums: ForumInfo[] = [];
  for (let page = 1; page <= MAX_PAGES; page += 1) {
    const forums = pageMap.get(page);
    if (forums) allForums.push(...forums);
  }
  return allForums;
}

/**
 * 有界并发拉取全部已关注吧，并缓存 5 分钟（CACHE_TTL_MS）。
 * 并发上限为 CONCURRENCY；同一时间只有一个全量请求在途。
 *
 * 缓存契约：本模块唯一的缓存写入点是模块级 followedCache（下方赋值处）；
 * 读取时按 expiresAt 判 ≤5min 旧缓存。失效路径唯一 ——
 * invalidateFollowedForumsCache()/invalidateNow()（调用方见其注释），
 * 无遗漏路径：inflightFetch 仅作同批次并发去重，不参与缓存。
 */
export async function fetchAllFollowedForums(signal?: AbortSignal): Promise<ForumInfo[]> {
  const now = Date.now();
  if (followedCache && followedCache.expiresAt > now) {
    // 2026-08-27 时序诊断：冷启动预热是否命中缓存（未命中 = 主页要等请求）
    if (__DEV__) console.warn(`[prefetch] forums 缓存命中（${followedCache.forums.length} 个，剩余 ${Math.round((followedCache.expiresAt - now) / 1000)}s）`);
    return [...followedCache.forums];
  }
  // 内存 miss → 磁盘缓存兜底（冷启动秒显：上次会话的列表即刻可用，
  // 预热请求随后覆盖——2026-08-27 冷启 1.6s 网络等待优化）。
  if (!followedCache) {
    const disk = readDiskCache();
    if (disk && disk.expiresAt > now) {
      followedCache = disk;
      if (__DEV__) console.warn(`[prefetch] forums 磁盘缓存命中（${disk.forums.length} 个，剩余 ${Math.round((disk.expiresAt - now) / 1000)}s）`);
      return [...disk.forums];
    }
  }
  if (inflightFetch) {
    if (__DEV__) console.warn('[prefetch] forums 复用 in-flight 请求');
    return inflightFetch;
  }

  inflightFetch = (async () => {
    const startedAt = Date.now();
    if (__DEV__) console.warn('[prefetch] forums 发起请求（缓存未命中）');
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), ROUND_TIMEOUT_MS);
    const onExternalAbort = () => controller.abort();
    if (signal) {
      if (signal.aborted) {
        controller.abort();
      } else {
        signal.addEventListener('abort', onExternalAbort, { once: true });
      }
    }

    try {
      const forums = await fetchAllPages(controller.signal);
      followedCache = { expiresAt: Date.now() + CACHE_TTL_MS, forums };
      writeDiskCache({ expiresAt: Date.now() + DISK_CACHE_TTL_MS, forums });
      if (__DEV__) {
        console.warn(`[prefetch] forums 完成：${forums.length} 个（${Date.now() - startedAt}ms）`);
      }
      // ⚠️ 副作用（立法待办）：数据获取层内嵌 UI 副作用 setBackgroundForums
      //（吧页背景快照）。依赖方向应为 store 层在数据成功分支调用 —— 待 K 域
      // forumStore 接入本模块时一并上移，此处仅标注位置，不迁移。
      setBackgroundForums(
        forums.map((forum) => forum.forumId),
        forums.map((forum) => forum.forumName),
      );
      return forums;
    } finally {
      clearTimeout(timeout);
      signal?.removeEventListener('abort', onExternalAbort);
      inflightFetch = null;
    }
  })();

  return inflightFetch;
}

/**
 * 关注/取关后主动失效缓存，下次读取重新拉取。
 * 必调方（契约）：forumStore.followForum / unfollowForum 成功分支必须调用
 * （K 域任务书要求；否则 ≤5min 旧缓存会把关注/取关的本地补丁覆盖回旧状态）。
 * 现有调用方：authStore（登录/登出/切号 teardown）、app/_layout.tsx
 * （后台登录态恢复后失效）。
 */
export function invalidateFollowedForumsCache(): void {
  followedCache = null;
  kvRemoveSync(DISK_CACHE_KEY);
}

/** invalidateFollowedForumsCache 的短别名（同一函数对象，签名 () => void 稳定）。 */
export const invalidateNow = invalidateFollowedForumsCache;

/**
 * 只读导出：已关注吧缓存快照（内存 TTL 5min 优先，磁盘 TTL 24h 兜底）。
 * 不触发网络、不写缓存（严格只读：不赋值 followedCache，磁盘缓存过期的
 * 冷启动由 fetchAllFollowedForums 正常预热覆盖）；缓存过期/损坏返回空 Map。
 * 用途：动态流吧头像回填等只读消费（2026-08-28，见 endpoints/feed.ts
 * backfillForumAvatars——服务端 personalized 不下发 forumInfo.avatar，
 * 已关注吧列表是本地唯一大头像数据源）。
 */
export function getCachedForumsMap(): Map<string, ForumInfo> {
  const now = Date.now();
  const mem = followedCache && followedCache.expiresAt > now ? followedCache.forums : null;
  if (mem) {
    if (__DEV__) console.warn(`[prefetch][avatar] 缓存：内存 ${mem.length} 个`);
    return new Map(mem.map((f) => [f.forumId, f]));
  }
  const disk = readDiskCache();
  if (disk && disk.expiresAt > now) {
    if (__DEV__) console.warn(`[prefetch][avatar] 缓存：磁盘 ${disk.forums.length} 个`);
    return new Map(disk.forums.map((f) => [f.forumId, f]));
  }
  if (__DEV__) console.warn('[prefetch][avatar] 缓存未命中（只读，不触发网络，待关注列表预热后回填）');
  return new Map();
}
