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
  Picker, ProgressView, ContentUnavailableView, Spacer,
} from '@expo/ui/swift-ui';
import {
  pickerStyle, tag, foregroundStyle, padding,
  buttonStyle, buttonBorderShape,
} from '@expo/ui/swift-ui/modifiers';
import {
  View, DeviceEventEmitter,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useFocusEffect, useLocalSearchParams, useRouter } from 'expo-router';
import { hapticForScene } from '@/theme/hapticsMap';
import { useThemeColors } from '@/theme/ThemeContext';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { SegmentPager } from '@/components/ui/SegmentPager';
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
  return (
    <View style={{ flex: 1, paddingTop: insets.top }}>
      <ThemedHost style={{ flex: 1 }} ignoreSafeArea="container">
        <VStack spacing={0}>
          {/* 分段选择器：selection 是 string 标签，onSelectionChange 用正式签名 */}
          <Picker<string>
            selection={activeTab}
            onSelectionChange={handleTabChange}
            modifiers={[pickerStyle('segmented'), padding({ horizontal: 16, top: 8, bottom: 4 })]}
          >
            {SEGMENTS.map((s) => (
              <Text key={s.value} modifiers={[tag(s.value)]}>{s.label}</Text>
            ))}
          </Picker>

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
        </VStack>
      </ThemedHost>

      {/* 底部渐罩：叠在列表之上、贴容器底 80pt；glass 底栏背后不再是纯平实色 */}
      <BottomFade />
    </View>
  );
}