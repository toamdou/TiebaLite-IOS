/* eslint-disable react-hooks/immutability -- Reanimated shared values are mutable refs; React Compiler cannot model them. */
// ============================================================
// TiebaLite React Native - Shared Skeleton (骨架屏)
// 全 App 共享的加载占位：形状 1:1 模拟真实卡片，呼吸动画
// 尊重 "Reduce Motion"（静态占位，不做脉冲）
// ============================================================

import React, { useEffect, useMemo } from 'react';
import { StyleSheet, View } from 'react-native';
import Animated, {
  cancelAnimation,
  useAnimatedStyle,
  useSharedValue,
  withRepeat,
  withTiming,
} from 'react-native-reanimated';

import { useReducedMotion } from '@/hooks/useReducedMotion';
import { useThemeColors } from '@/theme/ThemeContext';
import {Spacing, RadiusStyle, Radius} from '@/theme';

// ---------- 类型 ----------

export type SkeletonVariant = 'thread' | 'post' | 'card' | 'row';

export interface SkeletonCellProps {
  /** 骨架形状：thread=标题+摘要+左缩略图；post=头像+昵称+正文；card=大图+标题+两行；row=头像+两行文本 */
  variant?: SkeletonVariant;
  /** 自定义样式 */
  style?: any;
  /** 呼吸动画样式（由 SkeletonList 下发同一驱动，全列表同相位；必填） */
  pulse: any;
}

export interface SkeletonListProps {
  /** 骨架单元数量（默认 8） */
  count?: number;
  variant?: SkeletonVariant;
  /** 自定义单个单元高度；缺省按 variant 对齐真实行高（thread=帖卡 128 / post=回复 136 / card=大图 232 / row=列表行 88） */
  itemHeight?: number;
  /** 列表容器自定义样式 */
  style?: any;
}

// ---------- 呼吸动画 ----------
// opacity 0.45 → 0.9 → 0.45，每段 500ms，无限循环（withRepeat reverse 对称
// 呼吸，无首段空转）；Reduce Motion 时静态 0.9
function useBreathing(reduceMotion: boolean) {
  const opacity = useSharedValue(0.45);
  const pulseStyle = useAnimatedStyle(() => ({ opacity: opacity.value }));

  useEffect(() => {
    if (reduceMotion) {
      // Reduce Motion：静态占位，不做脉冲
      cancelAnimation(opacity);
      opacity.value = 0.9;
      return;
    }
    opacity.value = withRepeat(
      withTiming(0.9, { duration: 500 }),
      -1,
      true, // reverse：0.45→0.9→0.45 对称呼吸，去掉旧版 withSequence 首段 500ms 空转
    );
    return () => cancelAnimation(opacity);
  }, [reduceMotion, opacity]);

  return pulseStyle;
}

// ---------- 单个骨架单元 ----------

export function SkeletonCell({ variant = 'row', style, pulse }: SkeletonCellProps) {
  const { colors } = useThemeColors();

  // 占位色：theme.surfaceTertiary。不能用 surfaceSecondary——亮色主题下它与
  // background 同为 #F2F2F7，骨架块贴在页面背景上完全隐形（8-25 真机四路
  // 骨架屏"消失"根因）；surfaceTertiary 在各调色板均与 background 有对比。
  const bg = colors.surfaceTertiary;
  const bar = useMemo(
    () => ({ backgroundColor: bg, borderRadius: Radius.chip }),
    [bg],
  );

  let content: React.ReactNode;
  switch (variant) {
    case 'thread':
      // 标题条 + 摘要两行 + 左侧缩略图块
      content = (
        <View style={styles.threadRow}>
          <View style={[styles.threadThumb, { backgroundColor: bg }]} />
          <View style={styles.threadColumn}>
            <View style={[styles.titleBar, bar]} />
            <View style={[styles.lineBar, { width: '92%' }, bar]} />
            <View style={[styles.lineBar, { width: '64%' }, bar]} />
          </View>
        </View>
      );
      break;
    case 'post':
      // 头像圆 + 昵称条 + 正文两行 + 操作条（对齐 PostCard 回复行）
      content = (
        <View>
          <View style={styles.postHeader}>
            <View style={[styles.avatar, { backgroundColor: bg }]} />
            <View style={[styles.nickBar, bar]} />
          </View>
          <View style={[styles.bodyBar, bar]} />
          <View style={[styles.bodyBar, { width: '72%' }, bar]} />
          <View style={[styles.actionBar, bar]} />
        </View>
      );
      break;
    case 'card':
      // 大图块 + 标题 + 两行
      content = (
        <View>
          <View style={[styles.cardMedia, { backgroundColor: bg }]} />
          <View style={[styles.titleBar, { marginTop: Spacing.sm }, bar]} />
          <View style={[styles.lineBar, bar]} />
          <View style={[styles.lineBar, { width: '56%' }, bar]} />
        </View>
      );
      break;
    case 'row':
    default:
      // 头像圆 + 两行文本
      content = (
        <View style={styles.rowRow}>
          <View style={[styles.avatarSmall, { backgroundColor: bg }]} />
          <View style={styles.rowColumn}>
            <View style={[styles.rowBar1, bar]} />
            <View style={[styles.rowBar2, bar]} />
          </View>
        </View>
      );
      break;
  }

  return (
    <Animated.View style={[styles.cell, pulse, style]} accessible={false}>
      {content}
    </Animated.View>
  );
}

// ---------- 骨架列表 ----------

// 缺省行高 = 各界面真实行高（骨架替换列表时块高度一致，切换不跳）
const DEFAULT_ITEM_HEIGHT: Record<SkeletonVariant, number> = {
  thread: 128, // 信息流帖子卡（TweetCard 无图行高）
  post: 136, // 帖内回复行（PostCard）
  card: 232, // 大图页
  row: 88, // 通用列表行（历史/通知/成员/吧行）
};

export function SkeletonList({
  count = 8,
  variant = 'thread',
  itemHeight,
  style,
}: SkeletonListProps) {
  const { reduceMotion } = useReducedMotion();
  // 列表级共享呼吸：一次驱动，全列表同相位
  const pulse = useBreathing(reduceMotion);
  const height = itemHeight ?? DEFAULT_ITEM_HEIGHT[variant];

  return (
    <View
      style={[styles.list, style]}
      accessibilityRole="progressbar"
      accessibilityLabel="内容加载中"
    >
      {Array.from({ length: count }, (_, index) => (
        <View key={index} style={[styles.item, { height }]}>
          <SkeletonCell variant={variant} pulse={pulse} />
        </View>
      ))}
    </View>
  );
}

// ---------- 样式 ----------

const styles = StyleSheet.create({
  list: {
    width: '100%',
    gap: Spacing.md,
  },
  item: {
    width: '100%',
    justifyContent: 'center',
  },
  cell: {
    width: '100%',
  },
  // thread
  threadRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: Spacing.md,
  },
  threadThumb: {
    width: 72,
    height: 72,
    ...RadiusStyle.card,
  },
  threadColumn: {
    flex: 1,
    gap: Spacing.xs,
    paddingTop: 2,
  },
  // 公共条
  titleBar: {
    height: 16,
    ...RadiusStyle.chip,
    width: '100%',
  },
  lineBar: {
    height: 12,
    ...RadiusStyle.chip,
    width: '100%',
    marginTop: Spacing.xs,
  },
  // post
  postHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.sm,
  },
  actionBar: {
    height: 10,
    width: '42%',
    ...RadiusStyle.chip,
    marginTop: Spacing.sm,
  },
  avatar: {
    width: 40,
    height: 40,
    borderRadius: 20,
    borderCurve: 'continuous',
  },
  nickBar: {
    height: 12,
    ...RadiusStyle.chip,
    width: 120,
  },
  bodyBar: {
    height: 14,
    ...RadiusStyle.chip,
    width: '100%',
    marginTop: Spacing.md,
  },
  // card
  cardMedia: {
    width: '100%',
    height: 160,
    ...RadiusStyle.cardLarge,
  },
  // row
  rowRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.sm,
  },
  avatarSmall: {
    width: 36,
    height: 36,
    borderRadius: 18,
    borderCurve: 'continuous',
  },
  rowColumn: {
    flex: 1,
    gap: Spacing.xs,
  },
  rowBar1: {
    height: 12,
    ...RadiusStyle.chip,
    width: '52%',
  },
  rowBar2: {
    height: 10,
    ...RadiusStyle.chip,
    width: '78%',
  },
});

export default SkeletonList;
