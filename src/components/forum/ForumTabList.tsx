/**
 * 吧页单 tab 列表（segment 下方 pager 的一页，从 app/forum/[name].tsx 拆出）。
 *
 * 各自独立 LegendList + 独立滚动位置；数据读 forumStore 分桶（200 条封顶），
 * 渲染层统一过滤广告/屏蔽词/置顶帖。
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { RefreshControl } from 'react-native';
import { LegendList } from '@legendapp/list/react-native';

import { EmptyState } from '@/components/ui/EmptyState';
import { LoadMoreFooter } from '@/components/ui/LoadMoreFooter';
import { SkeletonList } from '@/components/ui/Skeleton';
import TweetCard from '@/components/feed/TweetCard';
import { EntranceRow } from '@/components/feed/EntranceRow';
import { useBlockFilter } from '@/hooks/useBlockFilter';
import { useAppPreference } from '@/hooks/useAppPreference';
import { FEED_ADAPTIVE_RENDER } from '@/constants/listPerf';
import { useForumStore } from '@/stores/forumStore';
import { prefetchNextThreads, threadThumbs } from '@/utils/feedMedia';
import { BlockManager } from '@/utils/BlockManager';
import { isAdThreadInfo } from '@/services/api/endpoints/helpers';
import type { ThreadInfo } from '@/types';

// 模块级列表回调（与 SearchResultList 同规范）：内联箭头每次渲染新建引用，
// LegendList 内部按需调用无碍，但保持全库一致的稳定函数引用。
const threadKeyExtractor = (item: ThreadInfo) => item.id;
const threadItemType = (item: ThreadInfo) =>
  item.mediaList && item.mediaList.length > 0 ? 'tweet-media' : 'tweet-text';

export const ForumTabList = React.memo(function ForumTabList({
  tab,
  timeType,
  colors,
  insets,
  isFocused,
  loaded,
  header,
  refreshing,
  loadingMore,
  animateEntry,
  onRefresh,
  onLoadMore,
  onScroll,
  onAgree,
  onShare,
  onMenuAction,
  onImagePress,
  setListRef,
  loadTab,
}: {
  tab: number;
  timeType: 'create' | 'last';
  colors: any;
  insets: any;
  isFocused: boolean;
  loaded: boolean;
  /** 列表头元素（吧卡片/置顶/segment/排序行）：随列表原生滚动，滑到顶自然退出 */
  header: React.ReactElement | null;
  refreshing: boolean;
  loadingMore: boolean;
  animateEntry: boolean;
  onRefresh: () => void;
  onLoadMore: () => void;
  onScroll: (e: any) => void;
  onAgree: (item: ThreadInfo) => void;
  onShare: (item: ThreadInfo) => void;
  onMenuAction: (action: string, item: ThreadInfo) => void;
  onImagePress: any;
  setListRef: (ref: any) => void;
  loadTab: () => Promise<void>;
}) {
  const threads = useForumStore(
    tab === 0 ? (s) => s.latestThreads : tab === 1 ? (s) => s.newestThreads : (s) => s.goodThreads,
  );
  const hasMore = useForumStore(
    tab === 0 ? (s) => s.latestHasMore : tab === 1 ? (s) => s.newestHasMore : (s) => s.goodHasMore,
  );
  const { blockedWords, blockedUsers } = useBlockFilter();

  // tab 0 的数据由页面级初始加载负责（loaded 翻转前已发起），不重复请求
  const attemptedRef = useRef(tab === 0);
  const [tabLoading, setTabLoading] = useState(false);
  useEffect(() => {
    if (attemptedRef.current || !loaded) return;
    attemptedRef.current = true;
    if (threads.length === 0) {
      setTabLoading(true);
      loadTab().finally(() => setTabLoading(false));
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- 仅首次 loaded 翻转时尝试一次
  }, [loaded]);

  // 渲染层统一过滤（广告过滤与 blockedWords 逻辑并列）
  const filterAdThreads = useAppPreference('filterAdThreads', true);
  const listThreads = useMemo(() => {
    const hasBlock = blockedWords.length > 0 || blockedUsers.length > 0;
    const filtered = hasBlock
      ? threads.filter((t: ThreadInfo) => {
          if (filterAdThreads && isAdThreadInfo(t)) return false;
          const text = `${t.title || ''} ${t.abstract || ''}`;
          if (BlockManager.shouldBlockContent(text, blockedWords)) return false;
          if (t.authorId && BlockManager.shouldBlockUser(t.authorId, t.authorName || null, blockedUsers)) return false;
          return true;
        })
      : threads.filter((t) => !filterAdThreads || !isAdThreadInfo(t));
    return filtered.filter((t) => !t.isTop);
  }, [threads, blockedWords, blockedUsers, filterAdThreads]);

  // 视口尾预取（同 explore）：滚动时对尾后 6 条缩略图 prefetch
  const listThreadsRef = useRef(listThreads);
  listThreadsRef.current = listThreads;
  const viewabilityConfig = useRef({ itemVisiblePercentThreshold: 50 }).current;
  const onViewableItemsChanged = useRef(
    (info: { viewableItems: { index: number | null }[] }) => {
      let tail = -1;
      for (const v of info.viewableItems) {
        if (typeof v.index === 'number' && v.index > tail) tail = v.index;
      }
      prefetchNextThreads(listThreadsRef.current, tail, threadThumbs);
    },
  ).current;

  const renderItem = useCallback(
    ({ item, index }: { item: ThreadInfo; index: number }) => (
      <EntranceRow index={index} animateEntry={animateEntry}>
        <TweetCard
          thread={item}
          timeType={timeType}
          imageContextMenu
          onMenuAction={onMenuAction}
          onImagePress={onImagePress}
          onLike={onAgree}
          onShare={onShare}
        />
      </EntranceRow>
    ),
    [timeType, animateEntry, onAgree, onShare, onImagePress, onMenuAction],
  );

  const listEmpty = useCallback(
    () =>
      loaded && listThreads.length === 0 ? (
        <EmptyState title="暂无帖子" description="这个吧还没有帖子" icon="tray" />
      ) : null,
    [loaded, listThreads.length],
  );
  const listFooter = useCallback(
    () => (
      <LoadMoreFooter hasMore={hasMore} loading={loadingMore} colors={colors} onLoadMore={onLoadMore} />
    ),
    [hasMore, loadingMore, colors, onLoadMore],
  );

  if (tabLoading && listThreads.length === 0) {
    return <SkeletonList count={4} variant="thread" />;
  }

  return (
    <LegendList
      recycleItems
      experimental_adaptiveRender={FEED_ADAPTIVE_RENDER}
      ref={setListRef}
      data={listThreads}
      keyExtractor={threadKeyExtractor}
      getItemType={threadItemType}
      viewabilityConfig={viewabilityConfig}
      onViewableItemsChanged={onViewableItemsChanged}
      // 保留：tab 切换换数据时保持可视位置稳定（LegendList 的 maintainVisibleContentPosition
      // data/size 锚定，换数据时视口不因内容尺寸估算跳变而瞬移）；push 转场期间自动禁用
      // （页面经 isFocused 控制）。
      maintainVisibleContentPosition={isFocused ? { data: true, size: true } : undefined}
      renderItem={renderItem}
      ListHeaderComponent={header}
      ListEmptyComponent={listEmpty}
      // 顶栏让位已由列表头自身承载（forum/[name].tsx topBlock 的
      // paddingTop=insets.top+NAV_BAR_H，8-28 显式化——不依赖本容器
      // contentContainerStyle 的 padding 语义，随列表头滚动滑出不变）。
      contentContainerStyle={{
        paddingBottom: insets.bottom + 20,
      }}
      refreshControl={
        <RefreshControl refreshing={refreshing} onRefresh={onRefresh} tintColor={colors.primary} />
      }
      ListFooterComponent={listFooter}
      onEndReached={onLoadMore}
      onEndReachedThreshold={0.3}
      onScroll={onScroll}
      scrollEventThrottle={64}
      onMomentumScrollEnd={(e: any) => onScroll(e as any)}
      drawDistance={300}
      decelerationRate="normal"
    />
  );
});
