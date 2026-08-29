/**
 * UserTabList — the three-tab paged list of the user profile page:
 * 贴子 (threads) / 回复 (replies) / 关注的吧 (forums).
 *
 * Extracted from the user profile page ([uid].tsx) during the page split.
 * One LegendList instance is reused for every tab; the fetcher branch is
 * selected by `tab` and rows are split into ForumRow / ThreadRow. The
 * profile card is passed in as `header` (ListHeaderComponent).
 */

import React, { useCallback, useEffect } from 'react';
import {
  Pressable,
  RefreshControl,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import type { EdgeInsets } from 'react-native-safe-area-context';
import { LegendList } from '@legendapp/list/react-native';
import { Link } from 'expo-router';

import { SymbolView } from '@/components/ui/SymbolView';
import { Avatar } from '@/components/ui/Avatar';
import { EmptyState } from '@/components/ui/EmptyState';
import { ErrorState } from '@/components/ui/ErrorState';
import { SkeletonList } from '@/components/ui/Skeleton';
import { LoadMoreFooter } from '@/components/ui/LoadMoreFooter';
import { showToast } from '@/components/ui/Toast';
import TweetCard from '@/components/feed/TweetCard';

import {Spacing, typographyStyles, RadiusStyle} from '@/theme';
import type { SemanticColors } from '@/theme';
import { flattenStyle, contentToText } from '@/utils';
import { usePagedList } from '@/hooks/usePagedList';
import { mapProtoThread } from '@/services/api/endpoints/helpers';
import { userPost, userLikeForum } from '@/services/api/endpoints/user';
import type { UserInfo } from '@/types';

/** 列表行分隔（关注的吧 tab 使用；TweetCard 自带间距） */
export const ProfileItemSeparator = () => <View style={{ height: Spacing.sm }} />;

/**
 * 顶栏让位高度：页面已是纯 RN 根 + headerTransparent（吧页终局范式），
 * 内容从 y=0 起，由列表 contentContainerStyle 手动补状态栏 + 实测导航栏
 * （56pt，与 [uid].tsx PROFILE_TOP_CLEARANCE / 吧页同款，卡片贴 bar 下沿）。
 */
const TOP_CLEARANCE = 56;

// ---------- Rows ----------

/** 关注的吧行：吧头像 + 吧名 + 等级 + chevron，点击进吧页 */
function ForumRow({ item, colors }: { item: any; colors: SemanticColors }) {
  return (
    <Link href={{ pathname: '/forum/[name]', params: { name: item.forumName || '' } }} push asChild>
      <Pressable
        style={flattenStyle([styles.forumItem, { backgroundColor: colors.card }])}
      >
        <Avatar
          source={item.avatar}
          initials={(item.forumName || '?')?.slice(0, 2)}
          size={36}
        />
        <View style={styles.forumInfo}>
          <Text style={[styles.forumName, { color: colors.text }]}>{item.forumName}吧</Text>
          <Text style={[styles.forumLevel, { color: colors.textTertiary }]}>
            {item.levelName || ''}
          </Text>
        </View>
        <SymbolView name="chevron.right" size={14} tintColor={colors.textTertiary} />
      </Pressable>
    </Link>
  );
}

/** 贴子/回复行：统一 Twitter 信息流卡片（与首页/吧页同款 TweetCard）。 */
function ThreadRow({
  item,
  uid,
  profileUser,
}: {
  item: any;
  uid: string;
  profileUser?: UserInfo | null;
}) {
  const thread = mapProtoThread(item);
  // userPost 原生白名单不透传作者字段，主页帖子作者即本人，用资料卡兜底，
  // 保证与首页/吧页卡片一样显示真实昵称/头像。
  thread.authorId = String(item.userId ?? uid);
  thread.authorName = item.userName || profileUser?.name || '';
  thread.authorNameShow =
    item.nameShow || item.userName || profileUser?.nameShow || profileUser?.name || '';
  thread.authorPortrait = item.userPortrait || profileUser?.portrait || '';
  // 回复行无 title 时回退正文，保证卡片有主文案。
  if (!thread.title) thread.title = contentToText(item.content);
  // 列表 key 用 postId（回复行唯一），卡片跳转/回收必须用主题帖 threadId：
  // mapProtoThread 的 id 优先读 raw.id（= postId），不覆盖会跳到 postId 而非帖子。
  thread.id = String(thread.threadId || thread.id);
  return <TweetCard thread={thread} timeType="create" />;
}

// ---------- Component ----------

export interface UserTabListProps {
  tab: string;
  uid: string;
  colors: SemanticColors;
  insets: EdgeInsets;
  header: React.ReactElement | null;
  profileUser?: UserInfo | null;
  /** 资料卡刷新（返回是否成功；失败时本组件弹 toast 提示） */
  onHeaderRefresh: () => Promise<boolean>;
}

export function UserTabList({
  tab,
  uid,
  colors,
  insets,
  header,
  profileUser,
  onHeaderRefresh,
}: UserTabListProps) {
  const paged = usePagedList<any, { tab: string; uid: string }>({
    fetcher: async (p, params, signal) => {
      let data: { items: any[]; hasMore: boolean };
      if (params.tab === 'threads') {
        data = await userPost(params.uid, p, true, signal);
      } else if (params.tab === 'replies') {
        data = await userPost(params.uid, p, false, signal);
      } else {
        data = await userLikeForum(params.uid, p, signal);
      }
      return { items: data.items, hasMore: data.hasMore, nextPage: p + 1 };
    },
    params: { tab, uid },
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
  } = paged;

  useEffect(() => {
    load(1, { tab, uid });
  }, [tab, uid, load]);

  // 下拉刷新 = 资料卡刷新 + 列表刷新并行。资料卡已有内容时刷新失败无
  // 整页错误态承接（error 只在 !user 时展示），这里用轻量 toast 提示。
  const handleRefresh = useCallback(async () => {
    const [profileOk] = await Promise.all([onHeaderRefresh(), refresh()]);
    if (!profileOk) showToast('主页信息刷新失败');
  }, [onHeaderRefresh, refresh]);

  const handleLoadMore = useCallback(async () => {
    if (!hasMore || loadingMore || loading) return;
    await loadMore();
  }, [hasMore, loadingMore, loading, loadMore]);

  const renderItem = useCallback(
    ({ item }: { item: any }) => {
      if (tab === 'forums') {
        return <ForumRow item={item} colors={colors} />;
      }
      return <ThreadRow item={item} uid={uid} profileUser={profileUser} />;
    },
    [tab, colors, uid, profileUser],
  );

  const userKeyExtractor = useCallback(
    // proto 路径帖子 id 在 userPost 已映射为 id；此处再兜底 thread_id/post_id，
    // 保证 key 恒定非索引（索引 key 会让 LegendList 虚拟化错乱产生行空洞）。
    // 用 || 链而非 ??：映射 miss 时 id 是 ''（非 nullish），?? 会短路成恒空串，
    // 全部 key 相同 → LegendList 只渲染 1 个 cell（"帖子间大片空白"）。
    (item: any, idx: number) =>
      String(item.id || item.thread_id || item.threadId || item.post_id || item.postId || item.forumId || idx),
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
      return <ErrorState message={error} onRetry={() => load(1, { tab, uid })} />;
    }
    let description: string;
    if (tab === 'threads') description = '还没有发过贴子';
    else if (tab === 'replies') description = '还没有回复';
    else description = '还没有关注的吧';
    return (
      // 空态容器撑高+垂直居中：数据空时列表只剩 header（资料卡+segment），
      // 不给 minHeight 时 SwiftUI 空态初次测量 0 高、与 segment 槽重叠
      //（2026-08-27 真机复现："暂无内容 与 segment 栏重叠"）。
      <View style={[styles.listEmptyWrap, { minHeight: 360 }]}>
        <EmptyState title="暂无内容" description={description} icon="tray.fill" />
      </View>
    );
  }, [loading, error, tab, load, uid]);
  const listFooter = useCallback(
    () =>
      (
        <LoadMoreFooter
          hasMore={hasMore}
          loading={loadingMore}
          colors={colors}
          onLoadMore={handleLoadMore}
        />
      ),
    [loadingMore, hasMore, colors, handleLoadMore],
  );

  // LegendList 一次渲染足量行完成行高测量，行高用实测均值自动处理——
  // 避免首帧估计偏差导致行高测量错乱、出现"帖子间大片空白"
  //（subposts/历史/收藏同款处理）。
  return (
    <LegendList
      recycleItems
      data={items}
      keyExtractor={userKeyExtractor}
      decelerationRate="normal"
      drawDistance={250}
      renderItem={renderItem}
      ListHeaderComponent={header}
      ListEmptyComponent={listEmpty}
      contentContainerStyle={[
        // 帖子/回复 tab 用 TweetCard（自带 marginHorizontal:10），列表不再加横向 padding，
        // 避免双重缩进；关注的吧 tab 的行卡片仍需 listContent 的 10pt 边距。
        // 顶部让位：headerTransparent 后内容从 y=0 起，资料卡+分段栏都在
        // ListHeaderComponent 内随列表原生滚动、滑到顶自然从顶栏下方退出
        //（吧页信息流同款跟手），此处手动补一次状态栏+导航栏高度。
        tab === 'forums' ? styles.listContent : styles.listContentNoPad,
        { paddingTop: insets.top + TOP_CLEARANCE, paddingBottom: insets.bottom + Spacing.lg },
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
      ItemSeparatorComponent={tab === 'forums' ? ProfileItemSeparator : undefined}
    />
  );
}

// ---------- Styles ----------

const styles = StyleSheet.create({
  listEmptySkeleton: { paddingTop: Spacing.md },
  // 空态容器：居中显示并保底高度（见 listEmpty 注释）
  listEmptyWrap: {
    justifyContent: 'center',
    paddingTop: Spacing.lg,
  },
  // 列表内容卡片距屏边统一 10pt
  listContent: { paddingHorizontal: 10 },
  // 帖子/回复 tab：TweetCard 自带横向 10pt，列表不加 padding
  listContentNoPad: { paddingHorizontal: 0 },

  // Forum Items
  forumItem: {
    flexDirection: 'row',
    alignItems: 'center',
    padding: Spacing.md,
    ...RadiusStyle.card,
    gap: 10,
  },
  forumInfo: { flex: 1, gap: 2 },
  forumName: { fontSize: 14, fontWeight: '600' },
  forumLevel: typographyStyles.caption2,
});