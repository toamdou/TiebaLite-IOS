// ============================================================
// TiebaLite React Native - Favorite Threads Page (我的收藏)
// LegendList of favorite threads with pull-to-refresh, infinite
// scroll, and swipe-to-remove, matching
// com.huanchengfly.tieba.post.ui.page.ThreadStorePage
//
// 视觉：与吧页信息流完全同款（TweetCard，2026-08-28 用户要求对齐）——
// 作者头像（store_thread author.user_portrait）+ 标题 + X 式图片带 +
// 回复时间 + 吧名药丸；取消收藏 = iOS 左滑出现红色「取消收藏」按钮
//（原右上角 ⋯ 菜单删除）。
// ============================================================

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  View,
  StyleSheet,
  Text,
  Pressable,
  RefreshControl,
  ActivityIndicator,
  Alert,
} from 'react-native';
import { LegendList } from '@legendapp/list/react-native';
import { useRouter, useFocusEffect } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Animated, { useAnimatedStyle, type SharedValue } from 'react-native-reanimated';
import ReanimatedSwipeable, {
  type SwipeableMethods,
} from 'react-native-gesture-handler/ReanimatedSwipeable';
import { SymbolView } from '@/components/ui/SymbolView';
import { hapticForScene } from '@/theme/hapticsMap';
import { VStack, Spacer, ContentUnavailableView, Button as SwiftButton, Label } from '@expo/ui/swift-ui';
import { buttonStyle, buttonBorderShape } from '@expo/ui/swift-ui/modifiers';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { EmptyState } from '@/components/ui/EmptyState';
import { ErrorState } from '@/components/ui/ErrorState';
import { SkeletonList } from '@/components/ui/Skeleton';
import TweetCard from '@/components/feed/TweetCard';
import { EntranceRow } from '@/components/feed/EntranceRow';
import { NAV_BAR_H } from '@/constants/layout';
import { Button } from '@/components/ui/Button';
import { useThemeColors } from '@/theme/ThemeContext';
import {Spacing, typographyStyles, RadiusStyle} from '@/theme';
import { useAuthStore } from '@/stores/authStore';
import { threadStore, removeStore } from '@/services/api/endpoints/thread';
import { usePagedList } from '@/hooks/usePagedList';
import { useForumAvatarStore, forumAvatarKey } from '@/stores/forumAvatarCache';
import { useImageViewer } from '@/hooks/useImageViewer';
import ImageViewer from '@/components/ImageViewer';
import { getFavoriteImagesMap, removeFavoriteImages } from '@/services/storage/favoriteImages';
import type { FavoriteThread, ThreadInfo } from '@/types';

// threadStore 原始项曾以 tid 承载收藏 ID（id 全为 undefined），数据在
// fetcher 入口已收窄为 FavoriteThread（camelCase id），无需再读原始字段；
// `||` 让空串一并兜底（原 `??` 对 '' 不短路，会落成重复空 key 让 LegendList
// 虚拟化错乱），id 缺失/为空时回退索引保证 key 稳定唯一。
const favoriteKeyExtractor = (item: FavoriteThread, index: number) =>
  String(item.id) || String(index);

/** threadStore 时间戳容错：camelCase 毫秒，秒值自动换算毫秒。
 *  原 snake_case（update_time/collect_time）兜底为死分支，已移除。 */
function storeTimestamp(item: FavoriteThread): number {
  const raw = item.updateTime || item.collectTime || 0;
  const t = Number(raw);
  if (!Number.isFinite(t) || t <= 0) return 0;
  return t >= 1e11 ? t : t * 1000;
}

/**
 * 收藏行 → 信息流 ThreadInfo 轻量投影（对齐搜索页 searchThreadToThreadInfo）：
 * 让收藏行直接复用 TweetCard（吧页信息流同款卡片）。快照图无尺寸信息，
 * 按 1:1 方图兜底；authorId 缺失 → 头像点击安全短路（TweetCard 内部判空）。
 */
function favoriteToThreadInfo(item: FavoriteThread, images?: string[], forumAvatar = ''): ThreadInfo {
  const time = storeTimestamp(item);
  return {
    id: item.id,
    title: item.title,
    forumId: item.forumId ?? '',
    forumName: item.forumName,
    forumAvatar,
    authorId: '',
    authorName: item.authorName,
    authorNameShow: '',
    authorPortrait: item.authorPortrait || '',
    authorLevelId: 0,
    replyNum: item.latestReplyNum,
    viewNum: 0,
    lastTime: time,
    createTime: item.collectTime,
    isTop: false,
    isGood: false,
    isVideo: false,
    mediaList: (images ?? []).map((src) => ({
      type: 'image' as const,
      src,
      originSrc: src,
      smallSrc: '',
      width: 1,
      height: 1,
    })),
    abstract: '',
    firstPostContent: [],
    zanNum: 0,
    shareNum: 0,
    hasAgree: false,
  };
}

/** 左滑露出右侧固定宽红色「取消收藏」钮（history.tsx SwipeToDeleteRow 同款）。 */
function SwipeToUncollectRow({
  children,
  onUncollect,
}: {
  children: React.ReactNode;
  onUncollect: () => void;
}) {
  const ref = useRef<SwipeableMethods>(null);
  const progressRef = useRef<SharedValue<number> | null>(null);
  const actionStyle = useAnimatedStyle(() => {
    const p = progressRef.current?.value ?? 1;
    return {
      opacity: 0.35 + p * 0.65,
      transform: [{ scale: 0.6 + p * 0.4 }],
    };
  });

  const renderRightActions = (progress: SharedValue<number>) => {
    progressRef.current = progress;
    return (
      <Animated.View style={[styles.deleteAction, actionStyle]}>
        <Pressable
          style={styles.deleteBtn}
          onPress={() => {
            ref.current?.close();
            void hapticForScene('destructive');
            onUncollect();
          }}
          accessibilityRole="button"
          accessibilityLabel="取消收藏"
        >
          <SymbolView name="star.slash" size={17} weight="semibold" tintColor="#FFFFFF" />
          <Text style={styles.deleteText}>取消收藏</Text>
        </Pressable>
      </Animated.View>
    );
  };

  return (
    <ReanimatedSwipeable
      ref={ref}
      renderRightActions={renderRightActions}
      friction={2}
      rightThreshold={40}
      overshootRight={false}
      enableTrackpadTwoFingerGesture
    >
      {children}
    </ReanimatedSwipeable>
  );
}

export default function ThreadStorePage() {
  const insets = useSafeAreaInsets();
  const { colors } = useThemeColors();
  const router = useRouter();
  const { isLoggedIn } = useAuthStore();
  // fetcher 必须稳定引用：内联会导致 usePagedList 的 run/refresh 每次渲染
  // 重建，下方 useFocusEffect([refresh]) 每次 focus 反复触发 → 请求风暴
  // （thread/[id].tsx 同款修复）。
  const fetchThreadStore = useCallback(async (p: number, _params: unknown, signal?: AbortSignal) => {
    const data = await threadStore(p, signal);
    return { items: data.items, hasMore: data.hasMore, nextPage: p + 1 };
  }, []);
  const paged = usePagedList<FavoriteThread>({
    fetcher: fetchThreadStore,
    initialPage: 1,
  });
  const {
    items,
    hasMore,
    loading,
    refreshing,
    loadingMore,
    error,
    refresh,
    loadMore,
    setItems,
  } = paged;
  const [undoRemoved, setUndoRemoved] = useState<{ item: FavoriteThread; index: number } | null>(null);
  const imageViewer = useImageViewer();
  // 收藏时的本地图片快照：服务端 store_list 不带图，合并显示缩略图
  const [favImages, setFavImages] = useState<Record<string, string[]>>({});
  // 吧头像走全站统一缓存（subscribe + ensure：已关注缓存直查/未关注实时拉）
  const avatarMap = useForumAvatarStore((s) => s.avatars);
  useEffect(() => {
    useForumAvatarStore.getState().ensureAvatars(items);
  }, [items]);

  // focus 刷新（(tabs)/index.tsx:344 同款模式）：从帖子页取消收藏/重新收藏后
  // 返回本页时，重新拉列表 + 重取图片快照。refresh 只置 refreshing 不闪骨架；
  // 首次进入时 loading 初值仍为 true，首帧照常走骨架屏。
  useFocusEffect(
    useCallback(() => {
      // 未登录不请求收藏接口（避免报错刷屏），由下方登录引导态承接
      if (!isLoggedIn) return;
      refresh();
      getFavoriteImagesMap().then(setFavImages).catch(() => {});
    }, [isLoggedIn, refresh]),
  );

  const handleRemove = useCallback(
    async (item: FavoriteThread) => {
      if (!isLoggedIn) {
        Alert.alert('提示', '请先登录');
        return;
      }
      const originalIndex = items.findIndex((i) => i.id === item.id);
      // Optimistic removal
      setItems((prev) => prev.filter((i) => i.id !== item.id));
      setUndoRemoved({ item, index: originalIndex });
      void hapticForScene('action-warning');
      try {
        await removeStore(item.id);
        // 成功：清本地图片快照（服务端不带图，残留 kv 里只是死数据），并
        // 同步剪掉内存 favImages 对应键——快照清除与列表行移除保持一致。
        void removeFavoriteImages(item.id);
        setFavImages((prev) => {
          if (!(String(item.id) in prev)) return prev;
          const next = { ...prev };
          delete next[String(item.id)];
          return next;
        });
        setUndoRemoved(null);
        hapticForScene('action-success');
      } catch {
        // Undo: put item back at its original index, not the end of the list.
        setItems((prev) => {
          // 竞态守卫：失败回滚与「撤销」toast 的插回并发时，若该帖已回到
          // 列表（或刷新后同 id 项已存在），跳过插回——防重复行 + LegendList
          // key 冲突（同 id 双行会让虚拟化错乱渲染成整屏灰）。
          if (prev.some((i) => i.id === item.id)) return prev;
          const next = [...prev];
          const insertIndex = originalIndex >= 0 ? Math.min(originalIndex, next.length) : next.length;
          next.splice(insertIndex, 0, item);
          return next;
        });
        setUndoRemoved(null);
        Alert.alert('错误', '取消收藏失败');
      }
    },
    [isLoggedIn, items, setItems],
  );

  const handleUndo = useCallback(() => {
    if (undoRemoved) {
      const { item, index } = undoRemoved;
      setItems((prev) => {
        const next = [...prev];
        const insertIndex = index >= 0 ? Math.min(index, next.length) : next.length;
        next.splice(insertIndex, 0, item);
        return next;
      });
      setUndoRemoved(null);
      hapticForScene('action-success');
    }
  }, [undoRemoved, setItems]);

  // 首屏批次入场（全 App 统一 EntranceRow 效果）：仅首次数据到达播放，
  // 分页/刷新/回收复用不重播（entranceDoneRef 冻结）
  const entranceDoneRef = useRef(false);
  useEffect(() => {
    if (items.length > 0) entranceDoneRef.current = true;
  }, [items.length]);

  const renderItem = useCallback(
    ({ item, index }: { item: FavoriteThread; index: number }) => {
      const favoritesImages = favImages[String(item.id)];
      const avatarKey = forumAvatarKey(item);
      const forumAvatar = avatarKey ? avatarMap[avatarKey]?.avatar ?? '' : '';
      return (
        <EntranceRow index={index} animateEntry={!entranceDoneRef.current}>
          <SwipeToUncollectRow onUncollect={() => handleRemove(item)}>
            <TweetCard
              thread={favoriteToThreadInfo(item, favoritesImages, forumAvatar)}
              timeType="last"
              showForumPill
              hideActions
              imageContextMenu
              onImagePress={imageViewer.handleImagePress}
              onOpenThread={() => {
                hapticForScene('press');
                router.push({ pathname: '/thread/[id]', params: { id: item.id, fromFavorites: '1' } });
              }}
            />
          </SwipeToUncollectRow>
        </EntranceRow>
      );
    },
    [router, handleRemove, favImages, imageViewer, avatarMap],
  );

  const renderFooter = useMemo(() => {
    if (loadingMore) {
      return <ActivityIndicator style={styles.loadingMore} color={colors.primary} />;
    }
    if (!hasMore && items.length > 0) {
      return <Text style={[styles.noMore, { color: colors.textDisabled }]}>没有更多了</Text>;
    }
    return null;
  }, [loadingMore, hasMore, items.length, colors]);

  // 未登录：不请求收藏接口，直接引导登录（登录后返回本页自动拉取）
  if (!isLoggedIn) {
    return (
      <ThemedHost style={{ flex: 1 }}>
        <VStack alignment="center" spacing={16}>
          <Spacer />
          <ContentUnavailableView
            systemImage="person.crop.circle.badge.questionmark"
            title="需要登录"
            description="登录后才能查看收藏的贴子"
          />
          <SwiftButton
            onPress={() => router.push('/login')}
            modifiers={[buttonStyle('glassProminent'), buttonBorderShape('capsule')]}
          >
            <Label title="登录百度账号" systemImage="person.crop.circle.badge.checkmark" />
          </SwiftButton>
          <Spacer />
        </VStack>
      </ThemedHost>
    );
  }

  // Loading
  if (loading && items.length === 0) {
    return (
      <ThemedHost style={{ flex: 1 }}>
        <View style={[styles.container, { backgroundColor: colors.background }]}>
          <View style={styles.skeletonWrap}>
            <SkeletonList variant="thread" count={6} />
          </View>
        </View>
      </ThemedHost>
    );
  }

  // Error
  if (error && items.length === 0) {
    return (
      <ThemedHost style={{ flex: 1 }}>
        <View style={[styles.container, { backgroundColor: colors.background }]}>
          <ErrorState message={error} onRetry={refresh} />
        </View>
      </ThemedHost>
    );
  }

  return (
    // 主列表为纯 RN 内容：不再包整页 ThemedHost——页级 Host 会隔断顶栏玻璃
    // 链路（8-25 吧页三连否决同源），纯 RN 分支与帖子页同构即可；SwiftUI 组件
    // （登录引导/加载/错误分支）仍各自保留 Host。
    <View style={[styles.container, { backgroundColor: colors.background }]}>
      <LegendList
        recycleItems
        data={items}
        keyExtractor={favoriteKeyExtractor}
        decelerationRate="normal"
        renderItem={renderItem}
        drawDistance={250}
        ListEmptyComponent={
          <EmptyState
            title="暂无收藏"
            description="浏览帖子时点击收藏即可添加到此处"
            icon="star.fill"
          />
        }
        contentContainerStyle={[
          styles.listContent,
          { paddingTop: insets.top + NAV_BAR_H, paddingBottom: insets.bottom + Spacing.lg },
          items.length === 0 && styles.emptyList,
        ]}
        refreshControl={
          <RefreshControl
            refreshing={refreshing}
            onRefresh={() => { void refresh().then(() => hapticForScene('toggle')); }}
            tintColor={colors.primary}
          />
        }
        onEndReached={loadMore}
        onEndReachedThreshold={0.3}
        ListFooterComponent={renderFooter}
      />
      {/* Undo Toast：浮动在列表底部，不再遮挡列表头数据（P2 最小修复） */}
      {undoRemoved && (
        <View style={[styles.undoBar, { backgroundColor: colors.surfaceSecondary, bottom: insets.bottom + 16 }]}>
          <Text style={[styles.undoText, { color: colors.text }]}>已取消收藏</Text>
          <View style={{ height: 32 }}>
            <Button title="撤销" variant="plain" onPress={handleUndo} />
          </View>
        </View>
      )}
      {/* ── Image Viewer（收藏缩略图点开大图/手势退出手感同帖子页） ── */}
      <ImageViewer
        images={imageViewer.imageViewerImages}
        initialIndex={imageViewer.imageViewerIndex}
        visible={imageViewer.imageViewerVisible}
        onClose={imageViewer.closeImageViewer}
        sourceFrame={imageViewer.imageViewerSourceFrame}
        imageOrigins={imageViewer.imageViewerOrigins}
        contextTitle={imageViewer.imageViewerContextTitle}
        imageMeta={imageViewer.imageViewerMeta}
      />
    </View>
  );
}

// ── 内嵌小组件 ──

const styles = StyleSheet.create({
  container: { flex: 1 },
  // 骨架容器与列表容器契约一致（列表卡片贴边 10pt、listContent paddingTop sm）：
  // 首行 y 偏移与水平缩进与真实列表对齐，替换瞬间不跳位（2026-08-29 错位修复）
  skeletonWrap: { paddingHorizontal: 10, paddingTop: Spacing.sm },
  listContent: { paddingTop: Spacing.sm },
  emptyList: { flex: 1 },
  // 左滑「取消收藏」动作条（history.tsx 左滑删除同款：固定宽红色钮）
  deleteAction: {
    width: 96,
    marginVertical: Spacing.sm,
    justifyContent: 'center',
  },
  deleteBtn: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 4,
    ...RadiusStyle.card,
    backgroundColor: 'rgba(255,59,48,0.95)',
  },
  deleteText: {
    ...typographyStyles.caption1,
    color: '#FFFFFF',
    fontWeight: '600',
  },
  // Undo toast（浮动底部，不遮列表头）
  undoBar: {
    position: 'absolute',
    left: Spacing.md,
    right: Spacing.md,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: Spacing.lg,
    paddingVertical: 10,
    ...RadiusStyle.chip,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.03,
    shadowRadius: 6,
    elevation: 2,
  },
  undoText: typographyStyles.footnote,
  // Footer
  loadingMore: { paddingVertical: Spacing.lg },
  noMore: { textAlign: 'center', paddingVertical: Spacing.lg, ...typographyStyles.footnote },
});
