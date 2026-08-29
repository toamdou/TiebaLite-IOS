/**
 * Shared search result lists for global search and in-forum search.
 *
 * The list wrappers keep the LegendList tuning (drawDistance, keyboard
 * behavior) and empty/footer states consistent across search flows.
 */

import { useCallback, useEffect } from 'react';
import {
  ActivityIndicator,
  Pressable,
  RefreshControl,
  StyleSheet,
  Text,
  View,
  type StyleProp,
  type ViewStyle,
} from 'react-native';
import { LegendList } from '@legendapp/list/react-native';
import { SymbolView } from '@/components/ui/SymbolView';
import { SkeletonList } from '@/components/ui/Skeleton';
import TweetCard, { type TweetCardProps } from '@/components/feed/TweetCard';
import { htmlToText } from '@/utils/htmlSummary';
import {
  SearchForumCard,
  SearchPostCard,
  SearchUserCard,
} from '@/components/search/SearchResultCard';
import type {
  SearchForumResult,
  SearchPostResult,
  SearchThreadResult,
  SearchUserResult,
  ThreadInfo,
} from '@/types';
import type { SemanticColors } from '@/theme';
import { useForumAvatarStore, forumAvatarKey } from '@/stores/forumAvatarCache';

// 稳定 key：thread 同页无重复 tid，直接用纯 id（去掉 -index 后缀可避免
// 分页 append 后索引位移导致的 cell 重建）；post 在 id 缺失时退到
// `post-${authorId}-${index}` 稳定前缀（authorId+index 组合同页唯一）。
const threadKeyExtractor = (item: SearchThreadResult) => item.id;
const forumKeyExtractor = (item: SearchForumResult) => item.forumId;
const userKeyExtractor = (item: SearchUserResult) => item.uid;
const postKeyExtractor = (item: SearchPostResult, index: number) => item.id || `post-${item.authorId}-${index}`;

/**
 * 搜索结果贴 → 信息流 ThreadInfo 轻量投影：让「贴」结果直接复用 TweetCard
 * 推特流卡片（X 式图片带 + 长按菜单），与动态/吧内信息流完全同观感。
 * 服务端无 authorId（头像不可跳用户页）、无点赞态（hasAgree 由乐观更新写入）。
 */
function searchThreadToThreadInfo(item: SearchThreadResult, avatarFallback = ''): ThreadInfo {
  // JSON 兜底路径可能缺 media 数组：必须与旧实现同样先判存在再取长度
  const media = item.media && item.media.length > 0 ? item.media : (item.mainPost?.media ?? []);
  const createTimeMs = item.createTime > 0 ? item.createTime * 1000 : 0;
  return {
    id: item.id,
    title: item.title,
    forumId: '',
    forumName: item.forumName,
    forumAvatar: item.forumAvatar || avatarFallback,
    authorId: '',
    authorName: item.authorName,
    authorNameShow: item.authorNameShow || '',
    authorPortrait: item.authorPortrait || '',
    authorLevelId: 0,
    replyNum: item.replyNum,
    viewNum: 0,
    lastTime: createTimeMs,
    createTime: createTimeMs,
    isTop: false,
    isGood: false,
    isVideo: media.some((m) => m.type === 'video'),
    mediaList: media.map((m) => ({
      type: m.type === 'video' ? ('video' as const) : ('image' as const),
      src: m.bigPic || m.src || m.smallPic || '',
      originSrc: m.bigPic || m.src || m.smallPic || '',
      smallSrc: m.smallPic,
      width: m.width,
      height: m.height,
    })),
    abstract: htmlToText(item.content || ''),
    firstPostContent: [],
    zanNum: item.likeNum,
    shareNum: item.shareNum,
    hasAgree: item.hasAgree,
  };
}

// 模块级常量分隔线：内联匿名组件每次渲染都会创建新组件类型，迫使 LegendList
// 重建分隔 cell；模块级函数引用稳定。
const postListSeparator = () => <View style={styles.postSeparator} />;

export function SearchThreadList({
  items,
  colors,
  onPressItem,
  onEndReached,
  hasMore,
  loadingMore,
  onLike,
  onShare,
  onImagePress,
  header,
  loading,
  error,
  onRetry,
}: {
  items: SearchThreadResult[];
  colors: SemanticColors;
  /** 保留旧契约（空态/调用方兼容）；TweetCard 自带进帖导航，实际未用 */
  onPressItem: (item: SearchThreadResult) => void;
  onEndReached?: () => void;
  hasMore?: boolean;
  loadingMore?: boolean;
  /** 点赞（登录守卫+乐观更新在页面层） */
  onLike?: (item: SearchThreadResult) => void;
  onShare?: (item: SearchThreadResult) => void;
  onImagePress?: TweetCardProps['onImagePress'];
  /** 搜索页列表头（搜索行+分段+排序）：随列表滚动退出 */
  header?: React.ReactNode;
  /** 首屏骨架态：header 仍展示在骨架上方 */
  loading?: boolean;
  /** 失败态（无数据时）：header + 重试按钮 */
  error?: string;
  onRetry?: () => void;
}) {
  // 吧头像走全站统一缓存：搜索帖服务端 forum_info 时有时无，缺的按吧名
  // 键（forumId 恒空）补齐；服务端有值不覆盖。
  const avatarMap = useForumAvatarStore((s) => s.avatars);
  useEffect(() => {
    useForumAvatarStore.getState().ensureAvatars(items);
  }, [items]);
  const renderItem = useCallback(
    ({ item }: { item: SearchThreadResult }) => {
      const avatarKey = forumAvatarKey(item);
      const avatar = avatarKey ? avatarMap[avatarKey]?.avatar ?? '' : '';
      return (
        <TweetCard
          thread={searchThreadToThreadInfo(item, avatar)}
          timeType="create"
          showForumPill
          imageContextMenu
          onImagePress={onImagePress}
          onLike={onLike ? () => onLike(item) : undefined}
          onShare={onShare ? () => onShare(item) : undefined}
        />
      );
    },
    [colors, onPressItem, onLike, onShare, onImagePress, avatarMap],
  );
  const listFooter = useCallback(
    () =>
      loadingMore ? (
        <View style={styles.footerLoader}>
          <ActivityIndicator size="small" color={colors.primary} />
          <Text style={[styles.footerText, { color: colors.textTertiary }]}>加载更多...</Text>
        </View>
      ) : !hasMore && items.length > 0 ? (
        <View style={styles.footerLoader}>
          <Text style={[styles.footerText, { color: colors.textTertiary }]}>没有更多了</Text>
        </View>
      ) : null,
    [loadingMore, hasMore, items.length, colors.primary, colors.textTertiary],
  );

  // 首屏骨架 / 失败 / 空态一律走 LegendList + ListEmptyComponent：header
  //（搜索行 UISearchBar）始终挂在同一棵组件树上，提交搜索/切 tab 不再
  // 卸载重建（2026-08-27 真机：两套树切换让搜索栏重挂，出现结果/切板块
  // 时从右往左跳动两下）。
  const listEmpty = useCallback(() => {
    if (loading && items.length === 0) {
      return <SkeletonList variant="row" itemHeight={104} count={6} />;
    }
    if (error && items.length === 0) {
      return (
        <View style={styles.centerWrap}>
          <SymbolView name="wifi.exclamationmark" size={36} tintColor={colors.textDisabled} />
          <Text style={[styles.emptyTitle, { color: colors.textSecondary }]}>{error}</Text>
          {onRetry && (
            <Pressable
              onPress={onRetry}
              style={[styles.retryBtn, { backgroundColor: colors.primary }]}
            >
              <Text style={[styles.retryText, { color: colors.textOnPrimary }]}>重试</Text>
            </Pressable>
          )}
        </View>
      );
    }
    return (
      <View style={styles.centerWrap}>
        <SymbolView name="doc.text.magnifyingglass" size={36} tintColor={colors.textDisabled} />
        <Text style={[styles.emptyTitle, { color: colors.textSecondary }]}>未找到相关贴子</Text>
        {onRetry && (
          <Pressable
            onPress={onRetry}
            style={[styles.retryBtn, { backgroundColor: colors.primary }]}
          >
            <Text style={[styles.retryText, { color: colors.textOnPrimary }]}>刷新</Text>
          </Pressable>
        )}
      </View>
    );
  }, [loading, error, items.length, colors, onRetry]);

  return (
    <LegendList
      recycleItems
      data={items}
      keyExtractor={threadKeyExtractor}
      contentContainerStyle={styles.listContent}
      drawDistance={250}
      keyboardDismissMode="on-drag"
      keyboardShouldPersistTaps="handled"
      onEndReached={onEndReached}
      onEndReachedThreshold={0.3}
      ListHeaderComponent={header as React.ReactElement | null}
      ListEmptyComponent={listEmpty}
      ListFooterComponent={listFooter}
      renderItem={renderItem}
    />
  );
}

export function SearchForumList({
  items,
  colors,
  onPressItem,
  header,
  loading,
  error,
  onRetry,
}: {
  items: SearchForumResult[];
  colors: SemanticColors;
  onPressItem: (item: SearchForumResult) => void;
  /** 搜索页列表头：随列表滚动退出 */
  header?: React.ReactNode;
  loading?: boolean;
  error?: string;
  onRetry?: () => void;
}) {
  const renderItem = useCallback(
    ({ item }: { item: SearchForumResult }) => (
      <SearchForumCard
        item={item}
        colors={colors}
        onPressItem={onPressItem}
      />
    ),
    [colors, onPressItem],
  );

  // 同 SearchThreadList：骨架/错误/空态走 ListEmptyComponent，header 常驻
  const listEmpty = useCallback(() => {
    if (loading && items.length === 0) {
      return <SkeletonList variant="row" itemHeight={88} count={6} />;
    }
    if (error && items.length === 0) {
      return (
        <View style={styles.centerWrap}>
          <SymbolView name="wifi.exclamationmark" size={36} tintColor={colors.textDisabled} />
          <Text style={[styles.emptyTitle, { color: colors.textSecondary }]}>{error}</Text>
          {onRetry && (
            <Pressable
              onPress={onRetry}
              style={[styles.retryBtn, { backgroundColor: colors.primary }]}
            >
              <Text style={[styles.retryText, { color: colors.textOnPrimary }]}>重试</Text>
            </Pressable>
          )}
        </View>
      );
    }
    return (
      <View style={styles.centerWrap}>
        <SymbolView name="square.grid.2x2" size={36} tintColor={colors.textDisabled} />
        <Text style={[styles.emptyTitle, { color: colors.textSecondary }]}>未找到相关贴吧</Text>
        {onRetry && (
          <Pressable
            onPress={onRetry}
            style={[styles.retryBtn, { backgroundColor: colors.primary }]}
          >
            <Text style={[styles.retryText, { color: colors.textOnPrimary }]}>刷新</Text>
          </Pressable>
        )}
      </View>
    );
  }, [loading, error, items.length, colors, onRetry]);

  return (
    <LegendList
      recycleItems
      data={items}
      keyExtractor={forumKeyExtractor}
      contentContainerStyle={styles.listContent}
      drawDistance={250}
      keyboardDismissMode="on-drag"
      keyboardShouldPersistTaps="handled"
      ListHeaderComponent={header as React.ReactElement | null}
      ListEmptyComponent={listEmpty}
      renderItem={renderItem}
    />
  );
}

export function SearchUserList({
  items,
  colors,
  onPressItem,
  header,
  loading,
  error,
  onRetry,
}: {
  items: SearchUserResult[];
  colors: SemanticColors;
  onPressItem: (item: SearchUserResult) => void;
  /** 搜索页列表头：随列表滚动退出 */
  header?: React.ReactNode;
  loading?: boolean;
  error?: string;
  onRetry?: () => void;
}) {
  const renderItem = useCallback(
    ({ item }: { item: SearchUserResult }) => (
      <SearchUserCard
        item={item}
        colors={colors}
        onPressItem={onPressItem}
      />
    ),
    [colors, onPressItem],
  );

  // 同 SearchThreadList：骨架/错误/空态走 ListEmptyComponent，header 常驻
  const listEmpty = useCallback(() => {
    if (loading && items.length === 0) {
      return <SkeletonList variant="row" itemHeight={88} count={6} />;
    }
    if (error && items.length === 0) {
      return (
        <View style={styles.centerWrap}>
          <SymbolView name="wifi.exclamationmark" size={36} tintColor={colors.textDisabled} />
          <Text style={[styles.emptyTitle, { color: colors.textSecondary }]}>{error}</Text>
          {onRetry && (
            <Pressable
              onPress={onRetry}
              style={[styles.retryBtn, { backgroundColor: colors.primary }]}
            >
              <Text style={[styles.retryText, { color: colors.textOnPrimary }]}>重试</Text>
            </Pressable>
          )}
        </View>
      );
    }
    return (
      <View style={styles.centerWrap}>
        <SymbolView name="person.crop.circle" size={36} tintColor={colors.textDisabled} />
        <Text style={[styles.emptyTitle, { color: colors.textSecondary }]}>未找到相关用户</Text>
        {onRetry && (
          <Pressable
            onPress={onRetry}
            style={[styles.retryBtn, { backgroundColor: colors.primary }]}
          >
            <Text style={[styles.retryText, { color: colors.textOnPrimary }]}>刷新</Text>
          </Pressable>
        )}
      </View>
    );
  }, [loading, error, items.length, colors, onRetry]);

  return (
    <LegendList
      recycleItems
      data={items}
      keyExtractor={userKeyExtractor}
      contentContainerStyle={styles.listContent}
      drawDistance={250}
      keyboardDismissMode="on-drag"
      keyboardShouldPersistTaps="handled"
      ListHeaderComponent={header as React.ReactElement | null}
      ListEmptyComponent={listEmpty}
      renderItem={renderItem}
    />
  );
}

export function SearchPostList({
  items,
  colors,
  onPressItem,
  onEndReached,
  hasMore,
  loadingMore,
  refreshing,
  onRefresh,
  contentContainerStyle,
}: {
  items: SearchPostResult[];
  colors: SemanticColors;
  onPressItem: (item: SearchPostResult) => void;
  onEndReached: () => void;
  hasMore: boolean;
  loadingMore: boolean;
  refreshing: boolean;
  onRefresh: () => void;
  contentContainerStyle?: StyleProp<ViewStyle>;
}) {
  const renderItem = useCallback(
    ({ item }: { item: SearchPostResult }) => (
      <SearchPostCard
        item={item}
        colors={colors}
        onPressItem={onPressItem}
      />
    ),
    [colors, onPressItem],
  );
  const listFooter = useCallback(
    () =>
      loadingMore ? (
        <View style={styles.postFooter}>
          <ActivityIndicator size="small" color={colors.primary} />
        </View>
      ) : !hasMore && items.length > 0 ? (
        <Text style={[styles.noMore, { color: colors.textDisabled }]}>没有更多了</Text>
      ) : null,
    [loadingMore, hasMore, items.length, colors.primary, colors.textDisabled],
  );

  return (
    <LegendList
      recycleItems
      data={items}
      keyExtractor={postKeyExtractor}
      decelerationRate="normal"
      keyboardDismissMode="on-drag"
      renderItem={renderItem}
      drawDistance={250}
      contentContainerStyle={contentContainerStyle}
      refreshControl={
        <RefreshControl
          refreshing={refreshing}
          onRefresh={onRefresh}
          tintColor={colors.primary}
        />
      }
      onEndReached={onEndReached}
      onEndReachedThreshold={0.3}
      ListFooterComponent={listFooter}
      ItemSeparatorComponent={postListSeparator}
      keyboardShouldPersistTaps="handled"
    />
  );
}

const styles = StyleSheet.create({
  // 搜索结果列表底部：紧贴安全区（不要再用大面积 paddingBottom，
  // 短结果页会在底部留下一大块 #F2F2F7 纯色区域——搜索页没有底栏
  // 可以盖住，底部应保持有内容贴底）。
  listContent: {
    paddingBottom: 24,
  },
  // 骨架/失败态：列表头（搜索行+分段）置顶展示，数据到达后由
  // LegendList ListHeader 接管滚动语义（2026-08-26 随滚退出）
  listFill: {
    flex: 1,
  },
  centerWrap: {
    alignItems: 'center',
    justifyContent: 'center',
    paddingTop: 80,
    gap: 12,
  },
  retryBtn: {
    paddingHorizontal: 24,
    paddingVertical: 10,
    borderRadius: 999,
    marginTop: 4,
  },
  retryText: {
    fontSize: 14,
    fontWeight: '600',
  },
  emptyWrap: {
    alignItems: 'center',
    justifyContent: 'center',
    paddingTop: 80,
    gap: 12,
  },
  emptyTitle: {
    fontSize: 15,
  },
  footerLoader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: 16,
    gap: 8,
  },
  footerText: {
    fontSize: 13,
  },
  postFooter: {
    paddingVertical: 16,
    alignItems: 'center',
  },
  noMore: {
    textAlign: 'center',
    paddingVertical: 16,
    fontSize: 13,
  },
  postSeparator: {
    height: 8,
  },
});
