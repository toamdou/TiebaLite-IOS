/**
 * ExploreTab 热榜段（从 app/(tabs)/explore.tsx 拆出）。
 *
 * 话题横向滚动 + Tab 分类 + 排名帖子列表；active 标记由页面传入，
 * 仅激活段响应 TAB_RESELECT 重拉。
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  View, Pressable, StyleSheet, Text as RNText, ActivityIndicator,
  ScrollView as RNScrollView, DeviceEventEmitter, RefreshControl,
} from 'react-native';
import { LegendList } from '@legendapp/list/react-native';
import { useRouter } from 'expo-router';
import {
  VStack, Button, Label,
  ContentUnavailableView, Spacer,
  RNHostView,
} from '@expo/ui/swift-ui';
import { hapticForScene } from '@/theme/hapticsMap';
import { useThemeColors } from '@/theme/ThemeContext';
import { typographyStyles } from '@/theme/typography';
import {Spacing, RadiusStyle, Radius} from '@/theme';
import { Avatar } from '@/components/ui/Avatar';
import { SymbolView } from '@/components/ui/SymbolView';
import { formatCount } from '@/utils';
import type { HotTopic, HotTabInfo, HotThreadInfo } from '@/types';
import { hotThreadList } from '@/services/api/endpoints/feed';
import { HOT_RANK_COLORS, TOPIC_CHIP_COLORS } from '@/constants/rank';
import { TAB_RESELECT_EVENT } from '@/constants/events';
import { EntranceRow } from '@/components/feed/EntranceRow';
import { SkeletonList } from '@/components/ui/Skeleton';
import { SegmentFade } from '@/components/feed/SegmentFade';
import { HdrPressable } from '@/components/ui/HdrPressable';

function hotThreadKeyExtractor(item: HotThreadInfo) {
  return item.threadId;
}

// active：热榜是否为当前可见段（同 FeedContent，TAB_RESELECT 时非激活不重拉）。
export function HotListContent({ active }: { active: boolean }) {
  const { colors } = useThemeColors();
  const router = useRouter();
  const [topics, setTopics] = useState<HotTopic[]>([]);
  const [tabs, setTabs] = useState<HotTabInfo[]>([]);
  const [threads, setThreads] = useState<HotThreadInfo[]>([]);
  const [activeTab, setActiveTab] = useState('all');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [refreshing, setRefreshing] = useState(false);
  // 首屏入场标记（同 FeedContent）
  const entranceDoneRef = useRef(false);
  useEffect(() => {
    if (threads.length > 0) entranceDoneRef.current = true;
  }, [threads.length]);

  const loadHot = useCallback(async (tabCode = 'all', silent = false) => {
    try {
      if (!silent) {
        setLoading(true);
        setError(null);
      }
      const data = await hotThreadList(tabCode);
      setTopics(data.topics ?? []);
      setTabs(data.tabs ?? []);
      setThreads(data.threads ?? []);
      setActiveTab(tabCode);
    } catch (e: any) {
      setError(e?.message || '加载热榜失败');
    } finally {
      setLoading(false);
    }
  }, []);

  const handleRefresh = useCallback(async () => {
    setRefreshing(true);
    try {
      await loadHot(activeTab, true);
    } finally {
      setRefreshing(false);
    }
    hapticForScene('toggle');
  }, [activeTab, loadHot]);

  // eslint-disable-next-line react-hooks/set-state-in-effect -- initial data fetch; state updates happen after the async boundary.
  useEffect(() => { loadHot('all', true); }, [loadHot]);

  useEffect(() => {
    const sub = DeviceEventEmitter.addListener(TAB_RESELECT_EVENT, (tabName: string) => {
      // 仅热榜为当前激活段时响应重选刷新（三路并发修复，同 FeedContent）。
      if (tabName === 'explore' && active) loadHot();
    });
    return () => sub.remove();
  }, [loadHot, active]);

  // stale-while-revalidate: 切换 Tab 时保留旧内容并降低透明度
  const isReloading = loading && threads.length > 0;

  const renderHotItem = useCallback(({ item, index }: { item: HotThreadInfo; index: number }) => {
    const rank = index + 1;
    const rankColor = rank <= 3 ? HOT_RANK_COLORS[rank - 1] : colors.textTertiary;
    const rankBg = rank <= 3 ? rankColor + '15' : 'transparent';
    return (
      <EntranceRow index={index} animateEntry={!entranceDoneRef.current}>
        <Pressable
        style={({ pressed }) => [
          styles.hotCard,
          { backgroundColor: colors.card },
          { opacity: pressed ? 0.9 : 1, transform: [{ scale: pressed ? 0.98 : 1 }] },
        ]}
        onPress={() => {
          hapticForScene('press');
          router.push(`/thread/${item.threadId}`);
        }}
      >
        <View style={[styles.hotRankBadge, { backgroundColor: rankBg }]}>
          <RNText style={[styles.hotRankNum, { color: rankColor }]}>{rank}</RNText>
        </View>
        <View style={styles.hotCardBody}>
          <RNText style={[styles.hotTitle, { color: colors.text }]} numberOfLines={2}>
            {item.title}
          </RNText>
          <View style={styles.hotMetaRow}>
            {(() => {
              // 作者行两分支仅差「可点跳用户页」：内容一致，收敛为单份 JSX
              const authorContent = (
                <>
                  <Avatar source={item.authorPortrait || undefined} initials={item.authorNameShow?.charAt(0)} size={18} />
                  <RNText style={[styles.hotUserName, { color: colors.textSecondary }]} numberOfLines={1}>
                    {item.authorNameShow || item.authorName}
                  </RNText>
                </>
              );
              if (!item.authorId) return <View style={styles.hotAuthorGroup}>{authorContent}</View>;
              return (
                <HdrPressable
                  onPress={(event) => {
                    event.stopPropagation?.();
                    hapticForScene('press');
                    router.push(`/user/${item.authorId}`);
                  }}
                  onPressIn={(event) => event.stopPropagation?.()}
                  onPressOut={(event) => event.stopPropagation?.()}
                  accessibilityRole="button"
                  accessibilityLabel="查看作者"
                  style={styles.hotAuthorGroup}
                >
                  {authorContent}
                </HdrPressable>
              );
            })()}
            <RNText style={[styles.hotDot, { color: colors.textTertiary }]}>·</RNText>
            <HdrPressable onPress={() => { void hapticForScene('press'); router.push(`/forum/${encodeURIComponent(item.forumName)}`); }} style={[styles.hotForumChip, { backgroundColor: colors.surfaceSecondary }]} flashRadius={8} glowOutset={5}>
              <RNText style={[styles.hotForumText, { color: colors.textSecondary }]}>{item.forumName}</RNText>
            </HdrPressable>
          </View>
          <View style={styles.hotActions}>
            <SymbolView name="bubble.left" size={13} tintColor={colors.textTertiary} />
            <RNText style={[styles.hotActionText, { color: colors.textTertiary }]}>{formatCount(item.replyNum)}</RNText>
            <SymbolView name="hand.thumbsup" size={13} tintColor={colors.textTertiary} />
            <RNText style={[styles.hotActionText, { color: colors.textTertiary }]}>{formatCount(item.agreeNum)}</RNText>
            <View style={{ flex: 1 }} />
            <View style={styles.hotHotNumWrap}>
              <SymbolView name="flame" size={13} tintColor={rankColor} />
              <RNText style={[styles.hotHotNum, { color: rankColor }]}>{formatCount(item.hotNum)}</RNText>
            </View>
          </View>
        </View>
      </Pressable>
      </EntranceRow>
    );
  }, [colors, router]);

  // 头/尾用 useMemo 的 JSX 元素传入 ListHeaderComponent/ListFooterComponent：
  // 若传"每次新建的组件类型"，依赖一变 React 会整树卸载重挂（含话题/分类
  // 两个横向 ScrollView，下拉刷新期间 isReloading 翻转两次就重挂两次）；
  // 元素形式按位置 reconcile，只做必要更新。
  const hotListHeader = useMemo(() => (
    <View style={{ opacity: isReloading ? 0.5 : 1 }}>
      {isReloading && (
        <View style={{ flexDirection: 'row', justifyContent: 'center', paddingVertical: 12 }}>
          <ActivityIndicator size="small" color={colors.primary} />
        </View>
      )}
      {topics.length > 0 && (
        <View style={styles.topicSection}>
          <View style={styles.topicSectionHeader}>
            <SymbolView name="flame" size={20} tintColor={colors.error} />
            <RNText style={[styles.topicSectionTitle, { color: colors.text }]}>热门话题</RNText>
          </View>
          <RNScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.topicScrollContent}>
            {topics.slice(0, 8).map((topic, idx) => {
              const c = TOPIC_CHIP_COLORS[idx % TOPIC_CHIP_COLORS.length];
              return (
                <HdrPressable
                  key={topic.topicId}
                  style={({ pressed }) => [
                    styles.topicChip,
                    { backgroundColor: c.bg, borderColor: c.border },
                    { opacity: pressed ? 0.8 : 1, transform: [{ scale: pressed ? 0.95 : 1 }] },
                  ]}
                  onPress={() => {
                    void hapticForScene('press');
                    router.push(`/topic/${topic.topicId}?name=${encodeURIComponent(topic.topicName)}`);
                  }}
                >
                  <View style={[styles.topicRankBadge, { backgroundColor: c.rank }]}>
                    <RNText style={styles.topicRankNum}>{idx + 1}</RNText>
                  </View>
                  <RNText style={[styles.topicChipText, { color: colors.text }]} numberOfLines={1}>
                    {topic.topicName}
                  </RNText>
                </HdrPressable>
              );
            })}
          </RNScrollView>
        </View>
      )}
      {tabs.length > 0 && (
        <RNScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={styles.tabScrollContent}>
          <HdrPressable
            style={({ pressed }) => [
              styles.tabItem,
              { backgroundColor: activeTab === 'all' ? colors.primary : colors.surfaceSecondary },
              { opacity: pressed ? 0.8 : 1, transform: [{ scale: pressed ? 0.95 : 1 }] },
            ]}
            onPress={() => {
              void hapticForScene('press');
              loadHot('all');
            }}
          >
            <RNText style={[styles.tabItemText, { color: activeTab === 'all' ? colors.textOnPrimary : colors.textSecondary }]}>全部</RNText>
          </HdrPressable>
          {tabs.slice(0, 6).map((tab) => (
            <HdrPressable
              key={tab.tabCode}
              style={({ pressed }) => [
                styles.tabItem,
                { backgroundColor: activeTab === tab.tabCode ? colors.primary : colors.surfaceSecondary },
                { opacity: pressed ? 0.8 : 1, transform: [{ scale: pressed ? 0.95 : 1 }] },
              ]}
              onPress={() => {
                void hapticForScene('press');
                loadHot(tab.tabCode);
              }}
            >
              <RNText style={[styles.tabItemText, { color: activeTab === tab.tabCode ? colors.textOnPrimary : colors.textSecondary }]} numberOfLines={1}>
                {tab.tabName}
              </RNText>
            </HdrPressable>
          ))}
        </RNScrollView>
      )}
      <RNText style={[styles.rankTip, { color: colors.textTertiary }]}>
        排名按热度计算 · 实时更新
      </RNText>
    </View>
  ), [topics, tabs, activeTab, colors, isReloading, loadHot, router]);

  const hotListFooter = useMemo(() => (
    threads.length > 0 ? (
      <View style={styles.hotFooter}>
        <View
          style={[styles.hotFooterCard, { backgroundColor: colors.secondarySystemGroupedBackground }]}
        >
          <RNText style={[styles.hotFooterText, { color: colors.textTertiary }]}>
            — 已展示全部热榜内容 —
          </RNText>
          <RNText style={[styles.hotFooterHint, { color: colors.textTertiary }]}>
            下拉刷新看看有没有新内容
          </RNText>
        </View>
      </View>
    ) : null
  ), [threads.length, colors.secondarySystemGroupedBackground, colors.textTertiary]);

  if (loading && threads.length === 0) {
    return (
      <SkeletonList
        variant="row"
        count={8}
        style={styles.hotSkeleton}
      />
    );
  }

  if (error && threads.length === 0) {
    return (
      <VStack alignment="center" spacing={16}>
        <Spacer />
        <ContentUnavailableView systemImage="wifi.exclamationmark" title="加载失败" description={error} />
        <Button onPress={() => loadHot()}>
          <Label title="重试" systemImage="arrow.clockwise" />
        </Button>
        <Spacer />
      </VStack>
    );
  }

  // 加载成功但无数据
  if (!loading && threads.length === 0 && topics.length === 0) {
    return (
      <VStack alignment="center" spacing={16}>
        <Spacer />
        <ContentUnavailableView systemImage="flame" title="暂无热榜内容" description="稍后再来看看吧" />
        <Button onPress={() => loadHot()}>
          <Label title="刷新" systemImage="arrow.clockwise" />
        </Button>
        <Spacer />
      </VStack>
    );
  }

  return (
    <RNHostView>
      <View style={{ flex: 1 }}>
        <SegmentFade segment={activeTab}>
          <LegendList
            data={threads}
            keyExtractor={hotThreadKeyExtractor}
            renderItem={renderHotItem}
            ListHeaderComponent={hotListHeader}
            ListFooterComponent={hotListFooter}
            contentContainerStyle={{ paddingBottom: 24 }}
            decelerationRate="normal"
            drawDistance={300}
            refreshControl={
              <RefreshControl
                refreshing={refreshing}
                onRefresh={handleRefresh}
                tintColor={colors.primary}
              />
            }
          />
        </SegmentFade>
      </View>
    </RNHostView>
  );
}

const styles = StyleSheet.create({
  hotSkeleton: { paddingHorizontal: 16, paddingTop: 8 },
  // 话题横向滚动
  topicSection: { paddingTop: 16, paddingBottom: 6 },
  topicSectionHeader: { flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 16, marginBottom: 12 },
  topicSectionTitle: { ...typographyStyles.title2 },
  topicScrollContent: { paddingHorizontal: 14, gap: 10 },
  topicChip: {
    flexDirection: 'row', alignItems: 'center', gap: 8,
    paddingHorizontal: 14, paddingVertical: 10, borderRadius: 22,
    borderWidth: 1,
  },
  topicRankBadge: {
    width: 20, height: 20, borderRadius: 10,
    alignItems: 'center', justifyContent: 'center',
  },
  topicRankNum: { fontSize: 11, fontWeight: '800', color: '#FFF' },
  topicChipText: { fontSize: 14, fontWeight: '600', maxWidth: 130, letterSpacing: 0 },
  // Tab 横向滚动
  tabScrollContent: { paddingHorizontal: 14, paddingTop: 14, paddingBottom: 8, gap: 8 },
  tabItem: { paddingHorizontal: 18, paddingVertical: 9, borderRadius: 20 },
  tabItemText: { fontSize: 14, fontWeight: '600', letterSpacing: 0 },
  rankTip: { paddingHorizontal: 16, paddingTop: 10, paddingBottom: 8, fontSize: 12, letterSpacing: 0 },
  // 热帖卡片：无阴影（0.03 软阴影肉眼不可辨，却让每行触发 CA 离屏计算）
  hotCard: {
    flexDirection: 'row', marginHorizontal: 10, marginVertical: 6,
    padding: 16, borderRadius: Radius.card,
  },
  hotRankBadge: {
    width: 38, alignItems: 'center', justifyContent: 'flex-start', paddingTop: 2, borderRadius: 10,
  },
  hotRankNum: { fontSize: 22, fontWeight: '800', letterSpacing: 0, fontVariant: ['tabular-nums'] },
  hotCardBody: { flex: 1, paddingLeft: 10 },
  hotTitle: { ...typographyStyles.headline, marginBottom: 8 },
  hotMetaRow: { flexDirection: 'row', alignItems: 'center', gap: 6, marginBottom: 8 },
  hotAuthorGroup: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  hotUserName: { fontSize: 13, fontWeight: '500', maxWidth: 80 },
  hotDot: { fontSize: 13 },
  hotForumChip: { paddingHorizontal: 8, paddingVertical: 3, borderRadius: 8 },
  hotForumText: { fontSize: 12, fontWeight: '500' },
  hotActions: { flexDirection: 'row', alignItems: 'center', gap: 5 },
  hotActionText: { fontSize: 13, marginRight: 12 },
  hotHotNumWrap: { flexDirection: 'row', alignItems: 'center', gap: 3 },
  hotHotNum: { fontSize: 13, fontWeight: '700', fontVariant: ['tabular-nums'] },
  hotFooter: { alignItems: 'center', paddingTop: 16, paddingHorizontal: Spacing.lg },
  hotFooterCard: {
    width: '100%',
    height: 130, // "到底卡"：内容滚到底时整卡压进底栏玻璃区，玻璃下有折射内容
    ...RadiusStyle.card,
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
  },
  hotFooterText: { fontSize: 13, letterSpacing: 0, fontWeight: '600' },
  hotFooterHint: { fontSize: 12 },
});
