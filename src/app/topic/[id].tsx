// ============================================================
// Topic Detail Page - 话题详情
// 迁移自: TopicDetailPage.kt

import { useCallback, useEffect, useMemo, useRef, type ReactNode } from 'react';
import {
  View,
  Text,
  Pressable,
  StyleSheet,
  RefreshControl,
} from 'react-native';
import Animated, { useSharedValue, useAnimatedStyle, withDelay, withTiming, interpolate } from 'react-native-reanimated';
import { LegendList } from '@legendapp/list/react-native';
import { useLocalSearchParams, Stack, Link } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Image } from 'expo-image';
import { SymbolView } from '@/components/ui/SymbolView';
import ImageViewer from '@/components/ImageViewer';
import TweetCard from '@/components/feed/TweetCard';
import { useThemeColors } from '@/theme/ThemeContext';
import { EmptyState } from '@/components/ui/EmptyState';
import { ErrorState } from '@/components/ui/ErrorState';
import { SkeletonList } from '@/components/ui/Skeleton';
import { LoadMoreFooter } from '@/components/ui/LoadMoreFooter';
import { hapticForScene } from '@/theme/hapticsMap';
import { useImageViewer } from '@/hooks/useImageViewer';
import type { ImagePressHandler } from '@/components/thread/PostImages';
import { mapProtoThread } from '@/services/api/endpoints/helpers';
import { topicDetail } from '@/services/api/endpoints/misc';
import { usePagedList } from '@/hooks/usePagedList';
import { useFeedCardActions } from '@/hooks/useFeedCardActions';
import { useReducedMotion } from '@/hooks/useReducedMotion';
import { formatCount } from '@/utils';
import {Spacing, DURATION, EASE_OUT, typographyStyles, RadiusStyle} from '@/theme';
import type { ThreadInfo } from '@/types';

// ---------- 话题额外数据宽松形态（proto 原始字段，snake_case） ----------
/** topic_detail 返回的 topic_info（与端上 TopicInfo 的 camelCase 形态不同源，单独声明） */
interface RawTopicInfo {
  discuss_num?: number;
  topic_desc?: string;
}

/** relate_forum 相关吧条目的宽松字段（老/新 proto 与 web 形状共存） */
interface RelatedForum {
  forum_name?: string;
  forumName?: string;
  name?: string;
  avatar?: string;
  pic?: string;
  forum_id?: string | number;
  forumId?: string | number;
}

interface TopicExtra {
  topicInfo: RawTopicInfo | null;
  relateForums: RelatedForum[];
}

// ---------- 首屏级联入场（仅首次数据批次，Reduce Motion 跳过） ----------
function FirstBatchStagger({
  index,
  enabled,
  children,
}: {
  index: number;
  enabled: boolean;
  children: ReactNode;
}) {
  const { reduceMotion } = useReducedMotion();
  const progress = useSharedValue(1);
  useEffect(() => {
    if (reduceMotion || !enabled) {
      progress.value = 1;
      return;
    }
    progress.value = 0;
    progress.value = withDelay(
      Math.min(index, 10) * DURATION.stagger,
      withTiming(1, { duration: DURATION.enter, easing: EASE_OUT }),
    );
    return () => {
      progress.value = 1;
    };
  }, [index, enabled, reduceMotion, progress]);
  const animStyle = useAnimatedStyle(() => ({
    opacity: progress.value,
    transform: [{ translateY: interpolate(progress.value, [0, 1], [12, 0]) }],
  }));
  return <Animated.View style={animStyle}>{children}</Animated.View>;
}

export default function TopicDetailPage() {
  const { id, name } = useLocalSearchParams<{ id: string; name: string }>();
  const { colors } = useThemeColors();
  const insets = useSafeAreaInsets();
  const topicName = name || '话题';
  const imageViewer = useImageViewer();
  const fetcher = useCallback(
    async (pageNum: number, _params: undefined, signal?: AbortSignal) => {
      const data = await topicDetail(id, topicName, pageNum, signal);
      // Defensive parse for related forums; render them below when present.
      const rawRelate =
        data?.relate_forum ??
        data?.relateForum ??
        data?.related_forum ??
        data?.topic_info?.relate_forum ??
        data?.topic_info?.relateForum ??
        [];
      const relateForums: RelatedForum[] = Array.isArray(rawRelate)
        ? rawRelate
        : rawRelate && typeof rawRelate === 'object'
          ? Object.values(rawRelate)
          : [];
      const rawThreads = data?.relate_thread?.thread_list ?? data?.thread_list ?? [];
      // 与 Kotlin TopicDetailViewModel 完全一致：relateThread.threadList 直接透传，
      // 话题详情页不做 ala_info 广告过滤（Kotlin 未在此处过滤，见 hottopic/detail/
      // TopicDetailViewModel.kt produceLoadPartialChange，无任何 filter）。
      const threadList: ThreadInfo[] = rawThreads.map((item: any) =>
        mapProtoThread(item.thread_info ?? item),
      );
      return {
        items: threadList,
        hasMore: threadList.length >= 10,
        nextPage: pageNum + 1,
        extra: {
          topicInfo: (data?.topic_info ?? data?.topicInfo ?? null) as RawTopicInfo | null,
          relateForums,
        },
      };
    },
    [id, topicName],
  );
  const paged = usePagedList<ThreadInfo, undefined, TopicExtra>({
    fetcher,
    initialPage: 1,
  });
  const {
    items: threads,
    loading: isLoading,
    refreshing: isRefreshing,
    error,
    load,
    refresh: handleRefresh,
    loadMore: handleLoadMore,
    hasMore,
    loadingMore,
    extra,
    setItems,
  } = paged;
  const topicInfo = extra?.topicInfo ?? null;
  const relateForums = useMemo<RelatedForum[]>(() => extra?.relateForums ?? [], [extra?.relateForums]);

  // ── 卡片操作四件套收敛到共享 hook（thermo Z4-B；点赞竞态策略与全库统一）──
  const feedActions = useFeedCardActions({
    applyLike: (id, nextAgree) =>
      setItems((prev) =>
        prev.map((t) =>
          t.id === id
            ? { ...t, hasAgree: nextAgree, zanNum: Math.max(0, (t.zanNum || 0) + (nextAgree ? 1 : -1)) }
            : t,
        ),
      ),
    removeByAuthor: (authorId) => setItems((prev) => prev.filter((t) => t.authorId !== authorId)),
    getLatestHasAgree: (id) => threads.find((t) => t.id === id)?.hasAgree,
  });

  const handleMenuAction = useCallback(
    (action: string, item: ThreadInfo) => {
      if (action === 'block') void feedActions.blockAuthor(item);
      else if (action === 'report') void feedActions.report(item);
    },
    [feedActions],
  );

  const handleImagePress = useCallback(
    (...args: Parameters<ImagePressHandler>) => {
      hapticForScene('press');
      // 全量透传（含 origins/contextTitle/meta）：此前只转发前 3 参，
      // 长图在话题页进查看器同样只显 bigPic 档且「保存原图」拿不到原图。
      imageViewer.handleImagePress(...args);
    },
    [imageViewer],
  );

  useEffect(() => {
    load(1);
  }, [load]);

  // 首次数据批次标记：仅首屏加载项做 stagger 渐入，分页加载不再重复动画。
  const firstBatchRef = useRef(true);
  useEffect(() => {
    if (threads.length > 0 && firstBatchRef.current) {
      firstBatchRef.current = false;
    }
  }, [threads.length]);

  const renderItem = useCallback(
    ({ item, index }: { item: ThreadInfo; index: number }) => (
      <FirstBatchStagger index={index} enabled={firstBatchRef.current}>
        <TweetCard
          thread={item}
          timeType="create"
          onMenuAction={handleMenuAction}
          onImagePress={handleImagePress}
          onLike={feedActions.like}
          onShare={feedActions.share}
        />
      </FirstBatchStagger>
    ),
    [handleMenuAction, handleImagePress, feedActions.like, feedActions.share],
  );

  const threadKeyExtractor = useCallback((item: ThreadInfo) => item.id, []);
  const listHeader = useCallback(
    () =>
      topicInfo ? (
        <Animated.View style={[styles.topicHeader, { borderBottomColor: colors.divider }]}>
          <View style={styles.topicHeaderRow}>
            <View
              style={[
                styles.topicIconBadge,
                { backgroundColor: colors.isNight ? 'rgba(255,159,10,0.16)' : 'rgba(255,149,0,0.12)' },
              ]}
            >
              <SymbolView name="number" size={18} tintColor={colors.warning} />
            </View>
            <View style={styles.topicTitleCol}>
              <Text style={[styles.topicTitle, { color: colors.text }]} numberOfLines={2}>
                #{topicName}#
              </Text>
              {topicInfo.discuss_num ? (
                <View style={styles.topicStatRow}>
                  <SymbolView name="flame" size={13} tintColor={colors.error} />
                  <Text style={[styles.topicMeta, { color: colors.textSecondary }]}>
                    {formatCount(topicInfo.discuss_num)} 讨论
                  </Text>
                </View>
              ) : null}
            </View>
          </View>
          {topicInfo.topic_desc ? (
            <Text style={[styles.topicDesc, { color: colors.textSecondary }]}>
              {topicInfo.topic_desc}
            </Text>
          ) : null}
          {relateForums.length > 0 && (
            <View style={styles.relateSection}>
              <Text style={[styles.relateTitle, { color: colors.textSecondary }]}>
                相关吧
              </Text>
              <View style={styles.relateWrap}>
                {relateForums.map((forum, idx) => {
                  const forumName = String(forum.forum_name ?? forum.forumName ?? forum.name ?? '');
                  const avatar = forum.avatar ?? forum.pic ?? '';
                  const chip = (
                    <Pressable
                      // expo-router Slot 断言：Link asChild 的唯一子元素 style 不能被数组
                      // 包裹（否则 dev 下抛 "-- passing an array of styles to child of <Slot>"），
                      // 这里用 flatten 合成单个样式对象。
                      style={StyleSheet.flatten([
                        styles.relateChip,
                        { backgroundColor: colors.surfaceSecondary },
                      ])}
                    >
                      {avatar ? (
                        <Image
                          source={{ uri: avatar }}
                          style={styles.relateAvatar}
                          contentFit="cover"
                          cachePolicy="memory-disk"
                          recyclingKey={avatar}
                        />
                      ) : (
                        <View
                          style={[
                            styles.relateAvatar,
                            { backgroundColor: colors.chip },
                          ]}
                        >
                          <SymbolView
                            name="person.2.fill"
                            size={14}
                            tintColor={colors.textDisabled}
                          />
                        </View>
                      )}
                      <Text
                        style={[styles.relateName, { color: colors.text }]}
                        numberOfLines={1}
                      >
                        {forumName || '相关吧'}
                      </Text>
                    </Pressable>
                  );
                  return forumName ? (
                    <Link
                      key={String(forum.forum_id ?? forum.forumId ?? idx)}
                      href={{
                        pathname: '/forum/[name]',
                        params: { name: forumName },
                      }}
                      asChild
                    >
                      {chip}
                    </Link>
                  ) : (
                    <View
                      key={String(forum.forum_id ?? forum.forumId ?? idx)}
                    >
                      {chip}
                    </View>
                  );
                })}
              </View>
            </View>
          )}
        </Animated.View>
      ) : (
        <View style={styles.simpleHeader}>
          <Text style={[styles.simpleHeaderText, { color: colors.text }]}>
            #{topicName}#
          </Text>
        </View>
      ),
    [topicInfo, topicName, colors, relateForums],
  );
  const listEmpty = useCallback(
    () => (
      <EmptyState
        icon="text.bubble"
        title="暂无讨论"
        description="这个话题下还没有内容"
      />
    ),
    [],
  );
  const listFooter = useMemo(
    () => (
      <LoadMoreFooter hasMore={hasMore} loading={loadingMore} colors={colors} onLoadMore={handleLoadMore} />
    ),
    [hasMore, loadingMore, colors, handleLoadMore],
  );

  if (isLoading) {
    return (
      <View style={StyleSheet.flatten([styles.container, { backgroundColor: colors.background }])}>
        <Stack.Screen options={{ title: topicName }} />
        <View style={styles.skeletonWrap}>
          <SkeletonList variant="thread" count={8} />
        </View>
      </View>
    );
  }

  if (error && threads.length === 0) {
    return (
      <View style={StyleSheet.flatten([styles.container, { backgroundColor: colors.background }])}>
        <Stack.Screen options={{ title: topicName }} />
        <ErrorState title="加载失败" message={error} onRetry={() => load(1)} />
      </View>
    );
  }

  return (
    <View style={StyleSheet.flatten([styles.container, { backgroundColor: colors.background }])}>
      <Stack.Screen options={{ title: topicName }} />
      <LegendList
        recycleItems
        data={threads}
        keyExtractor={threadKeyExtractor}
        renderItem={renderItem}
        decelerationRate="normal"
        drawDistance={300}
        refreshControl={
          <RefreshControl
            refreshing={isRefreshing}
            onRefresh={handleRefresh}
            tintColor={colors.primary}
          />
        }
        onEndReached={handleLoadMore}
        onEndReachedThreshold={0.3}
        ListHeaderComponent={listHeader}
        ListEmptyComponent={listEmpty}
        ListFooterComponent={listFooter}
        // headerTransparent 后内容从 y=0 起，顶部让位导航栏（状态栏+54pt
        // bar + 空隙）
        contentContainerStyle={[styles.listContent, { paddingTop: insets.top + 66 }]}
        showsVerticalScrollIndicator={false}
      />
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
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  skeletonWrap: { paddingHorizontal: Spacing.lg, paddingTop: Spacing.md },
  listContent: { paddingBottom: Spacing.page },
  topicHeader: {
    padding: Spacing.lg,
    borderBottomWidth: StyleSheet.hairlineWidth,
    // borderBottomColor 走 colors.divider（组件内动态注入，见 listHeader）
  },
  topicHeaderRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: Spacing.md,
    marginBottom: Spacing.sm,
  },
  topicIconBadge: {
    width: 40,
    height: 40,
    ...RadiusStyle.input,
    alignItems: 'center',
    justifyContent: 'center',
  },
  topicTitleCol: {
    flex: 1,
  },
  topicTitle: {
    fontSize: 24,
    fontWeight: '800',
    letterSpacing: 0,
  },
  topicStatRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    marginTop: 5,
  },
  topicMeta: {
    fontSize: 13,
    fontWeight: '500',
    fontVariant: ['tabular-nums'],
  },
  topicDesc: {
    fontSize: 14,
    lineHeight: 20,
    marginTop: Spacing.sm,
  },
  relateSection: {
    marginTop: Spacing.md,
  },
  relateTitle: {
    fontSize: 13,
    fontWeight: '600',
    marginBottom: Spacing.sm,
  },
  relateWrap: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: Spacing.sm,
  },
  relateChip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingHorizontal: 10,
    paddingVertical: 6,
    ...RadiusStyle.input,
    maxWidth: 180,
  },
  relateAvatar: {
    width: 20,
    height: 20,
    borderRadius: 10,
    borderCurve: 'continuous',
    alignItems: 'center',
    justifyContent: 'center',
  },
  relateName: {
    fontSize: 13,
    fontWeight: '500',
    flexShrink: 1,
  },
  simpleHeader: {
    padding: Spacing.lg,
    alignItems: 'center',
  },
  simpleHeaderText: typographyStyles.number,
});
