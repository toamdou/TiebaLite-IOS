/**
 * SegmentFade — 分段内容切换 crossfade（explore 动态页共用）
 *
 * segment 变化时透明度快速 0→1（淡入新内容）；reduceMotion 时直接显示、
 * 不做过渡。容器 flex:1 占满剩余空间，供 LegendList 等列表内容承载。
 */

import { useEffect } from 'react';
import { StyleSheet } from 'react-native';
import Animated, {
  useAnimatedStyle,
  useSharedValue,
  withTiming,
} from 'react-native-reanimated';
import { useReducedMotion } from '@/hooks/useReducedMotion';
import { DURATION, EASE_OUT } from '@/theme';

export function SegmentFade({ segment, children }: { segment: string; children: React.ReactNode }) {
  const { reduceMotion } = useReducedMotion();
  const opacity = useSharedValue(0);

  useEffect(() => {
    if (reduceMotion) {
      opacity.value = 1;
      return;
    }
    opacity.value = 0;
    opacity.value = withTiming(1, { duration: DURATION.enter, easing: EASE_OUT });
  }, [segment, reduceMotion, opacity]);

  const animatedStyle = useAnimatedStyle(() => ({ opacity: opacity.value }));
  return <Animated.View style={[styles.segmentFade, animatedStyle]}>{children}</Animated.View>;
}

const styles = StyleSheet.create({
  // 分段内容区：crossfade 动画容器需占满剩余空间
  segmentFade: { flex: 1 },
});