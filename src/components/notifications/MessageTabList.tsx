// ============================================================
// MessageTabList — 单 tab 消息列表（pager 一页）
//
// 从 notifications.tsx 拆出：usePagedList 接线、RefreshControl、
// 空态/错误态/骨架、分页 footer 与消息行渲染。
// ============================================================

import { useCallback, useEffect, useMemo, useRef } from 'react';
import { RefreshControl, StyleSheet, View } from 'react-native';
import { Text as RNText } from '../ui/CompatText';
import { LegendList } from '@legendapp/list/react-native';
import { useRouter } from 'expo-router';
import { hapticForScene } from '@/theme/hapticsMap';
import { Spacing } from '@/theme';
import { Avatar } from '@/components/ui/Avatar';
import { SymbolView } from '@/components/ui/SymbolView';
import { LoadMoreFooter } from '@/components/ui/LoadMoreFooter';
import { ErrorState } from '@/components/ui/ErrorState';
import { EmptyState } from '@/components/ui/EmptyState';
import { SkeletonList } from '@/components/ui/Skeleton';
import { PressScale } from '@/components/ui/PressScale';
import { usePagedList } from '@/hooks/usePagedList';
import { getMoreMsg } from '@/services/api';
import { useBlockFilter } from '@/hooks/useBlockFilter';
import { BlockManager } from '@/utils/BlockManager';
import { useTimeLabel } from '@/hooks/useTimeLabel';
import {
  AvatarPressable,
  EntranceRow,
  getSegmentLabel,
  getTypeIcon,
  messageKeyExtractor,
  messageRowStyles,
  type CategorizedMessage,
  type MessageTab,
} from '@/components/notifications/MessageRow';
import type { SemanticColors } from '@/theme/colors';
import type { MessageItem } from '@/types';

interface MessageTabListProps {
  tab: MessageTab;
  isLoggedIn: boolean;
  colors: SemanticColors;
  /** 当前是否为激活页（只有激活页响应 tab 重按刷新信号） */
  active: boolean;
  /** tab 重按（tabBar reselect）刷新信号：变化即刷新 */
  refreshSignal: number;
}

export function MessageTabList({
  tab,
  isLoggedIn,
  colors,
  active,
  refreshSignal,
}: MessageTabListProps) {
  const router = useRouter();
  const { blockedWords, blockedUsers } = useBlockFilter();
  const timeLabel = useTimeLabel();

  const paged = usePagedList<CategorizedMessage, { type: MessageTab; isLoggedIn: boolean }>({
    fetcher: async (p, params, signal) => {
      if (!params.isLoggedIn) return { items: [], hasMore: false };
      // getMoreMsg：按当前分类只拉对应接口（hasMore 只反映当前分类，避免已耗尽分类空翻页）。
      const data = await getMoreMsg(params.type, p - 1, signal);
      return { items: data.items, hasMore: data.hasMore, nextPage: p + 1 };
    },
    params: { type: tab, isLoggedIn },
  });
  const {
    items: messages,
    loading: msgLoading,
    refreshing,
    hasMore,
    loadingMore,
    error: msgError,
    load,
    refresh,
    loadMore,
  } = paged;

  // 首屏加载：usePagedList 不自发拉取（全站消费方约定——UserTabList/
  // SocialTabList 均在 useEffect 里调 load(1, ...)，本组件此前漏了这步：
  // loading 恒 true 卡骨架分支，数据/空态/错误态全都到达不了，
  // 真机表现为"消息页一片空白"（8-28 定位根因）。登录态恢复
  // （未登录 → 登录）或 tab 变化时同样触发首屏。
  useEffect(() => {
    if (!isLoggedIn) return;
    load(1, { type: tab, isLoggedIn }, 'initial');
    // eslint-disable-next-line react-hooks/exhaustive-deps -- load 稳定（依赖仅 maxItems），
    // 触发条件即 tab/isLoggedIn 变化；每条 fetcher 经 fetcherRef 读最新闭包
  }, [tab, isLoggedIn]);

  // 首屏入场标记：仅数据首次到达批次做 stagger 入场。
  const entranceDoneRef = useRef(false);
  useEffect(() => {
    if (messages.length > 0) entranceDoneRef.current = true;
  }, [messages.length]);

  const visibleMessages = useMemo(() => {
    if (blockedWords.length === 0 && blockedUsers.length === 0) return messages;
    return messages.filter((m) => {
      if (BlockManager.shouldBlockContent(m.content || '', blockedWords)) return false;
      if (m.fromUserId && BlockManager.shouldBlockUser(m.fromUserId, m.fromUserName || null, blockedUsers)) return false;
      return true;
    });
  }, [messages, blockedWords, blockedUsers]);

  // Tab 重按刷新：仅当前激活页响应（refreshSignal 变化一次刷一次）。
  // refresh 是 usePagedList 的稳定 useCallback，ref 同步放 useEffect 里，
  // 不在渲染期写 ref。
  const refreshRef = useRef(refresh);
  useEffect(() => {
    refreshRef.current = refresh;
  }, [refresh]);
  useEffect(() => {
    if (active && refreshSignal > 0) {
      refreshRef.current().catch(() => {});
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- 仅随刷新信号触发
  }, [refreshSignal, active]);

  const handleRefresh = useCallback(async () => {
    // 下拉释放即刻反馈，不等网络返回
    hapticForScene('toggle');
    await refresh();
  }, [refresh]);

  const handleRetry = useCallback(() => {
    load(1, { type: tab, isLoggedIn }, 'initial');
  }, [load, tab, isLoggedIn]);

  const handleLoadMore = useCallback(async () => {
    // loading 双保险：usePagedList 三重兜底已有，此层与 UserTabList 对齐
    //（首屏加载中 onEndReached 也可能触发，白挡一次空翻页）
    if (msgLoading || loadingMore || !hasMore) return;
    await loadMore();
  }, [msgLoading, loadingMore, hasMore, loadMore]);

  const handleMessagePress = useCallback((msg: MessageItem) => {
    hapticForScene('press');
    if (msg.threadId) {
      router.push(`/thread/${msg.threadId}${msg.postId ? `?postId=${msg.postId}` : ''}`);
    }
  }, [router]);

  const handleAuthorPress = useCallback((msg: MessageItem) => {
    if (!msg.fromUserId) return;
    hapticForScene('press');
    router.push(`/user/${msg.fromUserId}`);
  }, [router]);

  const renderMessageItem = useCallback(
    ({ item, index }: { item: CategorizedMessage; index: number }) => {
      const icon = getTypeIcon(item.category, colors);
      return (
        <EntranceRow index={index} animateEntry={!entranceDoneRef.current}>
          <PressScale onPress={() => handleMessagePress(item)}>
            <View
              style={[messageRowStyles.messageRow, { backgroundColor: colors.card }]}
            >
              {!item.isRead && <View style={[messageRowStyles.unreadDot, { backgroundColor: colors.primary }]} />}
              {item.fromUserId ? (
                <AvatarPressable msg={item} onAuthorPress={handleAuthorPress} style={messageRowStyles.messageAvatarPressable}>
                  <Avatar
                    source={item.fromUserPortrait || undefined}
                    initials={(item.fromUserName || '吧')?.charAt(0)}
                    size={40}
                  />
                </AvatarPressable>
              ) : (
                <Avatar
                  source={item.fromUserPortrait || undefined}
                  initials={(item.fromUserName || '吧')?.charAt(0)}
                  size={40}
                />
              )}
              <View style={messageRowStyles.messageBody}>
                <View style={messageRowStyles.messageHeader}>
                  {item.fromUserId ? (
                    <AvatarPressable msg={item} onAuthorPress={handleAuthorPress} style={messageRowStyles.messageNamePressable}>
                      <RNText style={[messageRowStyles.messageName, { color: colors.text }]} numberOfLines={1}>
                        {item.fromUserName}
                      </RNText>
                    </AvatarPressable>
                  ) : (
                    <RNText style={[messageRowStyles.messageName, { color: colors.text }]} numberOfLines={1}>
                      {item.fromUserName}
                    </RNText>
                  )}
                  <SymbolView
                    name={icon.name}
                    size={13}
                    weight="semibold"
                    tintColor={icon.color}
                  />
                </View>
                <RNText style={[messageRowStyles.messageContent, { color: colors.textSecondary }]} numberOfLines={2}>
                  {item.content || '...'}
                </RNText>
                {item.threadTitle ? (
                  <RNText style={[messageRowStyles.messageThread, { color: colors.textTertiary }]} numberOfLines={1}>
                    原贴: {item.threadTitle}
                  </RNText>
                ) : null}
                <RNText style={[messageRowStyles.messageTime, { color: colors.textDisabled }]}>
                  {timeLabel(item.createTime)}
                </RNText>
              </View>
            </View>
          </PressScale>
        </EntranceRow>
      );
    },
    [colors, handleMessagePress, handleAuthorPress],
  );

  const renderFooter = useCallback(
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

  return (
    <View style={{ flex: 1 }}>
      {msgLoading && messages.length === 0 ? (
        <SkeletonList variant="row" count={8} style={styles.messageSkeleton} />
      ) : msgError && messages.length === 0 ? (
        <ErrorState
          title="加载失败"
          message={msgError}
          icon="exclamationmark.triangle"
          onRetry={handleRetry}
          retryLabel="重试"
        />
      ) : visibleMessages.length === 0 ? (
        // 空态包 ThemedHost（EmptyState 内置）+ 保底高度：裸 ContentUnavailableView
        // 在 SegmentPager 内高度塌缩成一片空白（2026-08-27 真机"消息界面全空白、
        // 无提示"根因）；与个人主页空态 minHeight 隔离同款修复。
        <View style={[styles.messageEmptyWrap, { minHeight: 320 }]}>
          <EmptyState title="暂无消息" description={`暂无${getSegmentLabel(tab)}`} icon="bell" />
        </View>
      ) : (
        <LegendList
          data={visibleMessages}
          keyExtractor={messageKeyExtractor}
          renderItem={renderMessageItem}
          ListFooterComponent={renderFooter}
          contentContainerStyle={styles.messageListContent}
          refreshControl={
            <RefreshControl
              refreshing={refreshing}
              onRefresh={handleRefresh}
              tintColor={colors.primary}
            />
          }
          onEndReached={handleLoadMore}
          onEndReachedThreshold={0.4}
          drawDistance={300}
        />
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  // 骨架屏容器
  messageSkeleton: { paddingHorizontal: Spacing.lg, paddingTop: Spacing.sm, paddingBottom: 24 },
  // 空态容器：居中 + 保底高度（见空态注释）
  messageEmptyWrap: {
    justifyContent: 'center',
    paddingTop: Spacing.lg,
  },
  messageListContent: {
    paddingHorizontal: Spacing.lg,
    paddingTop: Spacing.sm,
    // 24 ≈ home indicator：末行压进底栏玻璃下，隐藏后不留 60pt 空带
    paddingBottom: 24,
  },
});