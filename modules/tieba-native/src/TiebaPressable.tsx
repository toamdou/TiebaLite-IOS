import { requireNativeViewManager } from 'expo-modules-core';
import type { ReactNode } from 'react';
import type { GestureResponderEvent, StyleProp, ViewStyle } from 'react-native';

const NativeTiebaPressableView = requireNativeViewManager(
  'TiebaNative',
  'TiebaPressableView',
);

export interface PressableScaleProps {
  /** 按下时内容缩放比例（默认 0.97，1.0 = 不缩放） */
  scalePressed?: number;
  /** 按压时覆盖层颜色（如 'rgba(255,255,255,0.18)'），缺省不显示覆盖层 */
  highlightColor?: string;
  /** 禁用按压：不缩放、不震动、不触发 onPress */
  disabled?: boolean;
  /** 容器样式（建议配合 borderRadius 使用） */
  style?: StyleProp<ViewStyle>;
  /**
   * 抬起（仍落在容器内）时触发。
   * 点击触发是调用方职责，此处不做防抖。
   */
  onPress?: (event: GestureResponderEvent) => void;
  /** 内容 */
  children?: ReactNode;
}

/**
 * 全站通用原生按压反馈容器：按下时原生动画缩放 + 可选高光覆盖层 + Light 震动，
 * 抬起恢复并触发 onPress。替代 RN 侧手写 `Pressable + withSpring + hapticImpact` 三段式。
 */
export function PressableScale({
  scalePressed = 0.97,
  highlightColor,
  disabled = false,
  style,
  onPress,
  children,
}: PressableScaleProps) {
  return (
    <NativeTiebaPressableView
      style={style}
      scalePressed={scalePressed}
      highlightColor={highlightColor}
      disabled={disabled}
      onPress={onPress}
    >
      {children}
    </NativeTiebaPressableView>
  );
}

export default PressableScale;
