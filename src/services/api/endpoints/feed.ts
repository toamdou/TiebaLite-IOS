import { apiGetHybrid } from '../client';
import { TiebaApiError } from '../interceptors';
import { protoHotThreadList, protoPersonalized, protoTopicList, protoUserLike } from '../protoClient';
import { PERSONALIZED_PAGE_SIZE } from '../proto';
import { assertProtoSuccess, extractData, mapProtoThread, toMillis, type ClientDataRes } from './helpers';
import { kvGetSync, kvSetSync } from '@/services/storage/unifiedDb';
import { getCachedForumsMap } from '@/services/forumFollowed';
import { LoadType } from '@/types';
import type { FeedItem, HotPageData, TopicInfo } from '@/types';
// ============================================================
// Feed — protobuf-aligned (Kotlin OfficialTiebaApi protobuf)
// ============================================================
// Kotlin protobuf: POST /c/f/excellent/personalized?cmd=309264
//（cmd 与 protoClient.protoPersonalized 一致；此前头注释误写 309471 ——
//  过期值，见全量审查 #6。实路径见 protoClient，保持 /c/f/recommend/personalized）

// 首屏预热 + SWR 快照：
// - warmHomeFeed() 在 splash 阶段后台预取首页推荐（不阻塞启动），成功后把
//   首屏条目存入模块级 seed 供 Explore 首帧直接渲染；
// - personalized(page=1) 每次成功后把最新首屏写入 kv 快照（25 条封顶，
//   序列化体积 ~40KB，避免 kv 全表常驻内存膨胀），冷启动 Explore 兜底渲染
//   "上次看到的内容"，网络返回后整体替换 —— 感知启动大幅提前。
const SNAPSHOT_KEY = '@tiebalite:feed_snapshot_v1';
const SNAPSHOT_MAX_ITEMS = 25;
/** 启动预热请求的悬挂超时：到点即释放 warming 锁（见 warmHomeFeed 注释） */
const WARM_TIMEOUT_MS = 8 * 1000;
let warmSeed: FeedItem[] | null = null;
let warming = false;

function saveFeedSnapshot(items: FeedItem[]): void {
  try {
    kvSetSync(SNAPSHOT_KEY, JSON.stringify(items.slice(0, SNAPSHOT_MAX_ITEMS)));
  } catch {
    // 快照写入失败不影响主流程
  }
}

/** 启动期后台预取首页推荐（幂等、静默失败）。 */
export function warmHomeFeed(): void {
  if (warming || warmSeed) return;
  warming = true;
  // 超时守卫：请求悬挂（弱网/服务端异常）时 8s 后释放 warming 锁 ——
  // 否则 warming 永久为 true，本次及后续会话都再也无法预热
  //（见全量审查 #16；宁可放弃一次预热，不让锁被钉死）。
  const timer = setTimeout(() => { warming = false; }, WARM_TIMEOUT_MS);
  personalized(LoadType.REFRESH, 1)
    .then((r) => {
      if (r.items.length > 0) warmSeed = r.items;
    })
    .catch(() => {})
    .finally(() => {
      clearTimeout(timer);
      warming = false;
    });
}

/** 取走内存预热 seed（取走即清空，避免常驻）。无则返回 null。 */
export function consumeWarmSeed(): FeedItem[] | null {
  const s = warmSeed;
  warmSeed = null;
  return s;
}

/** 同步读取磁盘首屏快照（冷启动兜底）。kv 未就绪时返回 null。 */
export function hydrateFeedSnapshotSync(): FeedItem[] | null {
  try {
    const raw = kvGetSync(SNAPSHOT_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed) || parsed.length === 0) return null;
    // 最小字段守卫（全量审查 #16）：只认 threadInfo.id 为 string 的行 ——
    // 快照被写坏/被外部改动时丢弃脏行，防 LegendList keyExtractor 拿到
    // 非字符串 key 后虚拟化错乱。
    const items = (parsed as FeedItem[]).filter((it) => typeof it?.threadInfo?.id === 'string');
    return items.length > 0 ? items : null;
  } catch {
    return null;
  }
}

/** Map raw proto thread entries to FeedItem rows (proto + JSON fallback share this). */
function mapThreadItems(threadList: any[], userList: any[]): FeedItem[] {
  return threadList.map((t: any) => ({
    type: 'thread' as const,
    threadInfo: mapProtoThread(t, { userList }),
  }));
}

/**
 * 吧头像缓存回填（2026-08-28，用户："吧名前没有吧头像"）：服务端 personalized
 * 的 ThreadInfo.forumInfo（SimpleForum，avatar=proto 字段 4）恒为 null（真机 dump
 * forum0={"forumInfo":null,"forumName":"高通"}；Kotlin FeedCard.kt 同样只读
 * threadInfo.forumInfo.avatar），解码器不丢字段 → 大头像只能本地回填：已关注吧
 * 列表缓存（forumFollowed.getCachedForumsMap，严格只读、不触发网络）带
 * ForumInfo.avatar。
 * 边界：仅已关注吧（缓存匹配、threadInfo.forumId 命中）回填；未关注吧保持无
 * 头像（服务端无数据、如实）；threadInfo.forumAvatar 已有值（服务端下发/其他
 * 来源）不覆盖。
 * 调用点在 personalized() 出口统一处理，一次覆盖 proto 主路径、JSON 兜底、
 * warm seed 与磁盘快照（saveFeedSnapshot 在回填之后写入）。
 */
function backfillForumAvatars(items: FeedItem[]): FeedItem[] {
  const cache = getCachedForumsMap();
  let hit = 0;
  let miss = 0;
  const next = items.map((item) => {
    const t = item.threadInfo;
    if (!t || t.forumAvatar) return item;
    const avatar = cache.get(String(t.forumId ?? ''))?.avatar;
    if (!avatar) {
      miss += 1;
      return item;
    }
    hit += 1;
    return { ...item, threadInfo: { ...t, forumAvatar: avatar } };
  });
  if (__DEV__) {
    console.warn(`[feed] forumAvatar 回填：命中=${hit} 缺失=${miss}（缓存 ${cache.size} 个吧，条目 ${items.length}）`);
  }
  return next;
}

export async function personalized(loadType: LoadType = LoadType.REFRESH, page: number = 1, signal?: AbortSignal): Promise<{ items: FeedItem[]; hasMore: boolean }> {
  let result: { items: FeedItem[]; hasMore: boolean };
  try {
    const decoded = await protoPersonalized({ loadType: Number(loadType), pn: page }, signal);
    assertProtoSuccess(decoded);
    const data = decoded.data;
    const items = mapThreadItems(data?.threadList ?? [], data?.userList ?? []);
    // PersonalizedResponseData 无 page 字段（descriptor 仅 threadList/threadPersonalized），
    // 翻页判定以条目数对齐请求页容量（PERSONALIZED_PAGE_SIZE=11，2026-08-27 由 20 修正：
    // 页容量对齐后 11 条/页恒 <20 → 首页就误判"没有更多"）。
    const hasMore = (data?.threadList?.length ?? 0) >= PERSONALIZED_PAGE_SIZE;
    result = { items, hasMore };
    if (__DEV__) {
      // 全量摘要：error=0 但 threadList=0 时看服务端到底回了什么（接口是否已废）
      let dump = '';
      try {
        dump = JSON.stringify(decoded).slice(0, 220);
      } catch {
        dump = String(decoded);
      }
      // 吧头像诊断（2026-08-27 用户："吧名前没有吧头像"）：看帖条是否带
      // forumInfo 子对象（avatar 在 forumInfo.avatar=4；顶层 forumName 有值
      // 但 forumInfo 缺失 = 服务端个性化响应不下发头像 → 帖卡无图）。
      // 2026-08-28 追加 alaInfo 计数：直播/广告卡片判据（Kotlin 铁律
      // ala_info != null，ThreadInfo.proto 字段 113）——验证解码产物键
      //（protobufjs camelCase）与 wire 存在性，供过滤链路排障。
      let forumDump = '';
      try {
        const t0 = (decoded as any)?.data?.threadList?.[0];
        forumDump = t0 ? JSON.stringify({ forumInfo: t0.forumInfo ?? null, forumName: t0.forumName ?? null, fname: t0.fname, alaInfo: t0.alaInfo ?? null }).slice(0, 200) : 'empty';
      } catch {
        forumDump = 'dump-failed';
      }
      const alaCount = (data?.threadList ?? []).filter((t: any) => t?.alaInfo != null).length;
      console.warn(`[personalized] proto: threadList=${data?.threadList?.length ?? 0} alaCount=${alaCount} forum0=${forumDump} body=${dump}`);
    }
  } catch (e) {
    if (__DEV__) console.warn('[personalized] proto failed, fallback:', e);
    const response = await apiGetHybrid<ClientDataRes<{ items: FeedItem[]; has_more: number }>>(
      '/c/f/personalized',
      {
        load_type: String(loadType), page_no: String(page), page_size: '20',
      },
      signal,
    );
    const data = extractData(response);
    result = { items: data.data?.items ?? [], hasMore: data.data?.has_more === 1 };
    if (__DEV__) console.warn(`[personalized] fallback: items=${result.items.length}`);
  }
  // 吧头像缓存回填（proto 主路径 + JSON 兜底统一出口；快照/预热 seed 一并覆盖，
  // 见 backfillForumAvatars 注释）
  result = { ...result, items: backfillForumAvatars(result.items) };
  // 2026-08-28：回填后仍缺失头像的吧（未关注/无缓存）→ 按吧名实时拉取。
  // 数据源=轻量 /mo/q/search/forum（exact_match.avatar，web 通道），
  // forumAvatarCache store 内部在途去重/并发 2/120ms 间隔/磁盘 24h 缓存；
  // 异步不阻塞渲染（拉取期间灰底兜底，命中后订阅侧自动更新）。
  if (result.items.length > 0) {
    void import('@/stores/forumAvatarCache').then(({ useForumAvatarStore }) => {
      useForumAvatarStore.getState().ensureAvatars(
        result.items
          .map((it) => it.threadInfo)
          .filter((t) => !!t && !t.forumAvatar && !!t.forumId && !!t.forumName)
          .map((t) => ({ forumId: String(t!.forumId), forumName: t!.forumName ?? '' })),
      );
    });
  }
  // 首页数据成功即刷新快照（warm 预取也会走到这里，属幂等冗余）
  if (page === 1 && result.items.length > 0) saveFeedSnapshot(result.items);
  return result;
}

// Kotlin protobuf: POST /c/f/concern/userlike?cmd=309474
//（与 protoClient.protoUserLike 一致；实路径保持 /c/f/recommend/userLike）

// Kotlin 增量语义：ConcernViewModel.userLikeFlow(pageTag, lastRequestUnix, loadType)
// 每次请求携带「上一次成功响应回吐的 requestUnix」，服务端按时间戳增量推送
// 关注动态（不传则每次拉全量、可能重复）。这里用模块级变量缓存上次成功的
// requestUnix（初始 0），下次调用自动带上 —— 跨分页/刷新/组件卸载保留，
// 等价 Kotlin ViewModel 字段生命周期（见全量审查 #5；不碰 preferencesStore）。
let lastSuccessRequestUnix = 0;

export async function userLike(
  pageTag?: string, lastRequestUnix?: number, loadType: LoadType = LoadType.REFRESH,
  signal?: AbortSignal,
): Promise<{ items: FeedItem[]; pageTag: string; hasMore: boolean }> {
  // 本次请求携带的增量时间戳：显式入参优先，否则模块级上次成功值
  const requestUnix = lastRequestUnix ?? lastSuccessRequestUnix;
  try {
    const decoded = await protoUserLike({
      loadType: Number(loadType),
      pageTag: pageTag ?? '',
      lastRequestUnix: requestUnix,
    }, signal);
    assertProtoSuccess(decoded);
    const data = decoded.data;
    // UserLikeResponseData 真实字段是 threadInfo（ConcernData[]，内含 threadList: ThreadInfo），
    // 而非 threadList —— 旧代码读空字段导致关注流恒空。
    const items = (data?.threadInfo ?? [])
      .map((c: any): FeedItem | null => {
        const threadRaw = c?.threadList ?? c?.thread_list ?? c;
        if (!threadRaw || typeof threadRaw !== 'object') return null;
        const tid = threadRaw?.id ?? threadRaw?.tid ?? threadRaw?.thread_id ?? threadRaw?.threadId;
        if (tid == null && threadRaw?.title == null) return null;
        const forum = threadRaw?.forum ?? c?.forum ?? {};
        const thread = mapProtoThread(
          { ...threadRaw, author: threadRaw?.author ?? c?.author },
          { forum },
        );
        return { type: thread.isVideo ? 'video_thread' : 'thread', threadInfo: thread };
      })
      .filter((x: FeedItem | null): x is FeedItem => x !== null);
    // 写回响应里的 requestUnix（data 走 index signature；字段缺失时保持原值）
    const nextUnix = Number(data?.requestUnix ?? 0);
    if (nextUnix > 0) lastSuccessRequestUnix = nextUnix;
    return {
      items,
      pageTag: data?.pageTag ?? '',
      hasMore: (data?.hasMore ?? 0) === 1,
    };
  } catch (e) {
    if (__DEV__) console.warn('[userLike] proto failed, fallback:', e);
    const response = await apiGetHybrid<ClientDataRes<{ items: FeedItem[]; page_tag: string; has_more: number; request_unix?: number }>>(
      '/c/f/userLike',
      {
        load_type: String(loadType), page_tag: pageTag ?? '', last_request_unix: String(requestUnix),
      },
      signal,
    );
    const data = extractData(response);
    // JSON 兜底同样回写 request_unix（缺省保持原值）
    const nextUnix = Number(data.data?.request_unix ?? 0);
    if (nextUnix > 0) lastSuccessRequestUnix = nextUnix;
    return { items: data.data?.items ?? [], pageTag: data.data?.page_tag ?? '', hasMore: data.data?.has_more === 1 };
  }
}

// ============================================================
// Hot Threads & Topics — already protobuf-aligned ✅
// ============================================================

function mapHotTopic(t: any) {
  return {
    topicId: String(t.topicId ?? ''),
    topicName: String(t.topicName ?? ''),
    type: Number(t.type ?? 0),
    discussNum: Number(t.discussNum ?? 0),
    tag: Number(t.tag ?? 0),
    topicDesc: String(t.topicDesc ?? ''),
    topicPic: String(t.topicPic ?? ''),
  };
}

function mapHotTab(t: any) {
  return {
    tabId: Number(t.tabId ?? 0),
    tabType: Number(t.tabType ?? 0),
    tabName: String(t.tabName ?? ''),
    tabCode: String(t.tabCode ?? ''),
    tabUrl: String(t.tabUrl ?? ''),
    tabGid: String(t.tabGid ?? ''),
    tabTitle: String(t.tabTitle ?? ''),
    isGeneralTab: Number(t.isGeneralTab ?? 0),
  };
}

function mapHotThread(t: any) {
  return {
    id: String(t.id ?? ''),
    threadId: String(t.threadId ?? t.id ?? ''),
    title: String(t.title ?? ''),
    replyNum: Number(t.replyNum ?? 0),
    viewNum: Number(t.viewNum ?? 0),
    forumId: String(t.forumId ?? ''),
    forumName: String(t.forumName ?? ''),
    authorId: String(t.author?.id ?? t.authorId ?? ''),
    authorName: String(t.author?.name ?? ''),
    authorNameShow: String(t.author?.nameShow ?? ''),
    authorPortrait: String(t.author?.portrait ?? ''),
    firstPostId: String(t.firstPostId ?? ''),
    createTime: toMillis(Number(t.createTime ?? t.lastTimeInt ?? 0)),
    agreeNum: Number(t.agreeNum ?? 0),
    hotNum: Number(t.hotNum ?? 0),
    hasAgree: Number(t.agree?.hasAgree ?? 0),
    agree: t.agree
      ? {
          agreeNum: Number(t.agree.agreeNum ?? 0),
          hasAgree: Number(t.agree.hasAgree ?? 0),
          diffAgreeNum: Number(t.agree.diffAgreeNum ?? 0),
        }
      : undefined,
    tabId: Number(t.tabId ?? 0),
    tabName: String(t.tabName ?? ''),
  };
}

export async function hotThreadList(tabCode: string = 'all'): Promise<HotPageData> {
  const decoded = await protoHotThreadList(tabCode);
  // proto3: error_code=0 时不序列化，undefined 视为成功
  assertProtoSuccess(decoded);
  const data = decoded.data;
  if (!data) throw new TiebaApiError('Empty response', -1, -1);
  return {
    topics: (data.topicList ?? []).map(mapHotTopic),
    tabs: (data.hotThreadTabInfo ?? []).map(mapHotTab),
    threads: (data.threadInfo ?? []).map(mapHotThread),
  };
}

function mapTopicInfo(t: any): TopicInfo {
  return {
    topicId: String(t.topicId ?? t.topic_id ?? ''),
    topicName: String(t.topicName ?? t.topic_name ?? ''),
    topicDesc: String(t.topicDesc ?? t.topic_desc ?? ''),
    discussNum: Number(t.discussNum ?? t.discuss_num ?? 0),
    isHot: (t.topicTag ?? t.topic_tag ?? t.tag) === 2,
    isNew: (t.topicTag ?? t.topic_tag ?? t.tag) === 1,
  };
}

export async function topicList(): Promise<TopicInfo[]> {
  const decoded = await protoTopicList();
  assertProtoSuccess(decoded);
  return (decoded.data?.topicList ?? decoded.data?.topic_list ?? []).map(mapTopicInfo);
}


