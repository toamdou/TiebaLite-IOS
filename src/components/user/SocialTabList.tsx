/**
 * SocialTabList — 粉丝/关注独立视图.
 *
 * Extracted from the user profile page ([uid].tsx) during the page split.
 * Rendered as an absolute-fill overlay on top of the (still-mounted) main
 * view, so the three main tabs keep their list state while browsing fans
 * and follows. Reuses social.ts getFans/getFollows (20/页，pn 从 1 开始);
 * SocialUser 无 level/时间字段，行内展示昵称 + 用户名副行。
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import { Pressable, RefreshControl, StyleSheet, View } from 'react-native';
import { Text } from '../ui/CompatText';
import type { EdgeInsets } from 'react-native-safe-area-context';
import { LegendList } from '@legendapp/list/react-native';
import { Link } from 'expo-router';

import { SymbolView } from '@/components/ui/SymbolView';
import { Avatar } from '@/components/ui/Avatar';
import { TiebaSegmentedControl } from '@/components/ui/TiebaSegmentedControl';
import { EmptyState } from '@/components/ui/EmptyState';
import { ErrorState } from '@/components/ui/ErrorState';
import { SkeletonList } from '@/components/ui/Skeleton';
import { LoadMoreFooter } from '@/components/ui/LoadMoreFooter';

import {Spacing, typographyStyles, RadiusStyle} from '@/theme';
import type { SemanticColors } from '@/theme';
import { hapticForScene } from '@/theme/hapticsMap';
import { flattenStyle } from '@/utils';
import { usePagedList } from '@/hooks/usePagedList';
import { getFans, getFollows, type SocialUser } from '@/services/api/endpoints/social';
import { ProfileItemSeparator } from '@/components/user/UserTabList';
import { HdrPressable } from '@/components/ui/HdrPressable';

export type SocialMode = 'fans' | 'follows';

export interface SocialTabListProps {
  uid: string;
  colors: SemanticColors;
  insets: EdgeInsets;
  initialMode: SocialMode;
  onClose: () => void;
}

export function SocialTabList({
  uid,
  colors,
  insets,
  initialMode,
  onClose,
}: SocialTabListProps) {
  const listRef = useRef<any>(null);
  const [mode, setMode] = useState<SocialMode>(initialMode);

  const paged = usePagedList<SocialUser, { uid: string; mode: SocialMode }>({
    fetcher: async (p, params, signal) => {
      const data =
        params.mode === 'fans'
          ? await getFans(params.uid, p, signal)
          : await getFollows(params.uid, p, signal);
      return { items: data.items, hasMore: data.hasMore, nextPage: p + 1 };
    },
    params: { uid, mode },
  });

  const {
    items,
    hasMore,
    loading,
    loadingMore,
    refreshing,
    error,
    load,
    refresh,
    loadMore,
    setItems,
  } = paged;

  useEffect(() => {
    // 切换粉丝/关注后旧 mode 数据若残留，loading && items.length===0 不成立
    // → 新 mode 下会闪现旧列表。先清空再请求，配合 listEmpty 骨架立即展示
    // 加载态（与 posts 页同款处理）。
    setItems([]);
    load(1, { uid, mode });
  }, [uid, mode, load, setItems]);

  const handleModeChange = useCallback((value: string) => {
    hapticForScene('toggle');
    listRef.current?.scrollToOffset({ offset: 0, animated: false });
    setMode(value === 'follows' ? 'follows' : 'fans');
  }, []);

  const handleRefresh = useCallback(async () => {
    await refresh();
    hapticForScene('toggle');
  }, [refresh]);

  const handleLoadMore = useCallback(async () => {
    if (!hasMore || loadingMore || loading) return;
    await loadMore();
  }, [hasMore, loadingMore, loading, loadMore]);

  const listHeader = useCallback(
    // 粉丝/关注分段与主页三 tab 同款原生 UISegmentedControl（吧页终局方案）：
    // 整页零 SwiftUI，杜绝 Host 嵌套触摸断链/布局错位族问题。顶栏让位由
    // [uid].tsx 的 socialOverlay paddingTop 承接（页面已是纯 RN 根，覆盖层
    // 自 y=0 起），此处不再叠加。
    () => (
      <View style={styles.socialTopBar}>
        <HdrPressable
          onPress={() => {
            void hapticForScene('press');
            onClose();
          }}
          hitSlop={8}
          style={styles.socialCloseBtn}
          flashRadius={8}
          glowOutset={5}
          accessibilityRole="button"
          accessibilityLabel="关闭粉丝/关注列表"
        >
          <SymbolView name="xmark" size={16} weight="semibold" tintColor={colors.textSecondary} />
        </HdrPressable>
        <View style={styles.socialSegmentSlot}>
          <TiebaSegmentedControl
            segments={[
              { label: '粉丝', value: 'fans' },
              { label: '关注', value: 'follows' },
            ]}
            selectedIndex={mode === 'follows' ? 1 : 0}
            onSelect={handleModeChange}
          />
        </View>
        {/* 平衡左侧关闭按钮占位，让分段居中 */}
        <View style={styles.socialCloseBtn} />
      </View>
    ),
    [onClose, mode, handleModeChange, colors],
  );

  const renderItem = useCallback(
    ({ item }: { item: SocialUser }) => {
      const displayName = item.nickName || item.userName || '用户';
      const row = (
        <Pressable
          style={flattenStyle([styles.socialItem, { backgroundColor: colors.card }])}
          accessibilityRole="button"
          accessibilityLabel={displayName}
        >
          <Avatar source={item.portrait} initials={displayName.slice(0, 2)} size={40} />
          <View style={styles.socialInfo}>
            <Text style={[styles.socialName, { color: colors.text }]} numberOfLines={1}>
              {displayName}
            </Text>
            {item.userName && item.userName !== displayName ? (
              <Text style={[styles.socialSub, { color: colors.textTertiary }]} numberOfLines={1}>
                @{item.userName}
              </Text>
            ) : null}
          </View>
          <SymbolView name="chevron.right" size={14} tintColor={colors.textTertiary} />
        </Pressable>
      );
      return item.uid ? (
        <Link href={{ pathname: '/user/[uid]', params: { uid: item.uid } }} push asChild>
          {row}
        </Link>
      ) : (
        row
      );
    },
    [colors],
  );

  const socialKeyExtractor = useCallback(
    // 无 uid 的行给可辨识前缀防 key 撞车（匿名用户同时进列表时索引 key 相同）
    (item: SocialUser, idx: number) => item.uid || `anon-${idx}`,
    [],
  );

  const listEmpty = useCallback(() => {
    if (loading) {
      return (
        <View style={styles.listEmptySkeleton}>
          <SkeletonList variant="row" count={4} />
        </View>
      );
    }
    if (error) {
      return <ErrorState message={error} onRetry={() => load(1, { uid, mode })} />;
    }
    return mode === 'fans' ? (
      <EmptyState
        title="暂无粉丝"
        description="还没有人关注 TA"
        icon="person.crop.circle.badge.questionmark"
      />
    ) : (
      <EmptyState
        title="暂无关注"
        description="TA 还没有关注任何人"
        icon="person.crop.circle.badge.plus"
      />
    );
  }, [loading, error, load, uid, mode]);

  const listFooter = useCallback(
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

  return (
    <View style={styles.socialRoot}>
      {/* 固定顶栏（含分段控件）：不随列表滚动，避开列表 header 内嵌 SwiftUI 宿主的布局错位 */}
      {listHeader()}
      {/* 粉丝/关注列表：LegendList 一次渲染足量行完成行高测量，
          行高用实测均值自动处理（同 UserTabList 注释） */}
      <LegendList
        ref={listRef}
        data={items}
        keyExtractor={socialKeyExtractor}
        decelerationRate="normal"
        drawDistance={250}
        renderItem={renderItem}
        ListEmptyComponent={listEmpty}
        contentContainerStyle={[
          styles.listContent,
          { paddingBottom: insets.bottom + Spacing.lg },
        ]}
        refreshControl={
          <RefreshControl
            refreshing={refreshing}
            onRefresh={handleRefresh}
            tintColor={colors.primary}
          />
        }
        onEndReached={handleLoadMore}
        onEndReachedThreshold={0.3}
        ListFooterComponent={listFooter}
        ItemSeparatorComponent={ProfileItemSeparator}
      />
    </View>
  );
}

// ---------- Styles ----------

const styles = StyleSheet.create({
  // 粉丝/关注独立视图容器：顶栏固定 + 列表滚动
  socialRoot: { flex: 1 },
  // 粉丝/关注独立视图顶部栏（固定，不在列表内）
  socialTopBar: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: Spacing.sm,
    paddingHorizontal: Spacing.sm,
  },
  socialCloseBtn: {
    width: 36,
    height: 36,
    justifyContent: 'center',
    alignItems: 'center',
  },
  // 分段槽占满两按钮之间（原生控件在 RN 树内由 Yoga 定宽）
  socialSegmentSlot: { flex: 1, marginHorizontal: Spacing.sm },

  listEmptySkeleton: { paddingTop: Spacing.md },
  // 列表内容卡片距屏边统一 10pt
  listContent: { paddingHorizontal: 10 },

  // Social Items (粉丝/关注)
  socialItem: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: Spacing.md,
    ...RadiusStyle.card,
    gap: 10,
  },
  socialInfo: { flex: 1, gap: 2 },
  socialName: { fontSize: 14, fontWeight: '600' },
  socialSub: typographyStyles.caption2,
});