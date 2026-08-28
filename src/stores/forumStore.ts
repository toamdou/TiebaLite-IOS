// ============================================================
// forumStore — 对齐 Kotlin ForumPage + ForumViewModel
//
// API:
//   POST c.tieba.baidu.com/c/f/frs/page  (form-encoded)
//     → 返回 forum info + thread_list + user_list + page + anti + nav_tab_info
//   POST c.tieba.baidu.com/c/c/forum/like  (follow, 需登录 + tbs)
//   POST c.tieba.baidu.com/c/c/forum/unfavolike  (unfollow, 需登录 + tbs + stoken)
//
// Tab 系统:
//   Tab 0/1 — 热门/最新 (isGood=false)
//   Tab 2 — 精品 (isGood=true, goodClassifyId from dropdown)
//   Tab N — 自定义Tab (navTabInfo, TODO: protobuf)
//
// Author mapping: 对齐 Kotlin FrsPageRepository
//   thread_list 每项只有 authorId，从 user_list 按 id 映射 author 信息
// ============================================================

import { create } from 'zustand';
import type { ForumInfo, ForumDetail, ThreadInfo } from '@/types';
import { ForumSortType } from '@/types';
import { getTbsSync, setTbsSync } from '@/services/storage/AuthSQLiteStorage';
import { useAuthStore } from '@/stores/authStore';
import { usePreferencesStore } from '@/stores/preferencesStore';
import { syncBackgroundSnapshot } from '@/services/nativeBackground';

// ── 启动热路径裁剪（冷启动 TTI）──
// 本 store 被首页 index.tsx / SignViewModel 静态引用、进首帧模块图。
// proto 端点（protobufjs 图）、JSON 端点（nitro-fetch 图）与关注列表网络层
// 一律延迟到调用点 require —— 同一模块实例、同一导出，仅推迟求值时机；
// 存储层与 authStore 保持静态（轻量、首帧即用）。
/* eslint-disable @typescript-eslint/no-require-imports -- 启动热路径惰性加载 */
const lazyProtoClient = () =>
  require('@/services/api/protoClient') as typeof import('@/services/api/protoClient');
const lazyHelpers = () =>
  require('@/services/api/endpoints/helpers') as typeof import('@/services/api/endpoints/helpers');
const lazyForumEndpoints = () =>
  require('@/services/api/endpoints/forum') as typeof import('@/services/api/endpoints/forum');
const lazyForumFollowed = () =>
  require('@/services/forumFollowed') as typeof import('@/services/forumFollowed');
/* eslint-enable @typescript-eslint/no-require-imports */

/** Keep a hard cap on retained rows so long paging can't grow memory forever. */
const MAX_THREADS_PER_LIST = 200;

function appendBounded<T>(current: T[], next: T[], max: number): T[] {
  return [...current, ...next].slice(-max);
}

let forumLoadSeq = 0;

/** 三桶键名组（threads/page/hasMore 后缀），消除 loadForumData 内三分支九段重复 */
type BucketKey = 'latest' | 'newest' | 'good';

function bucketKeyOf(routeTab: number, isGood?: boolean): BucketKey {
  // 分桶必须按「语义 tab」判定（最新=tab 1），不能按 sortType 判定：
  // 之前按 sortType===SEND_TIME 判断，导致最新 tab 用"按回复"偏好时数据落进
  // latestThreads（热门桶），newestThreads 恒空 → 最新板块空白（历史修复）。
  if (isGood) return 'good';
  return routeTab === 1 ? 'newest' : 'latest';
}

/** Good classify item (Kotlin ForumPageBean.GoodClassifyBean) */
export interface GoodClassifyItem {
  classId: string;
  className: string;
}

/** navTabInfo 契约最小形状：proto.ts 解码为 Record<string, any>[]，
 *  页面侧按需读取已知键（tabId/tabName），未知键走 index signature。 */
export interface NavTabInfoItem {
  tabId: number;
  tabName: string;
  [key: string]: unknown;
}

export interface ForumState {
  // ── Followed forums ──
  followedForums: ForumInfo[];
  isLoadingForums: boolean;

  // ── Current forum ──
  currentForum: ForumDetail | null;
  forumSortType: ForumSortType;

  // ── Tab system (对齐 Kotlin HorizontalPager) ──
  /** 0=热门, 1=最新, 2=精品, 3+=navTabInfo tabs */
  currentTab: number;
  goodClassifyId: string | null;
  goodClassify: GoodClassifyItem[];
  /** navTabInfo for general tabs (from API — may be null for JSON API) */
  navTabInfo: NavTabInfoItem[] | null;

  // ── Per-tab thread lists ──
  latestThreads: ThreadInfo[];
  goodThreads: ThreadInfo[];
  /** 最新 tab（SEND_TIME 排序）独立缓存桶：与热门（REPLY_TIME）互不冲刷。 */
  newestThreads: ThreadInfo[];
  latestPage: number;
  goodPage: number;
  newestPage: number;
  latestHasMore: boolean;
  goodHasMore: boolean;
  newestHasMore: boolean;

  // ── Actions ──
  loadFollowedForums(): Promise<void>;
  loadForumData(forumName: string, page: number, sortType: ForumSortType, isGood?: boolean, tab?: number): Promise<void>;
  setForumSortType(sortType: ForumSortType): void;
  setCurrentTab(tab: number): void;
  /**
   * 进入新吧会话：清空全部数据桶/分类/当前 tab（对齐 Kotlin ForumPage 新 ViewModel）。
   * loadForumData 只在成功后整体替换分桶、不在开始时清空——第二次进别的吧时残留
   * 上一吧数据会让页面 `latestThreads.length===0` 骨架条件失效（无骨架屏 + 先展示
   * 上一吧陈旧帖子，且最新/精品 tab 因桶非空跳过首次拉取）。currentForum 保留到
   * 新数据到达（本次 for visit 记录依赖它）。
   */
  resetForumData(): void;
  setGoodClassifyId(id: string | null): void;
  /** 关注成功返回 likeForum 响应等级/会员数（Kotlin LikeForumResultBean.info 对齐） */
  followForum(
    forumId: string,
    forumName: string,
  ): Promise<{
    memberSum?: number;
    levelId?: number;
    levelName?: string;
    curScore?: number;
    levelupScore?: number;
  }>;
  unfollowForum(forumId: string, forumName: string): Promise<void>;
  markForumSigned(forumId: string, exp: number): void;
  /**
   * 三桶统一更新原语（thermo 2026-08-26 Z8-A/Z1-B）：吧页点赞 patch /
   * 屏蔽作者移除等"作用于全部分桶"的页面侧需求，不再各自手写三份展开。
   */
  updateAllBuckets(updater: (list: ThreadInfo[]) => ThreadInfo[]): void;
}

/** 三桶状态键（updateAllBuckets 原语的落点） */
const BUCKET_STATE_KEYS = ['latestThreads', 'newestThreads', 'goodThreads'] as const;

/** Helper: get tbs from currentForum or auth storage */
function getForumTbs(currentForum: ForumDetail | null): string {
  return currentForum?.tbs || getTbsSync() || '';
}

export const useForumStore = create<ForumState>((set, get) => ({
  followedForums: [],
  isLoadingForums: false,
  currentForum: null,
  forumSortType: ForumSortType.REPLY_TIME,

  // ── Tab state ──
  currentTab: 0,
  goodClassifyId: null,
  goodClassify: [],
  navTabInfo: null,

  // ── Per-tab data ──
  latestThreads: [],
  goodThreads: [],
  newestThreads: [],
  latestPage: 1,
  goodPage: 1,
  newestPage: 1,
  latestHasMore: true,
  goodHasMore: true,
  newestHasMore: true,

  // ── loadFollowedForums ──
  loadFollowedForums: async () => {
    set({ isLoadingForums: true });
    try {
      const list = await lazyForumFollowed().fetchAllFollowedForums();
      // 签到标识合并：服务端列表（forumGuide like_forum）is_sign 可能缺失/滞后，
      // 直接全量覆盖会把本会话内已签到（markForumSigned 置位）的吧打回"未签"
      // （2026-08-27 真机：一键签到成功后打开又提示未签到）。只合并 isSign 升
      // 级（签过即保持），其余字段以服务端为准。
      const prevSigned = new Set(
        get().followedForums.filter((f) => f.isSign).map((f) => f.forumId),
      );
      const merged = prevSigned.size > 0
        ? list.map((f) => (prevSigned.has(f.forumId) ? { ...f, isSign: true } : f))
        : list;
      set({ followedForums: merged, isLoadingForums: false });
    } catch (error) {
      set({ isLoadingForums: false });
      // 不吞错误：首页靠 catch 设置 forumsError 并展示重试入口，
      // 否则网络失败会显示"暂无关注的贴吧"空态。
      console.error('[ForumStore] Failed to load followed forums:', error);
      throw error;
    }
  },

  // ── loadForumData — 对齐 Kotlin FrsPageRepository.frsPage() ──
  // POST /c/f/frs/page?cmd=301001 (protobuf)
  // 返回 forum + thread_list + user_list + page + anti + nav_tab_info
  loadForumData: async (forumName: string, page: number, sortType: ForumSortType, isGood?: boolean, tab?: number) => {
    const seq = ++forumLoadSeq;
    // 路由语义 tab：显式 tab 参数用于"按 tab 预挂载加载"（pager 页面挂载时
    // store.currentTab 可能是别的 tab，不能让分桶/默认流判定跟着当前选中走）。
    const { goodClassifyId } = get();
    const routeTab = tab ?? get().currentTab;
    // 对齐 Kotlin v12 frsPage 语义（MixedTiebaApiImpl.frsPage + ForumThreadListViewModel）：
    // - 热门(0)/精品(2)：sort_type = -1 —— 让服务端按该吧默认列表返回。此前硬编码
    //   5(按回复) 会被服务端当成"热门推荐"流，返回混合其他吧的贴子（串吧 bug）。
    // - 最新(1)：sort_type = 用户选择的 5(按回复) / 7(按发帖)。
    // - load_type：首载 1 / 翻页 2（Kotlin LoadMore 语义），不能恒为 0。
    // 热门(0)/精品(2) 走 -1（吧内默认列表）；仅"最新"(1) 用用户选择的排序，且 v12
    // frsPage 的 sort_type 是 0(按回复)/1(按发帖)（对齐 Kotlin default_sort_type 偏好
    // 与 getSortType），不是旧 JSON 接口的 5/7。
    const isDefaultList = routeTab === 0 || routeTab === 2 || isGood;
    const sortTypeNum = isDefaultList ? -1 : (sortType === ForumSortType.SEND_TIME ? 1 : 0);
    const loadType = page === 1 ? 1 : 2;
    // Add good classify if selected
    const cidNum = (isGood && goodClassifyId) ? parseInt(goodClassifyId, 10) : undefined;

    try {
    const { protoFrsPage } = lazyProtoClient();
    const { assertProtoSuccess, mapProtoThread } = lazyHelpers();
    const decoded = await protoFrsPage({
        kw: forumName,
        pn: page,
        sortType: sortTypeNum,
        isGood: !!isGood,
        goodClassifyId: cidNum,
        loadType,
      });
      if (seq !== forumLoadSeq) return;

      // 协议层校验（含业务错误码）统一走外层 catch：首屏的清桶/日志/抛出
      // 收敛为一次，翻页只告警不清桶（对齐 usePagedList 翻页失败语义）。
      assertProtoSuccess(decoded);

      // 首屏空 data 同样视为失败：原 `if (!data) return` 静默吞掉会让页面
      // 显示"暂无帖子"空态而非错误/重试态 → 并入 throw 路径。
      const data = decoded.data;
      if (!data) throw new Error('[ForumStore] frsPage 返回空 data');

      const forumData = data.forum;
      const rawThreadList = data.threadList ?? [];
      // proto.ts 解码类型即 Record<string, any>[]——不加本地 any 注解，
      // 契约以边界上的 loose 形状为准（mapProtoThread opts.userList 接受 any[]）。
      const userList = data.userList ?? [];
      const pageData = data.page;

      // ── Parse forum detail (Kotlin ForumPageBean.ForumBean) ──
      if (forumData && page === 1) {
        const signInUser = forumData.signInInfo?.userInfo ?? forumData.sign_in_info?.user_info;
        const detail: ForumDetail = {
          forumId: String(forumData.id ?? ''),
          forumName: forumData.name ?? forumName,
          avatar: forumData.avatar ?? '',
          memberCount: parseInt(String(forumData.memberNum ?? forumData.member_num ?? '0'), 10),
          threadCount: parseInt(String(forumData.threadNum ?? forumData.thread_num ?? '0'), 10),
          intro: forumData.slogan ?? forumData.intro ?? '',
          isLike: forumData.isLike === 1 || forumData.is_like === 1 || forumData.is_like === '1',
          levelId: parseInt(String(forumData.userLevel ?? forumData.levelId ?? forumData.level_id ?? '0'), 10) || undefined,
          levelName: forumData.levelName ?? forumData.level_name,
          curScore: parseFloat(String(forumData.curScore ?? forumData.cur_score ?? '0')),
          levelupScore: parseFloat(String(forumData.levelupScore ?? forumData.levelup_score ?? '1')),
          tbs: data.anti?.tbs ?? forumData.tbs ?? '',
          signInInfo: signInUser ? {
            isSignIn: (signInUser.isSignIn ?? signInUser.is_sign_in) === 1,
            contSignNum: parseInt(String(signInUser.contSignNum ?? signInUser.cont_sign_num ?? '0'), 10),
            userSignRank: parseInt(String(signInUser.userSignRank ?? signInUser.user_sign_rank ?? '0'), 10),
            signBonusPoint: parseInt(String(signInUser.signBonusPoint ?? signInUser.sign_bonus_point ?? '0'), 10),
          } : undefined,
        };
        // 2026-08-27 诊断：吧页等级数据是否进入（Lv 徽标/进度条的来源）
        if (__DEV__) {
          console.warn(
            `[forum] level: userLevel=${forumData?.userLevel ?? forumData?.level_id ?? '(none)'} levelName=${detail.levelName ?? '(none)'} curScore=${detail.curScore} levelupScore=${detail.levelupScore} isLike=${detail.isLike}`,
          );
        }

        // anti.tbs 到达时持久化到当前账号，并同步更新 authStore 账号对象。
        if (detail.tbs) {
          const authAccount = useAuthStore.getState().account;
          const targetUid = authAccount?.uid || '';
          setTbsSync(detail.tbs, targetUid || undefined);
          syncBackgroundSnapshot();
          if (authAccount) {
            useAuthStore.setState({
              account: { ...authAccount, tbs: detail.tbs },
            });
          }
        }

        // Parse good classify (Kotlin ForumBean.goodClassify)
        // 条目形状收窄为最小契约（服务端两种键名大小写）；unknown 输出统一 String 归一。
        const classifyList: GoodClassifyItem[] = (
          forumData.goodClassify ?? forumData.good_classify ?? []
        ).map(
          (c: {
            classId?: unknown;
            class_id?: unknown;
            id?: unknown;
            className?: unknown;
            class_name?: unknown;
            name?: unknown;
          }) => ({
            classId: String(c.classId ?? c.class_id ?? c.id ?? ''),
            className: String(c.className ?? c.class_name ?? c.name ?? ''),
          }),
        );

        set({
          currentForum: detail,
          goodClassify: classifyList,
          // proto.ts 解码类型为 Record<string, any>[]（loose 契约层）：赋值处
          // 边界断言一次收窄为最小契约形状，页面侧读 tabId/tabName 无需再 any。
          navTabInfo: (data.navTabInfo ?? null) as NavTabInfoItem[] | null,
        });
      }

      // ── Parse threads with author mapping (Kotlin FrsPageRepository) ──
      // 广告过滤（对齐 Kotlin FrsPageRepository 响应侧 `.filter { it.ala_info == null }`）：
      // mapProtoThread 已给广告/直播帖打 isAd 标记，这里在数据层剔除，
      // 保证三个标准 tab 的分桶缓存数组（含置顶帖来源桶）不含广告项。
      const threads: ThreadInfo[] = rawThreadList
        .map((item: any) =>
          mapProtoThread(item, { userList, forum: forumData, forumName }),
        )
        .filter((t: any) => !t.isAd);

      // Pagination (Kotlin ForumPageBean.PageBean)
      const hasMore = pageData
        ? (pageData.hasMore === 1)
        : (threads.length >= 20);

      // ── Store in per-tab state（桶键收敛：bucketKeyOf 单点判定） ──
      const bucket = bucketKeyOf(routeTab, isGood);
      if (page === 1) {
        set({
          [`${bucket}Threads`]: threads,
          [`${bucket}Page`]: page,
          [`${bucket}HasMore`]: hasMore,
        } as Partial<ForumState>);
      } else {
        set((s) => ({
          [`${bucket}Threads`]: appendBounded(
            s[`${bucket}Threads`] as ThreadInfo[],
            threads,
            MAX_THREADS_PER_LIST,
          ),
          [`${bucket}Page`]: page,
          [`${bucket}HasMore`]: hasMore,
        } as Partial<ForumState>));
      }
    } catch (error) {
      if (seq !== forumLoadSeq) return;
      if (page === 1) {
        // 首屏失败（网络/业务错误/空 data）：清桶一次 + 日志一次 + 向上抛出，
        // 页面才能进 ErrorState/重试入口（旧实现内层外层双清双日志，收敛为一次）。
        const failedBucket = bucketKeyOf(routeTab, isGood);
        set({ [`${failedBucket}Threads`]: [] } as Partial<ForumState>);
        console.error('[ForumStore] frsPage failed:', error);
        throw error;
      }
      // 翻页失败：保留已加载列表不清桶、不向上抛（避免整页 ErrorState 打断
      // 已滑入的内容），仅告警（对齐 usePagedList 翻页失败立法）。
      console.warn('[ForumStore] frsPage load-more failed:', error);
    }
  },

  setForumSortType: (sortType: ForumSortType) => {
    // 只清"最新"tab 独立缓存桶（对齐上方 :65 注释"最新 tab 独立缓存桶：
    // 与热门互不冲刷"）；热门/精品桶保留——外部并发页面依赖此行为，页面侧
    // 由后续批次处理。hasMore 复位与 resetForumData 对齐（true）。
    set({
      forumSortType: sortType,
      newestThreads: [],
      newestPage: 1,
      newestHasMore: true,
    });
  },

  // ── Tab switching ──
  setCurrentTab: (tab: number) => {
    set({ currentTab: tab });
  },

  resetForumData: () => {
    // 吧默认排序方式（设置-使用习惯 defaultSortType）：进新吧时从偏好播种。
    // 对位 Kotlin ForumPage 的 `dataStore.getInt("${forumName}_sort_type",
    // defaultSortType)`——RN 无按吧记忆，统一回落全局默认；吧内手动切换
    // （setForumSortType）在本吧会话内不受影响。
    const defaultSortType =
      usePreferencesStore.getState().preferences.defaultSortType === '1'
        ? ForumSortType.SEND_TIME
        : ForumSortType.REPLY_TIME;
    set({
      forumSortType: defaultSortType,
      latestThreads: [], goodThreads: [], newestThreads: [],
      latestPage: 1, goodPage: 1, newestPage: 1,
      latestHasMore: true, goodHasMore: true, newestHasMore: true,
      goodClassifyId: null, goodClassify: [], navTabInfo: null,
      currentTab: 0,
    });
  },

  setGoodClassifyId: (id: string | null) => {
    set({ goodClassifyId: id, goodThreads: [], goodPage: 1, goodHasMore: true });
  },

  // ── followForum — 对齐 Kotlin likeForum，必须传 tbs ──
  // Kotlin 关注成功后用 LikeForumResultBean.info 更新等级/经验/会员数，
  // 并把该吧加入主页关注列表（本地 store 驱动主页列表显示）。
  followForum: async (forumId: string, forumName: string) => {
    const tbs = getForumTbs(get().currentForum);
    if (!tbs) {
      throw new Error('缺少 tbs，无法关注贴吧');
    }
    try {
      const { likeForum } = lazyForumEndpoints();
      const result = await likeForum(forumId, forumName, tbs);
      // 契约（forumFollowed.ts）：关注成功必须失效关注列表缓存——否则
      // ≤5min 旧缓存会让首页下拉刷新把"刚关注的吧"覆盖回旧列表
      //（2026-08-27 真机：关注后首页看不到、刷新后仍看不到）。
      lazyForumFollowed().invalidateFollowedForumsCache();
      set((state) => {
        const exists = state.followedForums.some((f) => f.forumId === forumId);
        const followedForums = exists
          ? state.followedForums.map((f) =>
              f.forumId === forumId ? { ...f, isLike: true } : f,
            )
          : [
              // 新关注的吧不在关注列表里：插入（Kotlin 关注后主页列表即时可见）
              {
                forumId,
                forumName,
                avatar: state.currentForum?.avatar ?? '',
                slogan: state.currentForum?.intro ?? '',
                memberCount: result.memberSum ?? state.currentForum?.memberCount ?? 0,
                threadCount: state.currentForum?.threadCount ?? 0,
                levelId: result.levelId ?? 0,
                levelName: result.levelName ?? '',
                isLike: true,
                isSign: false,
              },
              ...state.followedForums,
            ];
        return {
          followedForums,
          currentForum:
            state.currentForum?.forumId === forumId
              ? {
                  ...state.currentForum,
                  isLike: true,
                  levelId: result.levelId ?? state.currentForum.levelId,
                  levelName: result.levelName ?? state.currentForum.levelName,
                  curScore: result.curScore ?? state.currentForum.curScore,
                  levelupScore:
                    result.levelupScore ?? state.currentForum.levelupScore,
                }
              : state.currentForum,
        };
      });
      return result;
    } catch (error) {
      console.error('[ForumStore] follow failed:', error);
      throw error;
    }
  },

  // ── unfollowForum — 对齐 Kotlin unlikeForum，必须传 tbs ──
  // Kotlin 取消关注后主页列表不再显示该吧 → 从关注列表移除
  unfollowForum: async (forumId: string, forumName: string) => {
    const tbs = getForumTbs(get().currentForum);
    if (!tbs) {
      throw new Error('缺少 tbs，无法取消关注');
    }
    try {
      const { unfavolike } = lazyForumEndpoints();
      await unfavolike(forumId, forumName, tbs);
      // 契约（forumFollowed.ts）：取关成功同样失效缓存（否则旧缓存回灌已取关的吧）
      lazyForumFollowed().invalidateFollowedForumsCache();
      set((state) => ({
        followedForums: state.followedForums.filter(
          (f) => f.forumId !== forumId,
        ),
        currentForum:
          state.currentForum?.forumId === forumId
            ? { ...state.currentForum, isLike: false }
            : state.currentForum,
      }));
    } catch (error) {
      console.error('[ForumStore] unfollow failed:', error);
      throw error;
    }
  },

  markForumSigned: (forumId: string, exp: number) => {
    set((state) => ({
      followedForums: state.followedForums.map((f) =>
        f.forumId === forumId ? { ...f, isSign: true } : f,
      ),
      currentForum:
        state.currentForum?.forumId === forumId
          ? {
              ...state.currentForum,
              signInInfo: {
                isSignIn: true,
                contSignNum: (state.currentForum.signInInfo?.contSignNum ?? 0) + 1,
                userSignRank: state.currentForum.signInInfo?.userSignRank ?? 0,
                signBonusPoint: (state.currentForum.signInInfo?.signBonusPoint ?? 0) + exp,
              },
            }
          : state.currentForum,
    }));
  },

  updateAllBuckets: (updater) => {
    set((state) => {
      const patch: Partial<ForumState> = {};
      for (const key of BUCKET_STATE_KEYS) {
        patch[key] = updater(state[key]);
      }
      return patch;
    });
  },
}));
