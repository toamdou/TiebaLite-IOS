import type { StyleProp, ViewStyle } from 'react-native';
import { hapticForScene } from '@/theme/hapticsMap';
import { requireNativeViewManager } from 'expo-modules-core';

const NativeSegmentedControl = requireNativeViewManager(
  'TiebaNative',
  'TiebaSegmentedControlView',
);

export interface TiebaSegmentItem {
  label: string;
  value: string;
}

/**
 * 原生分段控件（UIKit UISegmentedControl，iOS 26 液态视觉，ExpoUI segmented
 * Picker 同源系统组件）。
 *
 * 为什么存在：吧页 segment 必须在 LegendList 列表头内（跟手滚动）；该位置
 * 嵌套 SwiftUI Host（@expo/ui Picker）触摸断链——8-25 真机反复复现
 * （minHeight/宽度修复后仍点不到）。UIKit 控件在 RN 视图树内由 UIKit
 * hit-test 直接命中，任意深度可点（HdrPressable/GlassView 同原理）。
 */
export function TiebaSegmentedControl({
  segments,
  selectedIndex,
  onSelect,
  style,
}: {
  segments: TiebaSegmentItem[];
  selectedIndex: number;
  onSelect: (value: string) => void;
  style?: StyleProp<ViewStyle>;
}) {
  return (
    <NativeSegmentedControl
      titles={segments.map((s) => s.label)}
      selectedIndex={selectedIndex}
      style={[{ height: 44 }, style]}
      onValueChange={(e: { nativeEvent: { index: number } }) => {
        const item = segments[e.nativeEvent.index];
        if (item) {
          hapticForScene('segment');
          onSelect(item.value);
        }
      }}
    />
  );
}