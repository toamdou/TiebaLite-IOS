/**
 * Sub-Posts Page (楼中楼) — Threaded conversation design
 *
 * Design: 顶部「上一级回复」为圆角卡（secondarySystemGroupedBackground 底 +
 * hairline 描边 + 连续圆角）；下方回复行无卡片底色，行间 hairline 分隔
 * （信息流行分隔风格）。行内：头像/昵称/等级在上、点赞固定右上角，
 * 正文 + 缩略图流畅排列，空间紧凑（无独立操作行）。
 * 平滑淡入动画用于首屏批次的条目。
 *
 * 行/卡片渲染拆分至 components/thread/subposts/SubpostViews
 * （ReplyItem / ParentReplyCard / FallbackParentCard）。
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  View, StyleSheet,
  RefreshControl, Alert,
} from 'react-native';
import { LegendList, type LegendListRef } from '@legendapp/list/react-native';
import { useLocalSearchParams, Stack } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { EmptyState } from '@/components/ui/EmptyState';
import { ErrorState } from '@/components/ui/ErrorState';
import { useThemeColors } from '@/theme/ThemeContext';
import { hapticForScene } from '@/theme/hapticsMap';
import { useAuthStore } from '@/stores/authStore';
import { useMediaBus } from '@/stores/mediaBusStore';
import { mediaKeysOf } from '@/utils/feedMedia';
import { flattenStyle } from '@/utils';
import { openLink } from '@/utils/linkOpener';
import { checkReportPost } from '@/services/api/endpoints/misc';
import { pbFloor, agree, delPost } from '@/services/api/endpoints/thread';
import { usePagedList } from '@/hooks/usePagedList';
import { useImageViewer } from '@/hooks/useImageViewer';
import { useNavDoubleTapToTop } from '@/hooks/useNavDoubleTapToTop';
import { useAppPreference } from '@/hooks/useAppPreference';
import { LoadMoreFooter } from '@/components/ui/LoadMoreFooter';
import { SkeletonList } from '@/components/ui/Skeleton';
import ImageViewer from '@/components/ImageViewer';
import { getParentPostSummary } from '@/stores/parentPostCache';
import type { SubPostInfo } from '@/types';
import {
  ReplyItem,
  ParentReplyCard,
  FallbackParentCard,
} from '@/components/thread/subposts/SubpostViews';

const subPostKeyExtractor = (item: SubPostInfo, index: number) =>
  item.id || `subpost-anon-${index}`;

// ─── Main Page ───
export default function SubPostsPage() {
  const { threadId, postId, forumId, floor, threadAuthorId, forumName, threadTitle } = useLocalSearchParams<{
    threadId: string; postId: string; forumId: string; floor: string; threadAuthorId?: string;
    forumName?: string; threadTitle?: string;
  }>();
  const insets = useSafeAreaInsets();
  const { colors } = useThemeColors();
  const accountUid = useAuthStore((s) => s.account?.uid);
  const imageViewer = useImageViewer();
  const paged = usePagedList<SubPostInfo>({
    fetcher: async (page, _params, signal) => {
      const data = await pbFloor(threadId, postId, forumId, page, undefined, signal);
      return {
        // 楼中楼按时间升序（最老的第一条楼中楼在最上面，后续回复依序排列）：
        // pbFloor 每页已按时间升序下发，直接透传即可；分页在 usePagedList
        // 内按页号追加（页号递增 → 时间递增），跨页整体即自然的时间先后顺序，
        // 嵌套"A回复B"的链条按对话发生顺序阅读。
        items: data.posts,
        hasMore: data.page.hasMore,
        nextPage: data.page.current + 1,
        extra: data.page,
      };
    },
    initialPage: 1,
    // maxItems 设大（不裁剪）：楼中楼是"追加式"列表，若走滑动窗口（默认 200）
    // 会在第 7 页后把旧行裁掉，末尾位置固定→贴底时 onEndReached 持续满足，
    // 会把全部页连发拉完（92 页风暴+列表飞速刷新）。不裁剪则末尾随加载下移，
    // onEndReached 只在用户再次滚到底时触发——"加载一批，看一批"。
    // 2757 条轻量对象内存开销可忽略，LegendList 只渲染可见行。
    maxItems: 6000,
  });
  const {
    items: subPosts,
    hasMore,
    refreshing,
    loadingMore,
    loading,
    error,
    refresh: handleRefresh,
    loadMore: handleLoadMore,
    load,
    setItems: setSubPosts,
  } = paged;
  // C5: only the first loaded batch gets the fade-in; paginated rows render opaque.
  const initialBatchIdsRef = useRef<Set<string> | null>(null);
  // ref 填充本身不触发重渲染：首帧 animateIn 恒为 false（行以 opacity 1 渲染），
  // 这里在首批就绪后翻 true 强制重渲染 → animateIn 翻转 → ReplyItem fade 归零
  // 重新淡入（首批行真正淡入，见 ReplyItem 内 effect 注释）。
  const [initialBatchSealed, setInitialBatchSealed] = useState(false);

  // 媒体可见性：楼中楼滚动时向总线报告可视语音 key（离屏暂停）
  const subPostsViewabilityConfig = useRef({ itemVisiblePercentThreshold: 30 }).current;
  const subPostsOnViewableItemsChanged = useRef(
    (info: { viewableItems: { item: SubPostInfo }[] }) => {
      const keys = new Set<string>();
      for (const v of info.viewableItems) {
        if (v.item?.content) {
          for (const k of mediaKeysOf(v.item.content)) keys.add(k);
        }
      }
      useMediaBus.getState().setVisibleKeys(keys);
    },
  ).current;

  useEffect(() => {
    load(1);
  }, [load]);

  useEffect(() => {
    if (!initialBatchIdsRef.current && subPosts.length > 0) {
      initialBatchIdsRef.current = new Set(subPosts.map((p) => p.id));
      setInitialBatchSealed(true);
    }
  }, [subPosts]);

  // 点赞竞态守卫：按 item.id 维护在途集合，在途期间忽略新点击；
  // 失败回滚前校验当前态仍等于本次乐观写入的态，防旧请求回滚打翻新乐观态。
  const agreeInFlightRef = useRef<Set<string>>(new Set());

  const handleAgree = useCallback(
    async (item: SubPostInfo) => {
      if (!threadId || !item.id) return;
      if (agreeInFlightRef.current.has(item.id)) return;
      agreeInFlightRef.current.add(item.id);
      // 乐观更新：成功前就切换 UI（贴吧点赞是幂等操作），
      // 失败回滚 —— 旧实现无任何反馈，点了像没反应。
      const wasAgree = item.isAgree;
      const nextAgree = !wasAgree;
      hapticForScene('like');
      setSubPosts((prev) =>
        prev.map((p) =>
          p.id === item.id
            ? {
                ...p,
                isAgree: nextAgree,
                agreeNum: Math.max(0, (p.agreeNum ?? 0) + (nextAgree ? 1 : -1)),
              }
            : p,
        ),
      );
      try {
        await agree(threadId, item.id, nextAgree ? 1 : 0, 2);
      } catch {
        // 失败回滚（先校验：当前态必须仍等于本次乐观写入的态，
        // 期间被刷新/其他路径改写过的行不在此列，直接跳过）
        hapticForScene('action-fail');
        setSubPosts((prev) =>
          prev.map((p) => {
            if (p.id !== item.id || p.isAgree !== nextAgree) return p;
            return {
              ...p,
              isAgree: wasAgree,
              agreeNum: Math.max(0, (p.agreeNum ?? 0) + (wasAgree ? 1 : -1)),
            };
          }),
        );
      } finally {
        agreeInFlightRef.current.delete(item.id);
      }
    },
    [threadId, setSubPosts],
  );

  const safeDecode = (value?: string) => {
    if (!value) return '';
    try {
      return decodeURIComponent(value);
    } catch {
      return value;
    }
  };
  const decodedForumName = safeDecode(forumName);
  const decodedThreadTitle = safeDecode(threadTitle);

  const handleReport = useCallback(
    async (item: SubPostInfo) => {
      try {
        const reportUrl = await checkReportPost(item.id);
        if (reportUrl) {
          await openLink(reportUrl);
        } else {
          Alert.alert('提示', '当前回复不支持在线举报');
        }
      } catch {
        Alert.alert('错误', '举报失败');
      }
    },
    [],
  );

  const handleDelete = useCallback(
    (item: SubPostInfo) => {
      Alert.alert('删除回复', '确定要删除这条回复吗？', [
        { text: '取消', style: 'cancel' },
        {
          text: '删除',
          style: 'destructive',
          onPress: async () => {
            try {
              await delPost(forumId || '', decodedForumName, threadId || '', item.id, false);
              setSubPosts((prev) => prev.filter((p) => p.id !== item.id));
              hapticForScene('action-success');
            } catch {
              Alert.alert('错误', '删除失败');
            }
          },
        },
      ]);
    },
    [forumId, decodedForumName, threadId, setSubPosts],
  );

  const renderItem = useCallback(
    ({ item, index }: { item: SubPostInfo; index: number }) => (
      <ReplyItem
        item={item}
        index={index}
        colors={colors}
        threadAuthorId={threadAuthorId}
        onAgree={handleAgree}
        animateIn={initialBatchSealed && (initialBatchIdsRef.current?.has(item.id) ?? false)}
        isOwn={!!accountUid && accountUid === item.authorId}
        onReport={handleReport}
        onDelete={handleDelete}
        onImagePress={imageViewer.handleImagePress}
      />
    ),
    [colors, threadAuthorId, handleAgree, accountUid, handleReport, handleDelete, imageViewer.handleImagePress, initialBatchSealed],
  );

  // 上一级回复：从模块级缓存取回被点击的那条回复（帖子页跳转前快照）。
  // 未命中（如整包 reload 后直接深链进入）时回退展示原"主楼/帖子标题"卡。
  const parentPost = useMemo(() => getParentPostSummary(postId), [postId]);

  // 双击顶栏回顶（设置-浏览可关）
  const subPostsListRef = useRef<LegendListRef | null>(null);
  const navDoubleTapEnabled = useAppPreference('navBarDoubleTapToTop', true);
  useNavDoubleTapToTop(
    () => subPostsListRef.current?.scrollToOffset({ offset: 0, animated: true }),
    navDoubleTapEnabled ?? true,
  );

  const mainPostCard = useMemo(
    () => {
      // 有上一级回复快照 → 展示它（否则只会看到楼中楼列表，缺少上下文）
      if (parentPost) {
        return (
          <ParentReplyCard
            parent={parentPost}
            colors={colors}
            floor={floor}
            decodedForumName={decodedForumName}
            decodedThreadTitle={decodedThreadTitle}
            threadId={threadId}
            onImagePress={imageViewer.handleImagePress}
          />
        );
      }
      return (
        <FallbackParentCard
          colors={colors}
          decodedForumName={decodedForumName}
          decodedThreadTitle={decodedThreadTitle}
          floor={floor}
          threadId={threadId}
        />
      );
    },
    [parentPost, colors, decodedForumName, decodedThreadTitle, floor, threadId, imageViewer.handleImagePress],
  );

  const renderFooter = useMemo(
    () => (
      <LoadMoreFooter
        hasMore={hasMore}
        loading={loadingMore}
        colors={colors}
        onLoadMore={handleLoadMore}
      />
    ),
    [hasMore, loadingMore, colors, handleLoadMore],
  );

  // States
  if (loading && subPosts.length === 0) {
    return (
      <View style={flattenStyle([styles.container, { backgroundColor: colors.systemGroupedBackground }])}>
        <Stack.Screen options={{ title: `第${floor}楼回复` }} />
        <View style={styles.loadingSkeleton}>
          <SkeletonList count={8} variant="row" />
        </View>
      </View>
    );
  }
  if (error && subPosts.length === 0) {
    return (
      <View style={flattenStyle([styles.container, { backgroundColor: colors.systemGroupedBackground }])}>
        <Stack.Screen options={{ title: `第${floor}楼回复` }} />
        <ErrorState message={error} onRetry={handleRefresh} />
      </View>
    );
  }

  return (
    <View style={flattenStyle([styles.container, { backgroundColor: colors.systemGroupedBackground }])}>
      <Stack.Screen options={{ title: `第${floor || '?'}楼回复` }} />
      <LegendList
        recycleItems
        ref={subPostsListRef}
        data={subPosts}
        keyExtractor={subPostKeyExtractor}
        decelerationRate="normal"
        renderItem={renderItem}
        viewabilityConfig={subPostsViewabilityConfig}
        onViewableItemsChanged={subPostsOnViewableItemsChanged}
        ListHeaderComponent={mainPostCard}
        ListEmptyComponent={<EmptyState title="暂无回复" description="还没有楼中楼回复" icon="bubble.left" />}
        contentContainerStyle={[styles.listContent, { paddingTop: insets.top + 66, paddingBottom: insets.bottom + 24 }]}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={handleRefresh} tintColor={colors.primary} />}
        onEndReached={handleLoadMore}
        onEndReachedThreshold={0.5}
        drawDistance={500}
        // 首屏大批量（pbFloor 一次返回全部楼中楼）：drawDistance 提供首屏外的
        // 预渲染缓冲，导航动画中不会出现"只挂 1 个 cell、其余留白"。行高无需
        // 估算：v3 默认按 100px 估算首屏、渲染后以实测均值收敛（官方提示
        // estimatedItemSize 通常不需要，故不设置）。
        ListFooterComponent={renderFooter}
      />
      {/* C4: pbFloor only returns current/total/hasMore (no hasPrev), so
          "上一页/最新回复" controls are intentionally omitted until the
          service exposes a previous-page flag. */}
      {/* 楼中楼大图查看器（窗口化 + 低功耗 windowSize 2 + 关闭清缓存，
          由 ImageViewer 内部实现，接入模式与 thread/[id].tsx 一致） */}
      <ImageViewer
        images={imageViewer.imageViewerImages}
        initialIndex={imageViewer.imageViewerIndex}
        visible={imageViewer.imageViewerVisible}
        onClose={imageViewer.closeImageViewer}
        forumName={decodedForumName}
        sourceFrame={imageViewer.imageViewerSourceFrame}
        imageOrigins={imageViewer.imageViewerOrigins}
        contextTitle={imageViewer.imageViewerContextTitle}
        imageMeta={imageViewer.imageViewerMeta}
        imagePreviews={imageViewer.imageViewerPreviews}
      />
    </View>
  );
}

// ─── Styles ───
const styles = StyleSheet.create({
  container: { flex: 1 },
  loadingSkeleton: { flex: 1, paddingTop: 8 },
  // paddingTop 由 LegendList 内联（insets.top+66）下发，这里只管横向内缩
  listContent: { paddingHorizontal: 10 },
});
