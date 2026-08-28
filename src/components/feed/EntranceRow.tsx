/**
 * EntranceRow — 首屏批次入场（index 关注吧列表 / explore 信息流与热榜共用）
 *
 * opacity 0→1 + translateY 12→0，逐行 withDelay(DURATION.stagger) 级联。
 * 仅首次数据到达批次执行一次（ran ref 防重播，刷新/分页/回收复用不重复）；
 * reduceMotion 时直接静态显示。
 *
 * 注意：stagger 钳制语义（min(index, ENTRANCE_STAGGER_LIMIT - 1)）为冻结行为，
 * 不随本次抽取调整（见全量审查备注：钳制语义明确不做）。
 */

import { memo, useEffect, useRef } from 'react';
import Animated, {
  useAnimatedStyle,
  useSharedValue,
  withDelay,
  withTiming,
} from 'react-native-reanimated';
import { DURATION, EASE_OUT } from '@/theme';
import { useReducedMotion } from '@/hooks/useReducedMotion';
import { useAppPreference } from '@/hooks/useAppPreference';

/** 首屏入场级联延迟上限：避免长列表把入场拖得太久 */
const ENTRANCE_STAGGER_LIMIT = 10;

export const EntranceRow = memo(function EntranceRow({
  index,
  animateEntry,
  children,
}: {
  index: number;
  animateEntry: boolean;
  children: React.ReactNode;
}) {
  const { reduceMotion } = useReducedMotion();
  // 入场动画开关（设置→个性化→动效）：关闭或系统减弱动态效果时静态显示
  const entranceAnimation = useAppPreference('entranceAnimation', true);
  // 是否走动画壳在首挂载时一次性定格（sticky）：LegendList 默认不回收
  // 行组件（recycleItems 关），飞速滑动时每行都是新挂载，首屏入场结束后
  // 的行（animateEntry=false）直接透传 children，不再为每一行创建
  // Animated.View + shared value + worklet。已挂载的行不因 animateEntry
  // 翻转切换分支（会重挂 children），故用 ref 冻结决策；入场壳内部仍有
  // ran 防重播。
  const staticRef = useRef(!animateEntry || reduceMotion || !entranceAnimation);
  if (staticRef.current) return <>{children}</>;
  return <EntranceAnimated index={index}>{children}</EntranceAnimated>;
});

const EntranceAnimated = memo(function EntranceAnimated({
  index,
  children,
}: {
  index: number;
  children: React.ReactNode;
}) {
  const { reduceMotion } = useReducedMotion();
  const entranceAnimation = useAppPreference('entranceAnimation', true);
  const opacity = useSharedValue(0);
  const translateY = useSharedValue(12);
  const ran = useRef(false);

  useEffect(() => {
    if (ran.current) return;
    ran.current = true;
    if (reduceMotion || !entranceAnimation) {
      opacity.value = 1;
      translateY.value = 0;
      return;
    }
    const delay = Math.min(index, ENTRANCE_STAGGER_LIMIT - 1) * DURATION.stagger;
    opacity.value = withDelay(delay, withTiming(1, { duration: DURATION.enter, easing: EASE_OUT }));
    translateY.value = withDelay(delay, withTiming(0, { duration: DURATION.enter, easing: EASE_OUT }));
  }, [reduceMotion, entranceAnimation, index, opacity, translateY]);

  const animatedStyle = useAnimatedStyle(() => ({
    opacity: opacity.value,
    transform: [{ translateY: translateY.value }],
  }));

  return <Animated.View style={animatedStyle}>{children}</Animated.View>;
});