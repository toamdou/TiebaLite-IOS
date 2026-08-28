// ============================================================
// TiebaLite React Native - PressScale
// 按压进入用 PRESS_ENTER 弹簧缩放（默认 0.97），释放回 1。
// 抽取自首页关注 / 通知列表两份逐字节相同的实现，统一共享。
// ============================================================

/* eslint-disable react-hooks/immutability -- Reanimated shared values are mutable refs; React Compiler cannot model them. */
import { useCallback, type ReactNode } from 'react';
import Animated, { useAnimatedStyle, useSharedValue, withSpring } from 'react-native-reanimated';

import { PRESS_ENTER } from '@/theme';
import { useReducedMotion } from '@/hooks/useReducedMotion';
import { useAppPreference } from '@/hooks/useAppPreference';
import { HdrPressable } from './HdrPressable';

interface PressScaleProps {
  onPress?: () => void;
  /** 按压态缩放比例（默认 0.97） */
  scaleTo?: number;
  /** HDR 效果：'hdr' 扫光+白闪+光晕（默认）；'subtle' 零视觉（普通按压，列表行用）。 */
  effect?: 'hdr' | 'subtle';
  children: ReactNode;
}

export function PressScale({ onPress, scaleTo = 0.97, effect, children }: PressScaleProps) {
  const { reduceMotion } = useReducedMotion();
  // 按压缩放效果开关（设置→个性化→动效）；系统减弱动态效果优先
  const pressScaleEnabled = useAppPreference('pressScaleEffect', true);
  const skipScale = reduceMotion || !pressScaleEnabled;
  const scale = useSharedValue(1);

  const pressIn = useCallback(() => {
    if (skipScale) return;
    scale.value = withSpring(scaleTo, PRESS_ENTER);
  }, [skipScale, scale, scaleTo]);

  const pressOut = useCallback(() => {
    if (skipScale) return;
    scale.value = withSpring(1, PRESS_ENTER);
  }, [skipScale, scale]);

  const animatedStyle = useAnimatedStyle(() => ({ transform: [{ scale: scale.value }] }));
  return (
    <Animated.View style={animatedStyle}>
      <HdrPressable onPress={onPress} onPressIn={pressIn} onPressOut={pressOut} effect={effect}>{children}</HdrPressable>
    </Animated.View>
  );
}