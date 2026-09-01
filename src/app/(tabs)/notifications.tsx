/**
 * Notifications Tab (消息) — SwiftUI 原生实现
 *
 * 界面渲染：
 * - 顶部：Picker segmented（回复我的 | 提到我的 | 赞我的）
 * - 中部：三页横滑（SegmentPager）——每 tab 独立消息列表与滚动位置；
 *         一级 tab 页：最左向右滑只回弹，不退出
 * - 列表与消息行：MessageTabList / MessageRow（拆分子组件）
 * - 未读：Circle 蓝色圆点；空态/加载态按 tab 各自呈现
 */

import { useCallback, useEffect, useState } from 'react';
import {
  VStack, Button, Text, Label,
  ProgressView, ContentUnavailableView, Spacer,
} from '@expo/ui/swift-ui';
import {
  foregroundStyle,
  buttonStyle, buttonBorderShape,
} from '@expo/ui/swift-ui/modifiers';
import {
  View, DeviceEventEmitter,
} from 'react-native';
import { StyleSheet } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { hapticForScene } from '@/theme/hapticsMap';
import { useThemeColors } from '@/theme/ThemeContext';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { SegmentPager } from '@/components/ui/SegmentPager';
import { TiebaSegmentedControl } from '@/components/ui/TiebaSegmentedControl';
import { BottomFade } from '@/components/feed/BottomFade';
import { MessageTabList } from '@/components/notifications/MessageTabList';
import { useAuthStore } from '@/stores/authStore';
import { useNotificationStore } from '@/stores/notificationStore';
import { resetNotificationBaseline } from '@/services/NotificationPoller';
import type { MessageTab } from '@/components/notifications/MessageRow';
import { TAB_RESELECT_EVENT } from '@/constants/events';

// ── 分段选项 ──
// 与 notificationStore 的 activeTab 类型保持一致（store 支持 'agree' 赞消息）

const SEGMENTS: { label: string; value: MessageTab }[] = [
  { label: '回复我的', value: 'reply' },
  { label: '提到我的', value: 'at' },
  { label: '赞我的', value: 'agree' },
];

const TAB_INDEX: Record<MessageTab, number> = { reply: 0, at: 1, agree: 2 };

// 底部渐罩为公共组件（@/components/feed/BottomFade，index/explore 共用），
// 本地副本已收敛。

// ── 主页面 ──
export default function NotificationsScreen() {
  const { colors } = useThemeColors();
  const isLoggedIn = useAuthStore((s) => s.isLoggedIn);
  const isLoading = useAuthStore((s) => s.isLoading);
  const router = useRouter();
  const insets = useSafeAreaInsets();

  const activeTab = useNotificationStore((s) => s.activeTab);
  const loadNotificationCounts = useNotificationStore((s) => s.loadNotificationCounts);
  const setActiveTab = useNotificationStore((s) => s.setActiveTab);
  const { initialTab } = useLocalSearchParams<{ initialTab?: string }>();

  // tab 重按刷新信号：每次 +1，只有当前激活页消费
  const [refreshSignal, setRefreshSignal] = useState(0);

  // 深链接跳转
  useEffect(() => {
    if (initialTab !== undefined) {
      const TAB_MAP: Record<number, MessageTab> = { 0: 'reply', 1: 'at', 2: 'agree' };
      const tab = TAB_MAP[parseInt(initialTab, 10)];
      if (tab) setActiveTab(tab);
    }
  }, [initialTab, setActiveTab]);

  // 聚焦时刷新计数（仅登录时）。loadNotificationCounts 失败返回 null，
  // 此时不重置通知基线：服务端偶发失败不应把基线清零（否则下次增长会
  // 把整段旧增量重播成重复提醒）。
  useFocusEffect(
    useCallback(() => {
      if (!isLoggedIn) return;
      (async () => {
        const counts = await loadNotificationCounts();
        if (counts === null) return;
        try {
          await resetNotificationBaseline();
        } catch {}
      })();
    }, [loadNotificationCounts, isLoggedIn]),
  );

  useEffect(() => {
    const sub = DeviceEventEmitter.addListener(TAB_RESELECT_EVENT, (tabName: string) => {
      if (tabName === 'notifications' && isLoggedIn) {
        setRefreshSignal((s) => s + 1);
        loadNotificationCounts().catch(() => {});
      }
    });
    return () => sub.remove();
  }, [isLoggedIn, loadNotificationCounts]);

  const handleTabChange = useCallback((value: string) => {
    hapticForScene('toggle');
    setActiveTab(value as MessageTab);
  }, [setActiveTab]);

  // pager 滑动同步 segment（一级 tab 页：最左向右滑只回弹，不退出）
  const handlePagerChange = useCallback(
    (index: number) => {
      const seg = SEGMENTS[index]?.value;
      if (seg && seg !== activeTab) {
        hapticForScene('toggle');
        setActiveTab(seg);
      }
    },
    [activeTab, setActiveTab],
  );

  // ── 未登录 ──
  if (isLoading) {
    return (
      <View style={{ flex: 1, paddingTop: insets.top }}>
        <ThemedHost style={{ flex: 1 }}>
          <VStack alignment="center" spacing={12}>
            <Spacer />
            <ProgressView />
            <Text modifiers={[foregroundStyle({ type: 'hierarchical', style: 'secondary' })]}>加载中...</Text>
            <Spacer />
          </VStack>
        </ThemedHost>
      </View>
    );
  }

  if (!isLoggedIn) {
    return (
      <View style={{ flex: 1, paddingTop: insets.top, paddingBottom: insets.bottom + 80 }}>
        <ThemedHost style={{ flex: 1 }}>
          <VStack alignment="center" spacing={16}>
            <Spacer />
            <ContentUnavailableView
              systemImage="bell.slash"
              title="请先登录"
              description="登录后查看消息通知"
            />
            <Button
              onPress={() => router.push('/login')}
              modifiers={[buttonStyle('glassProminent'), buttonBorderShape('capsule')]}
            >
              <Label title="登录百度账号" systemImage="person.crop.circle.badge.checkmark" />
            </Button>
            <Spacer />
          </VStack>
        </ThemedHost>
        {/* 未登录分支同样铺底栏渐罩：空态下玻璃背后也不露纯平背景色 */}
        <BottomFade />
      </View>
    );
  }

  // ── 已登录 ──
  // 2026-08-31 重构：分段器/分页整体纯 RN 化——原 SwiftUI Picker + VStack
  // 嵌套下，内层 RN 的 SegmentPager 拿不到高度（用户实测消息页整块空白，
  // 连调试条都不可见）；TiebaSegmentedControl 与吧页同款原生分段。
  // paddingBottom 与未登录分支对齐（insets.bottom + 80 = 底栏高度+安全区）：
  // 此前缺失时 pager 区域直通屏底、区域中心偏下 40~60pt（2026-09-01 用户
  // "空态没居中"的几何根因之一；另一根因见 MessageTabList 空态容器注释）。
  return (
    <View style={{ flex: 1, paddingTop: insets.top, paddingBottom: insets.bottom + 80 }}>
      <View style={styles.segRow}>
        <TiebaSegmentedControl
          segments={SEGMENTS.map((s) => ({ label: s.label, value: s.value }))}
          selectedIndex={TAB_INDEX[activeTab]}
          onSelect={handleTabChange}
        />
      </View>

      {/* 三页横滑（回复/提到/赞），每 tab 独立列表与滚动位置 */}
      <SegmentPager pageIndex={TAB_INDEX[activeTab]} onPageIndexChange={handlePagerChange} canExit={false}>
        {SEGMENTS.map((s) => (
          <View key={s.value} style={{ flex: 1 }}>
            <MessageTabList
              tab={s.value}
              isLoggedIn={isLoggedIn}
              colors={colors}
              active={s.value === activeTab}
              refreshSignal={refreshSignal}
            />
          </View>
        ))}
      </SegmentPager>

      {/* 底部渐罩：叠在列表之上、贴容器底 80pt；glass 底栏背后不再是纯平实色 */}
      <BottomFade />
    </View>
  );
}

const styles = StyleSheet.create({
  segRow: {
    paddingHorizontal: 16,
    paddingTop: 8,
    paddingBottom: 4,
  },
});
