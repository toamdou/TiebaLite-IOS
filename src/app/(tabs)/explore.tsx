/**
 * Explore Tab (发现) — 分段壳
 *
 * 界面渲染：
 * - 顶部：Picker segmented（推荐 | 关注 | 热榜）
 * - 三板块 SegmentPager 横滑；推荐/关注 → FeedContent，热榜 → HotListContent
 *   （均拆至 @/components/explore/，本文件只承载原生分段与宿主结构）
 */

import { useCallback, useState } from 'react';
import { View } from 'react-native';
import {
  VStack, Text,
  RNHostView, Picker,
} from '@expo/ui/swift-ui';
import { padding, pickerStyle, tag, frame } from '@expo/ui/swift-ui/modifiers';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { hapticForScene } from '@/theme/hapticsMap';
import { Spacing } from '@/theme';
import { SegmentPager } from '@/components/ui/SegmentPager';
import { FeedContent, type ExploreSegment } from '@/components/explore/FeedContent';
import { HotListContent } from '@/components/explore/HotListContent';
import { BottomFade } from '@/components/feed/BottomFade';
import { ThemedHost } from '@/components/ui/ThemedHost';

const SEGMENTS: { label: string; value: ExploreSegment }[] = [
  { label: '推荐', value: 'personalized' },
  { label: '关注', value: 'concern' },
  { label: '热榜', value: 'hot' },
];

// ── 主页面 ──
export default function ExploreScreen() {
  const insets = useSafeAreaInsets();
  const [activeSegment, setActiveSegment] = useState<ExploreSegment>('personalized');
  const activeIndex = Math.max(0, SEGMENTS.findIndex((s) => s.value === activeSegment));

  const handleSegmentChange = useCallback((value: string) => {
    hapticForScene('toggle');
    setActiveSegment(value as ExploreSegment);
  }, []);

  // pager 滑动同步 segment（一级 tab 页：最左向右滑只回弹，不退出）
  const handlePagerChange = useCallback(
    (index: number) => {
      const seg = SEGMENTS[index]?.value;
      if (seg && seg !== activeSegment) {
        hapticForScene('toggle');
        setActiveSegment(seg);
      }
    },
    [activeSegment],
  );

  return (
    // ignoreSafeArea='container'：内容延伸到 tab bar 底下，让液态玻璃有内容可模糊
    <ThemedHost style={{ flex: 1 }} ignoreSafeArea="container">
      {/* 外层用 SwiftUI VStack 承载：分段控件必须是 Host 的直接后代才能
          全宽渲染（matchContents/定高容器会空白或收缩到理想宽）。
          列表仍走 RNHostView。 */}
      <VStack spacing={0} modifiers={[frame({ maxWidth: 10000, maxHeight: 10000 })]}>
        {/* 原生 SwiftUI 分段控制（iOS 26 液态玻璃）：ignoreSafeArea 已把顶部
            安全区划掉，这里显式补回 insets.top 让分段控件落在状态栏下方 */}
        <Picker
          selection={activeSegment}
          onSelectionChange={handleSegmentChange}
          modifiers={[pickerStyle('segmented'), padding({ horizontal: Spacing.lg, top: insets.top + 8, bottom: 8 })]}
        >
          {SEGMENTS.map((s) => (
            <Text key={s.value} modifiers={[tag(s.value)]}>{s.label}</Text>
          ))}
        </Picker>

        <RNHostView>
          <View style={{ flex: 1 }}>
            {/* 三板块横滑切换（推荐/关注/热榜）：每页独立 Feed 实例与滚动位置；
                最左页向右滑只回弹不退出（一级 tab，无返回语义） */}
            <SegmentPager pageIndex={activeIndex} onPageIndexChange={handlePagerChange} canExit={false}>
              <ThemedHost style={{ flex: 1 }} ignoreSafeArea="container">
                <FeedContent segment="personalized" active={activeSegment === 'personalized'} />
              </ThemedHost>
              <ThemedHost style={{ flex: 1 }} ignoreSafeArea="container">
                <FeedContent segment="concern" active={activeSegment === 'concern'} />
              </ThemedHost>
              <ThemedHost style={{ flex: 1 }} ignoreSafeArea="container">
                <HotListContent active={activeSegment === 'hot'} />
              </ThemedHost>
            </SegmentPager>

            {/* 底部渐罩：叠在列表之上、贴容器底 110pt；glass 底栏背后不再是纯平实色。
                公共组件（@/components/feed/BottomFade），index / explore 共用。 */}
            <BottomFade />
          </View>
        </RNHostView>
      </VStack>
    </ThemedHost>
  );
}
