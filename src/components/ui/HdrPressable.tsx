// ============================================================
// TiebaLite React Native - HdrPressable
// Pressable + 按压白闪反馈（SDR 合成）：按下瞬间按钮整体增亮（0.95 纯白）、
// 一层外扩光晕（默认超出边界 9pt）。任何可点击按钮把 <Pressable> 换成
// <HdrPressable> 即获得按压反馈；视觉层全部 pointerEvents="none"，不拦截
// 手势；props 与 Pressable 全兼容（React 19 ref 透传）。reduceMotion 时
// 只做静态白闪。
// 2026-08-28 用户反馈：白色斜向扫光带深浅色模式下都突兀，已全局删除。
//
// 2026-08-30 用户定案：**默认 subtle（全应用无高光扫过）**；仅保留名单
// 显式 effect="hdr"（左上角返回=原生 back、右上角吧头像、吧页 FAB、底栏
// 四 tab=原生 NativeTabs——均由系统/显式 hdr 承担）。
//
// effect="subtle"（默认）：无任何按压视觉变化，零开销直出（不创建
// shared value / worklet / 覆盖层视图）。
// ============================================================

/* eslint-disable react-hooks/immutability -- Reanimated shared values are mutable refs; React Compiler cannot model them. */
import { useCallback, type ReactNode } from 'react';
import { Pressable, StyleSheet, type PressableProps } from 'react-native';
import Animated, { useAnimatedStyle, useSharedValue, withTiming } from 'react-native-reanimated';

import { useReducedMotion } from '@/hooks/useReducedMotion';

export interface HdrPressableProps extends PressableProps {
  children?: ReactNode;
  /** 白闪圆角（与按钮自身圆角对齐，默认 10） */
  flashRadius?: number;
  /** 外扩光晕超出按钮边界的距离（pt），默认 9 */
  glowOutset?: number;
  /** 反馈效果：'subtle'=无按压视觉（**默认**，全应用）；'hdr'=白闪+光晕
      （仅保留名单：吧头像预览、吧页 FAB 等显式声明） */
  effect?: 'hdr' | 'subtle';
}

export function HdrPressable(props: HdrPressableProps) {
  // 默认 subtle：全应用无高光扫过（用户 2026-08-30 定案）；subtle 路径零开销
  // 直出：不创建 shared value / worklet / 覆盖层视图。LegendList 默认不回收行
  //（recycleItems 关），飞速滑动时每行都是新挂载，卡片行省掉的是纯常驻成本。
  if (props.effect !== 'hdr') {
    const { effect: _effect, flashRadius: _flashRadius, glowOutset: _glowOutset, ...rest } = props;
    return <Pressable {...rest} />;
  }
  return <HdrEffectPressable {...props} />;
}

/** 'hdr' 效果实现：白闪 + 光晕（hooks 全部收敛在此组件内）。 */
function HdrEffectPressable({
  children,
  flashRadius = 10,
  glowOutset = 9,
  onPressIn,
  style,
  ...rest
}: HdrPressableProps) {
  const { reduceMotion } = useReducedMotion();
  const flashOpacity = useSharedValue(0);
  const haloOpacity = useSharedValue(0);

  const flashStyle = useAnimatedStyle(() => ({ opacity: flashOpacity.value }));
  const haloStyle = useAnimatedStyle(() => ({ opacity: haloOpacity.value }));

  const handlePressIn = useCallback(
    (event: Parameters<NonNullable<PressableProps['onPressIn']>>[0]) => {
      // 峰值瞬间置位（按压瞬间即亮，不缓起），再按各自时长淡出：
      // 白闪 0.95；光晕 0.72、最晚收。
      if (reduceMotion) {
        // 降级路径：跳过光晕，只做静态白闪 + 与常态一致的 520ms 淡出收尾
        // （否则白闪置位后永不复位，按压痕迹残留）。
        flashOpacity.value = 0.95;
        flashOpacity.value = withTiming(0, { duration: 520 });
      } else {
        flashOpacity.value = 0.95;
        haloOpacity.value = 0.72;
        flashOpacity.value = withTiming(0, { duration: 520 });
        haloOpacity.value = withTiming(0, { duration: 680 });
      }
      onPressIn?.(event);
    },
    [reduceMotion, flashOpacity, haloOpacity, onPressIn],
  );

  return (
    <Pressable {...rest} style={style} onPressIn={handlePressIn}>
      {children}
      {/* 外扩光晕：超出按钮边界 glowOutset，先亮后淡 */}
      <Animated.View
        pointerEvents="none"
        style={[
          styles.halo,
          {
            top: -glowOutset,
            left: -glowOutset,
            right: -glowOutset,
            bottom: -glowOutset,
            borderRadius: flashRadius + glowOutset,
            borderCurve: 'continuous',
          },
          haloStyle,
        ]}
      />
      {/* 整体增亮：纯白闪，圆角对齐按钮 */}
      <Animated.View
        pointerEvents="none"
        style={[
          StyleSheet.absoluteFill,
          { borderRadius: flashRadius, borderCurve: 'continuous', backgroundColor: '#FFFFFF' },
          flashStyle,
        ]}
      />
    </Pressable>
  );
}

const styles = StyleSheet.create({
  halo: {
    position: 'absolute',
    backgroundColor: '#FFFFFF',
  },
});