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
  getTypeIcon,
  messageKeyExtractor,
  messageRowStyles,
  type CategorizedMessage,
  type MessageTab,
} from '@/components/notifications/MessageRow';
import type { SemanticColors } from '@/theme/colors';
import type { MessageItem } from '@/types';

/** 分 tab 专属空态文案（2026-08-29 用户反馈：空态要能区分"没消息"） */
const MESSAGE_EMPTY_STATE: Record<MessageTab, { title: string; description: string }> = {
  reply: { title: '暂无回复', description: '还没有人回复你的贴子' },
  at: { title: '暂无@提到我', description: '暂时没有 @你 的内容' },
  agree: { title: '暂无收到的赞', description: '你收到的赞会显示在这里' },
};


/**
 * 消息空态（2026-08-31 纯 RN 自绘）：SwiftUI ContentUnavailableView 经
 * ThemedHost(matchContents) 在 SegmentPager 嵌套页里测量塌缩为 0（外层
 * flex/minHeight 均无效，用户实测看不到文字）——RN 文本无宿主测量问题。
 */
function MsgEmptyState({
  icon,
  title,
  description,
  colors,
}: {
  icon: string;
  title: string;
  description: string;
  colors: SemanticColors;
}) {
  return (
    <View style={styles.msgEmptyInner}>
      <SymbolView name={icon} size={34} tintColor={colors.textTertiary} />
      <RNText style={[styles.msgEmptyTitle, { color: colors.text }]}>{title}</RNText>
      {description ? (
        <RNText style={[styles.msgEmptyDesc, { color: colors.textSecondary }]}>
          {description}
        </RNText>
      ) : null}
    </View>
  );
}

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
      {!isLoggedIn ? (
        // 未登录：显式说明（此前未登录时 loading 恒 true、骨架屏永转，
        // "加载失败还是没消息"无从判断——2026-08-29 用户反馈）
        <View style={[styles.messageEmptyWrap, { minHeight: 320 }]}>
          <MsgEmptyState
            icon="person.crop.circle.badge.questionmark"
            title="未登录"
            description="登录后查看回复、@提到我 与收到的赞"
            colors={colors}
          />
        </View>
      ) : msgLoading && messages.length === 0 ? (
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
        // 空态：**纯 RN 自绘**（2026-08-31）——SwiftUI ContentUnavailableView
        // 经 ThemedHost(matchContents) 在 SegmentPager 嵌套页里测量塌缩为 0，
        // 外层 flex 修复无效（用户实测"看不到无消息文字"）；RN 文本无宿主
        // 测量问题，任何容器都稳定可见。分 tab 专属文案。
        <View style={[styles.messageEmptyWrap, { minHeight: 320 }]}>
          <MsgEmptyState
            icon="bell"
            title={MESSAGE_EMPTY_STATE[tab].title}
            description={MESSAGE_EMPTY_STATE[tab].description}
            colors={colors}
          />
        </View>
      ) : (
        <LegendList
          recycleItems
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
  // 空态容器：in-flow flex:1 占满剩余高度并居中（2026-09-01 终局）。
  // 此前 absolute 铺满依赖"包含块高度"——v8 iOS 页包装对 RN 子视图零
  // AutoLayout 约束，若 Fabric 挂载未按页高应用则 flex 链塌缩，absolute
  // 回落 minHeight 320 + top 锚定、文字悬在页面上部（用户实测"偏上"）。
  // in-flow 与 LegendList 走完全相同的高度渠道：列表显示正常则空态必然
  // 同高同基准（absolute 在链断时可正常而列表异常——恰反）。
  // minHeight 320 仅兜底极端塌缩，行为不劣于原方案。
  messageEmptyWrap: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    minHeight: 320,
    paddingTop: Spacing.lg,
  },
  // 纯 RN 空态内容（SwiftUI 宿主塌缩的替代，见 MsgEmptyState）
  msgEmptyInner: {
    alignItems: 'center',
    gap: 8,
    paddingHorizontal: Spacing.lg,
  },
  msgEmptyTitle: {
    fontSize: 17,
    fontWeight: '600',
    marginTop: 4,
  },
  msgEmptyDesc: {
    fontSize: 13,
    textAlign: 'center',
  },
  messageListContent: {
    paddingHorizontal: Spacing.lg,
    paddingTop: Spacing.sm,
    // 24 ≈ home indicator：末行压进底栏玻璃下，隐藏后不留 60pt 空带
    paddingBottom: 24,
  },
});