/**
 * ExploreTab 推荐/关注信息流段（从 app/(tabs)/explore.tsx 拆出）。
 *
 * 路由文件只保留分段壳；本组件持有信息流全部状态机：
 * SWR seed、TAB_RESELECT 重拉、不感兴趣折叠、视口尾预取、点赞四件套。
 */

import { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  View, StyleSheet, Text as RNText,
  DeviceEventEmitter, RefreshControl,
} from 'react-native';
import { LegendList, type LegendListRef } from '@legendapp/list/react-native';
import { useFocusEffect, useRouter } from 'expo-router';
import { useMutation } from '@tanstack/react-query';
import {
  VStack, Button, Label,
  ContentUnavailableView, Spacer,
  RNHostView, BottomSheet, Group,
} from '@expo/ui/swift-ui';
import {
  buttonStyle, buttonBorderShape, padding,
  presentationDetents, presentationDragIndicator,
} from '@expo/ui/swift-ui/modifiers';
import { hapticForScene } from '@/theme/hapticsMap';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { SymbolView } from '@/components/ui/SymbolView';
import { showToast } from '@/components/ui/Toast';
import { useThemeColors } from '@/theme/ThemeContext';
import { useAuthStore } from '@/stores/authStore';
import { useBlockFilter } from '@/hooks/useBlockFilter';
import { useAppPreference } from '@/hooks/useAppPreference';
import { useImageViewer } from '@/hooks/useImageViewer';
import { useSourceRevealConsumer } from '@/hooks/useViewerSourceReveal';
import { BlockManager } from '@/utils/BlockManager';
import { LoadType } from '@/types';
import type { FeedItem, ThreadInfo } from '@/types';
import { personalized as apiPersonalized, userLike as apiUserLike, consumeWarmSeed, hydrateFeedSnapshotSync } from '@/services/api/endpoints/feed';
import { isAdThreadInfo } from '@/services/api/endpoints/helpers';
import { submitDislike } from '@/services/api/endpoints/misc';
import { usePagedList } from '@/hooks/usePagedList';
import { useForumAvatarStore, forumAvatarKey } from '@/stores/forumAvatarCache';
import { useFeedCardActions } from '@/hooks/useFeedCardActions';
import { prefetchNextThreads, threadThumbs } from '@/utils/feedMedia';
import { TAB_RESELECT_EVENT } from '@/constants/events';
import TweetCard, { type TweetCardMenuAction, type TweetCardProps } from '@/components/feed/TweetCard';
import { EntranceRow } from '@/components/feed/EntranceRow';
import ImageViewer from '@/components/ImageViewer';
import { LoadMoreFooter } from '@/components/ui/LoadMoreFooter';
import { SkeletonList } from '@/components/ui/Skeleton';
import { CollapseRow } from '@/components/feed/CollapseRow';
import { SegmentFade } from '@/components/feed/SegmentFade';

// ── 信息流字段映射（轻量透传，见全量审查 #1）──
// endpoints.personalized()/userLike() 的 proto 主路径已直接产出 FeedItem
// （mapProtoThread 在 endpoints/feed.ts 内完成）；此前的双映射层（再包一层
// mapProtoThread + forum 卡重建）已删除。这里仅做形状防御 + 透传，JSON 兜底
// 路径若吐回非 FeedItem 形状的裸对象则丢弃（proto 失败兜底不渲染脏数据，
// 由主路径负责渲染）。
function mapFeedItem(raw: any): FeedItem | null {
  if (!raw || typeof raw !== 'object') return null;
  // 已是 FeedItem 包装（proto 主路径产物）→ 直接透传
  if (raw.type && (raw.threadInfo || raw.forumInfo)) return raw as FeedItem;
  return null;
}

export type ExploreSegment = 'personalized' | 'concern' | 'hot';

// ── 不感兴趣原因（对齐 Kotlin DislikeReason；personalized 接口未透出 dislikeResource 时的兑底列表）──
const DEFAULT_DISLIKE_REASONS: { dislikeId: string; dislikeReason: string }[] = [
  { dislikeId: '1', dislikeReason: '内容质量差' },
  { dislikeId: '2', dislikeReason: '标题党' },
  { dislikeId: '3', dislikeReason: '重复推荐' },
  { dislikeId: '4', dislikeReason: '内容不适' },
  { dislikeId: '5', dislikeReason: '广告太多' },
  { dislikeId: '7', dislikeReason: '不想看这个吧' },
];

// 信息流驻留上限：对齐 usePagedList 默认上限（约 200 条），控制 JS 数据驻留。
const MAX_FEED_ITEMS = 200;

// 聚焦自动刷新的数据新鲜期：5 分钟内切回 Tab 不重拉（stale-while-revalidate）。
const FOCUS_REFRESH_STALE_MS = 5 * 60 * 1000;

// 信息流帖卡「×」菜单项：模块级常量 —— 若在 renderItem 内联数组字面量，
// 每帧新建引用会击穿 TweetCard 的 React.memo，点赞/加载更多时整屏重渲。
const TWEET_MENU_OPTIONS: TweetCardMenuAction[] = ['dislike', 'block', 'report', 'copy-title'];

// ── 信息流单行：FeedRow（memo 化，collapsing 只影响命中行自身） ──
// 抽出后 renderItem 不再因 collapsingId 翻转而重渲所有 cell——不感兴趣
// 折叠期间只有目标行的 FeedRow props 变化，其余行在 memo 比较处短路。
const FeedRow = memo(function FeedRow({
  item,
  index,
  animateEntry,
  collapsing,
  onCollapseEnd,
  onImagePress,
  onLike,
  onShare,
  onMenuAction,
}: {
  item: FeedItem;
  index: number;
  animateEntry: boolean;
  collapsing: boolean;
  onCollapseEnd: () => void;
  onImagePress: TweetCardProps['onImagePress'];
  onLike: (thread: ThreadInfo) => void;
  onShare: (thread: ThreadInfo) => void;
  onMenuAction: (action: TweetCardMenuAction, thread: ThreadInfo) => void;
}) {
  let inner: React.ReactNode = null;
  if ((item.type === 'thread' || item.type === 'video_thread') && item.threadInfo) {
    // 统一卡片：与吧内列表同款 TweetCard（forum 变体，右上角 × 菜单），
    // 动态流扩展菜单项：不感兴趣/屏蔽作者/举报/复制标题
    inner = (
      <EntranceRow index={index} animateEntry={animateEntry}>
        <TweetCard
          thread={item.threadInfo}
          timeType="create"
          showForumPill
          imageContextMenu
          closeMenuOptions={TWEET_MENU_OPTIONS}
          onImagePress={onImagePress}
          onLike={onLike}
          onShare={onShare}
          onMenuAction={onMenuAction}
        />
      </EntranceRow>
    );
    // 防御：threadInfo 缺失时渲染空位（映射层已收敛为透传，正常不可达；
    // 仅防脏数据经 JSON 兜底路径混入导致崩溃）
  }
  return (
    <CollapseRow collapsing={collapsing} onCollapseEnd={onCollapseEnd}>
      {inner}
    </CollapseRow>
  );
});

// ── 推荐/关注 信息流（自动懒加载） ──
// active：当前 SegmentPager 可见段标记（由 ExploreScreen 传入）——TAB_RESELECT
// 时仅当前激活段响应重拉，隐藏段保持 SWR stale 语义、不参与三路并发加载。
export function FeedContent({ segment, active }: { segment: 'personalized' | 'concern'; active: boolean }) {
  const { colors } = useThemeColors();
  const isLoggedIn = useAuthStore((s) => s.isLoggedIn);
  const { blockedWords, blockedUsers } = useBlockFilter();
  const exploreAutoRefresh = useAppPreference('exploreAutoRefresh', true);
  // 广告/直播过滤开关（Kotlin 铁律判据的开关化；默认开=行为不变）。
  // useAppPreference 的 defaultValue 已兜底，返回必非 undefined（见全量审查 #12）。
  const filterAdThreads = useAppPreference('filterAdThreads', true)!;
  const router = useRouter();
  const imageViewer = useImageViewer();
  // 不感兴趣面板状态
  const [dislikeTarget, setDislikeTarget] = useState<FeedItem | null>(null);
  const [selectedReasons, setSelectedReasons] = useState<string[]>([]);
  // 关注流（userLike）分页游标 — 对齐 Kotlin ConcernViewModel：userLikeFlow(pageTag, lastRequestUnix, loadType)
  const pageTagRef = useRef('');
  // 聚焦刷新的 stale 判定基准（0 = 从未加载过，聚焦必拉）
  const lastLoadedAtRef = useRef(0);
  const pagedFetcher = useCallback(
    async (p: number, params: { segment: 'personalized' | 'concern'; isLoggedIn: boolean; blockedWords: any[]; blockedUsers: any[]; filterAdThreads: boolean }, signal?: AbortSignal) => {
      if (params.segment === 'concern' && !params.isLoggedIn) {
        return { items: [] as FeedItem[], hasMore: false };
      }
      const loadType = p === 1 ? LoadType.REFRESH : LoadType.LOAD_MORE;
      let result: { items: FeedItem[]; hasMore: boolean };
      if (params.segment === 'personalized') {
        result = await apiPersonalized(loadType, p, signal);
      } else {
        const tag = p === 1 ? '' : pageTagRef.current;
        const res = await apiUserLike(tag || undefined, undefined, loadType, signal);
        pageTagRef.current = res.pageTag ?? '';
        result = res;
      }
      const feedItems = (result.items ?? [])
        .map((raw: any) => mapFeedItem(raw))
        .filter((item: FeedItem | null): item is FeedItem => item !== null);
      const visibleItems = feedItems.filter((item) => {
        const info = item.threadInfo;
        if (!info) return true;
        // 广告过滤（对齐 Kotlin PersonalizedRepository/PersonalizedViewModel
        // 响应侧 ala_info 过滤）：推荐/关注流默认不渲染广告/直播卡片，
        // filterAdThreads=false 时原样展示（2026-08-28 设置开关化）
        if (params.filterAdThreads && isAdThreadInfo(info)) return false;
        const text = `${info.title || ''} ${info.abstract || ''}`;
        if (BlockManager.shouldBlockContent(text, params.blockedWords)) return false;
        if (info.authorId && BlockManager.shouldBlockUser(info.authorId, info.authorName || null, params.blockedUsers)) return false;
        return true;
      });
      return { items: visibleItems, hasMore: result.hasMore, nextPage: p + 1 };
    },
    [],
  );
  // 首屏 seed（SWR）：内存预热优先，磁盘快照兜底；仅首次挂载消费一次
  // （FeedContent 常挂载，segment 切换不重挂载）。网络首屏返回后整体替换。
  // seed 先过 ala_info 过滤（与 pagedFetcher 的 visibleItems 同判据，Kotlin
  // PersonalizedViewModel 铁律）：预热/快照在 feed.ts 保存时未过滤，且
  // exploreAutoRefresh=false 时 seed 不会被聚焦刷新替换 → 直播/广告卡片
  // 此前会一直滞留首屏（2026-08-28 修复）。
  // useState 惰性初值：只在首帧渲染求值（等价旧的渲染期 ref 写入 + 同步读盘，
  // 语义不变，但不再在渲染期直接写 ref）。
  const [feedSeed] = useState<FeedItem[] | null>(() => {
    const seed = segment === 'personalized' ? (consumeWarmSeed() ?? hydrateFeedSnapshotSync()) : null;
    if (!seed) return null;
    const filtered = seed.filter(
      (it) =>
        !(it.type === 'thread' || it.type === 'video_thread') ||
        !filterAdThreads ||
        !isAdThreadInfo(it.threadInfo),
    );
    return filtered;
  });
  const paged = usePagedList<FeedItem, { segment: 'personalized' | 'concern'; isLoggedIn: boolean; blockedWords: any[]; blockedUsers: any[]; filterAdThreads: boolean }>({
    fetcher: pagedFetcher,
    params: { segment, isLoggedIn, blockedWords, blockedUsers, filterAdThreads },
    maxItems: MAX_FEED_ITEMS,
    initialItems: feedSeed ?? undefined,
  });
  const { items, loading, error, hasMore, loadingMore, refreshing, load, loadMore, refresh, setItems } = paged;

  // 首屏入场标记：仅在数据首次到达的那次渲染批次做 stagger 入场，
  // 之后的下拉刷新 / 加载更多 / 分页切换均不重播（配合 EntranceRow 内 ran ref）。
  const entranceDoneRef = useRef(false);
  useEffect(() => {
    if (items.length > 0) entranceDoneRef.current = true;
  }, [items.length]);

  // 吧头像实时拉取订阅（2026-08-28）：feed.ts 出口 ensureAvatars 对回填后
  // 仍缺失的吧按名拉取（/mo/q/search/forum）；这里订阅 store，头像逐条到达
  // 时合并进渲染数据（keyExtractor 以 id 稳定，不会错位/重挂）。拉取前
  // 保持灰底首字兜底（TweetCard ForumPill 既有行为）。
  const avatarMap = useForumAvatarStore((s) => s.avatars);
  const decoratedItems = useMemo(() => {
    if (Object.keys(avatarMap).length === 0) return items;
    return items.map((it) => {
      const t = it.threadInfo;
      if (!t || t.forumAvatar) return it;
      const key = forumAvatarKey(t);
      if (!key) return it;
      const entry = avatarMap[key];
      if (!entry?.avatar) return it;
      return { ...it, threadInfo: { ...t, forumAvatar: entry.avatar } };
    });
  }, [items, avatarMap]);

  // 列表最新数据的渲染期镜像：点赞/屏蔽等回调据此读取最新状态，避免闭包旧值。
  const itemsRef = useRef<FeedItem[]>([]);
  useEffect(() => {
    itemsRef.current = items;
  }, [items]);

  // 视口尾预取：滚动时对尾后 6 条缩略图发起 prefetch（expo-image 内部去重）
  const feedViewabilityConfig = useRef({ itemVisiblePercentThreshold: 50 }).current;
  const feedOnViewableItemsChanged = useRef(
    (info: { viewableItems: { index: number | null }[] }) => {
      let tail = -1;
      for (const v of info.viewableItems) {
        if (typeof v.index === 'number' && v.index > tail) tail = v.index;
      }
      prefetchNextThreads(
        itemsRef.current,
        tail,
        (it: FeedItem) => (it.threadInfo ? threadThumbs(it.threadInfo) : []),
      );
    },
  ).current;

  // 不感兴趣折叠：动画期间数据保持在位，完成后再移除
  const [collapsingId, setCollapsingId] = useState<string | null>(null);
  const opacityTargetRef = useRef<FeedItem | null>(null);
  // 折叠动画兜底定时器：CollapseRow 的 withTiming 完成回调在本仓曾实证
  // 偶发不触发（reanimated 三坑：回调被覆盖/不推进），不能赌动画回调——
  // 动画窗口结束后由 JS 定时器强制移除（2026-09-01 二轮根治）
  const collapseFallbackTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // 双击重选刷新：回顶动画后延迟触发 pull-refresh（spinner 可见性），
  // 卸载/失效时跳过；动画期间源（scrollToOffset）与刷新互不阻塞。
  const mountedRef = useRef(true);
  const tapRefreshTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      if (collapseFallbackTimerRef.current) clearTimeout(collapseFallbackTimerRef.current);
    };
  }, []);

  // 打开“不感兴趣”原因面板
  const handleDislikePress = useCallback((item: FeedItem) => {
    hapticForScene('sheet-present');
    setSelectedReasons([]);
    setDislikeTarget(item);
  }, []);

  const toggleReason = useCallback((id: string) => {
    hapticForScene('toggle');
    setSelectedReasons((prev) => (prev.includes(id) ? prev.filter((r) => r !== id) : [...prev, id]));
  }, []);

  const dislikeMutation = useMutation({
    mutationFn: submitDislike,
    onSuccess: () => {
      hapticForScene('action-success');
      showToast('已减少此类内容推荐');
      // 折叠动画在位播放：卡片先压扁收起，动画完成（handleCollapseEnd）
      // 才真正从列表移除 —— 列表逻辑不提前动数据，LegendList 布局稳定
      const target = dislikeTarget;
      setDislikeTarget(null);
      setSelectedReasons([]);
      if (!target) return;
      const targetId = target.threadInfo?.id || '';
      if (!targetId) {
        // 无可用行 key：折叠动画无从触发，引用移除兜底（2026-09-01）
        setItems((prev) => prev.filter((i) => i !== target));
        return;
      }
      opacityTargetRef.current = target;
      setCollapsingId(`${target.type}-${targetId}`);
      // 兜底（二轮）：不管 CollapseRow 动画回调是否触发，360ms（动画
      // 280ms 之后）强制按 id 移除并复位折叠态 —— 用户实证"有 toast 但
      // 卡片永不消失"两次，根因在动画完成回调链，不赌它
      if (collapseFallbackTimerRef.current) clearTimeout(collapseFallbackTimerRef.current);
      collapseFallbackTimerRef.current = setTimeout(() => {
        collapseFallbackTimerRef.current = null;
        setItems((prev) => prev.filter((i) => i.threadInfo?.id !== targetId));
        setCollapsingId(null);
        if (opacityTargetRef.current === target) opacityTargetRef.current = null;
      }, 360);
    },
    onError: (error) => {
      hapticForScene('action-fail');
      // 失败保持面板打开（可重试/取消），绝不静默关闭 —— 2026-09-01
      // 用户反馈"提交后不知道成没成功"，此前 onError 无声关面板
      showToast(error instanceof Error ? error.message : '提交失败，请稍后重试');
    },
  });

  // 折叠完成后移除目标行。⚠️ 不能用引用相等：菜单路径（TweetCard
  // 右上角 × → handleTweetMenuAction）会新建 FeedItem 包装对象，与列表内
  // 的 item 不是同一引用，filter(i => i !== target) 恒删不掉 —— 折叠动画
  // 结束后行恢复完整（collapsingId 复位 → CollapseRow 同步回弹），观感
  // 就是"卡片不会消失"（2026-09-01 真机实证）。改按线程 id 移除。
  const handleCollapseEnd = useCallback(() => {
    if (collapseFallbackTimerRef.current) {
      clearTimeout(collapseFallbackTimerRef.current);
      collapseFallbackTimerRef.current = null;
    }
    const target = opacityTargetRef.current;
    opacityTargetRef.current = null;
    setCollapsingId(null);
    if (!target) return;
    const targetId = target.threadInfo?.id;
    setItems((prev) =>
      targetId
        ? prev.filter((i) => i.threadInfo?.id !== targetId)
        : prev.filter((i) => i !== target),
    );
  }, [setItems]);

  const handleSubmitDislike = useCallback(() => {
    if (!dislikeTarget) return;
    dislikeMutation.mutate({
      threadId: dislikeTarget.threadInfo?.id ?? '',
      dislikeIds: selectedReasons.join(',') || '1',
      forumId: dislikeTarget.threadInfo?.forumId,
      clickTime: Date.now(),
    });
  }, [dislikeTarget, selectedReasons, dislikeMutation]);

  // 面板「取消」：显式关闭（面板外点按/下滑关闭走 onIsPresentedChange）
  const handleCloseDislike = useCallback(() => {
    hapticForScene('press');
    setDislikeTarget(null);
    setSelectedReasons([]);
  }, []);

  const startLoad = useCallback((p = 1) => {
    pageTagRef.current = '';
    load(p);
    lastLoadedAtRef.current = Date.now();
  }, [load]);

  const listRef = useRef<LegendListRef | null>(null);
  // 被遮挡源图揭示（2026-08-31）：查看器关闭后滚动列表使点击时半遮的
  // 卡片对齐屏缘（顶栏下/屏底）
  useSourceRevealConsumer(listRef, decoratedItems, (it: unknown) => {
    const f = it as FeedItem;
    return f.threadInfo?.id ?? f.topicInfo?.topicId ?? f.forumInfo?.forumId;
  });

  // 下拉刷新：走 refresh 模式（refreshing 置 true，spinner 有状态可依）
  const handleRefresh = useCallback(async () => {
    pageTagRef.current = '';
    await refresh();
    lastLoadedAtRef.current = Date.now();
    hapticForScene('toggle');
  }, [refresh]);

  useEffect(() => {
    const sub = DeviceEventEmitter.addListener(TAB_RESELECT_EVENT, (tabName: string) => {
      // 仅当前激活段响应重选刷新：隐藏段（SegmentPager 内仍挂载）不并发重拉，
      // 保持 SWR stale 语义，切回时由 useFocusEffect/手动重拉兜底。
      if (tabName === 'explore' && active) {
        // 双击底栏"动态"：先回顶（动画），再走 handleRefresh（refreshing 态 →
        // 顶栏出现下拉刷新 spinner；直接用 load(1) 无刷新动画，2026-08-27 真机反馈）
        listRef.current?.scrollToOffset({ offset: 0, animated: true });
        tapRefreshTimerRef.current = setTimeout(() => {
          tapRefreshTimerRef.current = null;
          if (mountedRef.current) void handleRefresh();
        }, 260);
      }
    });
    return () => {
      sub.remove();
      if (tapRefreshTimerRef.current) clearTimeout(tapRefreshTimerRef.current);
    };
  }, [active, handleRefresh]);

// 聚焦自动刷新改为 stale-while-revalidate：数据 5 分钟内新鲜就不重拉
  //（旧实现每次切回 Tab 都全量刷新 page 1，流量/耗电/列表跳动三重代价）。
  // 开关语义=exploreAutoRefresh 同时约束推荐流与关注流：关闭后已有数据的
  // 焦点恢复不自动重拉（关注流的无条件刷新分支为 2026-08-29 修复——此前
  // 退后台很久回前台点动态必刷，与设置不符）；但 items 为空（首挂载/无数据）
  // 时仍必须拉——关注流无 SWR seed，若也卡住开关，关掉自动刷新后关注流
  // 永远是空白页。手动下拉/双击刷新不受影响。
  useFocusEffect(
    useCallback(() => {
      const stale = Date.now() - lastLoadedAtRef.current > FOCUS_REFRESH_STALE_MS;
      if (stale && (exploreAutoRefresh || items.length === 0)) {
        if (segment !== 'concern' || isLoggedIn) {
          startLoad(1);
        }
      }
    }, [exploreAutoRefresh, segment, isLoggedIn, startLoad, items.length]),
  );

  const handleLoadMore = useCallback(() => {
    if (!hasMore || loadingMore || loading) return;
    loadMore();
  }, [hasMore, loadingMore, loading, loadMore]);

  // 卡片动作四件套收敛到共享 hook（thermo Z3-B）：点赞竞态基准走 itemsRef
  // 最新态；dislike 的原因面板仍是本页专属逻辑，保留在 dispatch 内。
  const feedActions = useFeedCardActions({
    applyLike: (id, nextAgree) =>
      setItems((prev) => prev.map((i) =>
        i.threadInfo?.id === id && i.threadInfo
          ? {
              ...i,
              threadInfo: {
                ...i.threadInfo,
                hasAgree: nextAgree,
                zanNum: Math.max(0, (i.threadInfo.zanNum ?? 0) + (nextAgree ? 1 : -1)),
              },
            }
          : i,
      )),
    removeByAuthor: (authorId) =>
      setItems((prev) => prev.filter((i) => i.threadInfo?.authorId !== authorId)),
    getLatestHasAgree: (id) =>
      itemsRef.current.find((i) => i.threadInfo?.id === id)?.threadInfo?.hasAgree,
  });

  const handleTweetMenuAction = useCallback((action: TweetCardMenuAction, thread: ThreadInfo) => {
    switch (action) {
      case 'dislike': {
        const feedItem: FeedItem = { type: 'thread', threadInfo: thread };
        handleDislikePress(feedItem);
        break;
      }
      case 'block':
        void feedActions.blockAuthor(thread);
        break;
      case 'report':
        void feedActions.report(thread);
        break;
      case 'copy-title':
        feedActions.copyTitle(thread);
        break;
    }
  }, [handleDislikePress, feedActions]);

  const renderItem = useCallback(({ item, index }: { item: FeedItem; index: number }) => {
    const id = item.threadInfo?.id || item.forumInfo?.forumId || item.topicInfo?.topicId || '';
    const itemKey = id ? `${item.type}-${id}` : `item-${index}`;
    return (
      <FeedRow
        item={item}
        index={index}
        animateEntry={!entranceDoneRef.current}
        collapsing={collapsingId === itemKey}
        onCollapseEnd={handleCollapseEnd}
        onImagePress={imageViewer.handleImagePress}
        onLike={feedActions.like}
        onShare={feedActions.share}
        onMenuAction={handleTweetMenuAction}
      />
    );
  }, [imageViewer.handleImagePress, feedActions.like, feedActions.share, handleTweetMenuAction, collapsingId, handleCollapseEnd]);

  const keyExtractor = useCallback((item: FeedItem, index: number) => {
    const id = item.threadInfo?.id || item.forumInfo?.forumId || item.topicInfo?.topicId || '';
    // 兜底前缀固定 forum-（对齐 getItemType 的回收类型命名，减少类型串扰）
    return id ? `${item.type}-${id}` : `forum-${index}`;
  }, []);

  const getItemType = useCallback((item: FeedItem) => {
    // 帖子卡片按 有图/纯文字 细分回收类型（高度差异大，提升复用命中率）
    if (item.type === 'thread' || item.type === 'video_thread') {
      return item.threadInfo?.mediaList && item.threadInfo.mediaList.length > 0
        ? 'tweet-media'
        : 'tweet-text';
    }
    return item.type;
  }, []);

  const listFooter = useMemo(
    () => (
      <LoadMoreFooter
        hasMore={hasMore}
        loading={loadingMore}
        colors={colors}
        onLoadMore={handleLoadMore}
      />
    ),
    [loadingMore, hasMore, colors, handleLoadMore],
  );

  // 未登录关注（Kotlin 未登录时隐藏关注 tab；RN 降级为提示登录）
  // 布局对齐关注页：VStack spacing=0 + 按钮 bottom padding 80，登录按钮悬浮居中
  if (segment === 'concern' && !isLoggedIn) {
    return (
      <VStack spacing={0}>
        <Spacer />
        <ContentUnavailableView
          systemImage="person.crop.circle.badge.questionmark"
          title="请先登录"
          description="登录后查看关注动态"
        />
        <Button
          onPress={() => router.push('/login')}
          modifiers={[buttonStyle('glassProminent'), buttonBorderShape('capsule'), padding({ bottom: 80 })]}
        >
          <Label title="登录百度账号" systemImage="person.crop.circle.badge.checkmark" />
        </Button>
        <Spacer />
      </VStack>
    );
  }

  // 加载中：骨架屏（thread 变体，1:1 模拟信息流卡片）
  if (loading && items.length === 0) {
    return (
      <SkeletonList
        variant="thread"
        count={8}
        style={styles.feedSkeleton}
      />
    );
  }

  // 错误
  if (error && items.length === 0) {
    return (
      <VStack alignment="center" spacing={16}>
        <Spacer />
        <ContentUnavailableView
          systemImage="wifi.exclamationmark"
          title="加载失败"
          description={error}
        />
        <Button onPress={() => startLoad(1)}>
          <Label title="重试" systemImage="arrow.clockwise" />
        </Button>
        <Spacer />
      </VStack>
    );
  }

  // 空态
  if (items.length === 0) {
    return (
      <ContentUnavailableView
        systemImage="tray"
        title="暂无内容"
        description={segment === 'personalized' ? '去关注一些贴吧获取推荐' : '暂无关注动态'}
      />
    );
  }

  return (
    <VStack spacing={0}>
      <RNHostView>
        <View style={{ flex: 1 }}>
          {/* LegendList v3：自动尺寸估算（无需 estimatedItemSize），
              drawDistance + getItemType（按卡片形态细分）做分批与回收控制。
              分段切换时 SegmentFade 负责 crossfade，下拉刷新走 refresh 模式。 */}
          <SegmentFade segment={segment}>
            <LegendList
              recycleItems
              ref={listRef}
              data={decoratedItems}
              renderItem={renderItem}
              keyExtractor={keyExtractor}
              getItemType={getItemType}
              drawDistance={400}
              viewabilityConfig={feedViewabilityConfig}
              onViewableItemsChanged={feedOnViewableItemsChanged}
              contentContainerStyle={{ paddingVertical: 8, paddingBottom: 24 }}
              decelerationRate="normal"
              onEndReached={handleLoadMore}
              onEndReachedThreshold={0.4}
              ListFooterComponent={listFooter}
              refreshControl={
                <RefreshControl
                  refreshing={refreshing}
                  onRefresh={handleRefresh}
                  tintColor={colors.primary}
                />
              }
            />
          </SegmentFade>
          <ImageViewer
            images={imageViewer.imageViewerImages}
            initialIndex={imageViewer.imageViewerIndex}
            visible={imageViewer.imageViewerVisible}
            onClose={imageViewer.closeImageViewer}
            sourceFrame={imageViewer.imageViewerSourceFrame}
            imageOrigins={imageViewer.imageViewerOrigins}
            contextTitle={imageViewer.imageViewerContextTitle}
            imageMeta={imageViewer.imageViewerMeta}
            imagePreviews={imageViewer.imageViewerPreviews}
          />
        </View>
      </RNHostView>

      {/* 不感兴趣原因面板（2026-09-01 重布局：定高 detent 贴内容消除空白；
          提交/取消用 RN 触控（HdrPressable），与 ForumChip 同规避 SwiftUI
          Button 事件偶发不触发；选中态勾选 + 禁用态 + 成功/失败 toast） */}
      <BottomSheet
        isPresented={dislikeTarget !== null}
        onIsPresentedChange={(presented) => {
          if (!presented) {
            setDislikeTarget(null);
            setSelectedReasons([]);
          }
        }}
      >
        <Group modifiers={[presentationDetents([{ height: 372 }]), presentationDragIndicator('visible')]}>
          <RNHostView matchContents>
            <View style={styles.dislikePanel}>
              <RNText style={[styles.dislikeTitle, { color: colors.text }]}>不感兴趣</RNText>
              <RNText style={[styles.dislikeSubtitle, { color: colors.textTertiary }]}>
                我们会减少这类内容的推荐
              </RNText>
              <View style={styles.dislikeChips}>
                {DEFAULT_DISLIKE_REASONS.map((reason) => {
                  const selected = selectedReasons.includes(reason.dislikeId);
                  return (
                    <HdrPressable
                      key={reason.dislikeId}
                      onPress={() => toggleReason(reason.dislikeId)}
                      flashRadius={20}
                      effect="subtle"
                      style={[
                        styles.dislikeChip,
                        selected
                          ? { backgroundColor: colors.primary, borderColor: colors.primary }
                          : { backgroundColor: colors.surfaceSecondary, borderColor: 'transparent' },
                      ]}
                      accessibilityRole="button"
                      accessibilityState={selected ? { selected: true } : {}}
                      accessibilityLabel={reason.dislikeReason}
                    >
                      {selected ? (
                        <SymbolView name="checkmark" size={12} weight="bold" tintColor={colors.textOnPrimary} />
                      ) : null}
                      <RNText
                        style={[
                          styles.dislikeChipText,
                          { color: selected ? colors.textOnPrimary : colors.textSecondary },
                        ]}
                      >
                        {reason.dislikeReason}
                      </RNText>
                    </HdrPressable>
                  );
                })}
              </View>
              <HdrPressable
                disabled={selectedReasons.length === 0}
                onPress={handleSubmitDislike}
                flashRadius={24}
                style={[
                  styles.dislikeSubmit,
                  { backgroundColor: colors.primary, opacity: selectedReasons.length === 0 ? 0.45 : 1 },
                ]}
                accessibilityRole="button"
                accessibilityState={selectedReasons.length === 0 ? { disabled: true } : {}}
              >
                <SymbolView name="hand.thumbsdown.fill" size={15} tintColor={colors.textOnPrimary} />
                <RNText style={[styles.dislikeSubmitText, { color: colors.textOnPrimary }]}>提交</RNText>
              </HdrPressable>
              <HdrPressable onPress={handleCloseDislike} effect="subtle" style={styles.dislikeCancel} hitSlop={8}>
                <RNText style={[styles.dislikeCancelText, { color: colors.textSecondary }]}>取消</RNText>
              </HdrPressable>
            </View>
          </RNHostView>
        </Group>
      </BottomSheet>
    </VStack>
  );
}

const styles = StyleSheet.create({
  // 容器契约与列表一致：卡片贴边 10pt、列表 paddingVertical 8（2026-08-29 错位修复）
  feedSkeleton: { paddingHorizontal: 10, paddingTop: 8, paddingBottom: 24 },
  // 不感兴趣原因面板（2026-09-01 重布局：紧凑贴内容、双列格栅胶囊、
  // 全宽提交 + 居中取消）
  dislikePanel: { paddingHorizontal: 20, paddingTop: 10, paddingBottom: 24 },
  dislikeTitle: { fontSize: 18, fontWeight: '700', letterSpacing: 0 },
  dislikeSubtitle: { fontSize: 13, marginTop: 4 },
  dislikeChips: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 10,
    marginTop: 18,
  },
  dislikeChip: {
    flexGrow: 1,
    flexBasis: '45%',
    minHeight: 40,
    paddingHorizontal: 16,
    borderRadius: 20,
    borderCurve: 'continuous',
    borderWidth: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
  },
  dislikeChipText: { fontSize: 14, fontWeight: '600', letterSpacing: 0 },
  dislikeSubmit: {
    marginTop: 22,
    height: 46,
    borderRadius: 23,
    borderCurve: 'continuous',
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 8,
  },
  dislikeSubmitText: { fontSize: 16, fontWeight: '700' },
  dislikeCancel: { marginTop: 8, height: 40, alignItems: 'center', justifyContent: 'center' },
  dislikeCancelText: { fontSize: 15, fontWeight: '500' },
});
