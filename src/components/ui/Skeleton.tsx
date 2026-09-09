/* eslint-disable react-hooks/immutability -- Reanimated shared values are mutable refs; React Compiler cannot model them. */
// ============================================================
// TiebaLite React Native - Shared Skeleton (骨架屏)
// 「同形」原则（借鉴 panelui-native Skeleton 文档）：骨架必须 1:1 模拟
// 即将出现的真实内容——尺寸不对的骨架比没有更糟，因为真数据落地时
// 页面会跳。thread/post 两个 variant 逐项镜像 TweetCard / PostCard 的
// 真实几何（卡片容器/外边距/头像/缩进/媒体块/操作栏），行高由内容
// 自然撑出而非写死；呼吸动画尊重 Reduce Motion（静态占位）。
// ============================================================

import React, { useEffect, useMemo } from 'react';
import { StyleSheet, View, useWindowDimensions } from 'react-native';
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

// 呼吸块：pulse 是 Reanimated 动画样式，必须挂在 Animated 组件上
const Block = Animated.createAnimatedComponent(View);

// ---------- 类型 ----------

export type SkeletonVariant = 'thread' | 'post' | 'card' | 'row';

export interface SkeletonCellProps {
  /** 骨架形状：thread=TweetCard 卡片（含图片占位）；post=PostCard 楼层卡；card=大图+标题+两行；row=头像+两行文本 */
  variant?: SkeletonVariant;
  /** 自定义样式 */
  style?: any;
  /** 呼吸动画样式（由 SkeletonList 下发同一驱动，全列表同相位；必填） */
  pulse: any;
  /** thread 变体：本格是否带图片占位块（真实信息流图文混排，骨架按半数带图交替） */
  withMedia?: boolean;
}

export interface SkeletonListProps {
  /** 骨架单元数量（默认 8） */
  count?: number;
  variant?: SkeletonVariant;
  /** 自定义单个单元高度；仅 row/card 需要（thread/post 由内容自然撑高，与真实卡片同构）。缺省按 variant 对齐真实行高（card=大图 232 / row=列表行 88） */
  itemHeight?: number;
  /** 列表容器自定义样式 */
  style?: any;
}

// ---------- TweetCard 真实几何（与其文件头常量单一来源同步） ----------

/** 卡片外边距 styles.cardWrap.marginHorizontal */
const T_WRAP = 10;
/** 卡片内水平 padding styles.card.paddingHorizontal */
const T_PAD = 12;
/** 内容列缩进 CONTENT_INDENT（头像 44 + gap 10） */
const T_INDENT = 54;
const T_AVATAR = 44;
/** 媒体块圆角 = MediaPager 图片圆角（Radius.card - 4） */
const MEDIA_RADIUS = Radius.card - 4;

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

export function SkeletonCell({ variant = 'row', style, pulse, withMedia = false }: SkeletonCellProps) {
  const { colors } = useThemeColors();
  const { width: screenWidth } = useWindowDimensions();

  // 占位色：theme.surfaceTertiary。不能用 surfaceSecondary——亮色主题下它与
  // background 同为 #F2F2F7，骨架块贴在页面背景上完全隐形（8-25 真机四路
  // 骨架屏"消失"根因）；surfaceTertiary 在各调色板均与 background 有对比。
  const bg = colors.surfaceTertiary;
  const bar = useMemo(
    () => ({ backgroundColor: bg, borderRadius: Radius.chip }),
    [bg],
  );

  // thread 媒体块：真实单图按内容列宽的 4:3 钳制呈现，骨架取同宽 4:3
  //（宽 = 屏宽 - 卡片外边距 20 - 卡片内 padding 24 - 内容列缩进 54）
  const threadMediaWidth = Math.max(0, screenWidth - T_WRAP * 2 - T_PAD * 2 - T_INDENT);
  const threadMediaHeight = Math.round(threadMediaWidth * 0.75);

  let content: React.ReactNode;
  switch (variant) {
    case 'thread':
      // TweetCard 同形（src/components/feed/TweetCard.tsx）：
      // 卡片容器（Radius.card + hairline 描边 + padding 12/12/8，外边距 10/4）
      // → 头像行（44 圆 + 名字/时间条）→ 缩进 54 的内容列（标题/摘要/媒体/
      // 操作栏），行高由内容自然撑出，真卡片落地时零位移。
      content = (
        <View
          style={[
            styles.tWrap,
            { backgroundColor: colors.card, borderColor: colors.borderCard },
          ]}
        >
          <View style={styles.tHeader}>
            <Block style={[styles.tAvatar, { backgroundColor: bg }, pulse]} />
            <Block style={[styles.tNameBar, bar, pulse]} />
            <Block style={[styles.tTimeBar, bar, pulse]} />
          </View>
          <View style={styles.tContent}>
            <Block style={[styles.tTitle, { width: '88%' }, bar, pulse]} />
            <Block style={[styles.tLine, { width: '100%' }, bar, pulse]} />
            <Block style={[styles.tLine, { width: '72%' }, bar, pulse]} />
            {withMedia ? (
              <Block
                style={[styles.tMedia, { height: threadMediaHeight, backgroundColor: bg }, pulse]}
              />
            ) : null}
            <View style={styles.tActions}>
              {[0, 1, 2].map((i) => (
                <View key={i} style={styles.tActionGroup}>
                  <Block style={[styles.tActionIcon, { backgroundColor: bg }, pulse]} />
                  <Block style={[styles.tActionText, { backgroundColor: bg }, pulse]} />
                </View>
              ))}
            </View>
          </View>
        </View>
      );
      break;
    case 'post':
      // PostCard 楼层卡同形：卡片容器（Radius.card + padding 16，外边距 10/4）
      // → 头像行（36 圆 + 昵称条）→ 正文三行 → 操作条。帖页首屏主楼有快照
      //（KnownPostHeader）承接，楼层骨架不带媒体块。
      content = (
        <View
          style={[
            styles.pWrap,
            { backgroundColor: colors.card, borderColor: colors.borderCard },
          ]}
        >
          <View style={styles.pHeader}>
            <Block style={[styles.pAvatar, { backgroundColor: bg }, pulse]} />
            <Block style={[styles.pNickBar, bar, pulse]} />
          </View>
          <View style={styles.pBodyCol}>
            <Block style={[styles.pBody, { width: '100%' }, bar, pulse]} />
            <Block style={[styles.pBody, { width: '100%' }, bar, pulse]} />
            <Block style={[styles.pBody, { width: '64%' }, bar, pulse]} />
          </View>
          <Block style={[styles.pActionBar, bar, pulse]} />
        </View>
      );
      break;
    case 'card':
      // 大图块 + 标题 + 两行
      content = (
        <View>
          <Block style={[styles.cardMedia, { backgroundColor: bg }, pulse]} />
          <Block style={[styles.titleBar, { marginTop: Spacing.sm }, bar, pulse]} />
          <Block style={[styles.lineBar, bar, pulse]} />
          <Block style={[styles.lineBar, { width: '56%' }, bar, pulse]} />
        </View>
      );
      break;
    case 'row':
    default:
      // 头像圆 + 两行文本
      content = (
        <View style={styles.rowRow}>
          <Block style={[styles.avatarSmall, { backgroundColor: bg }, pulse]} />
          <View style={styles.rowColumn}>
            <Block style={[styles.rowBar1, bar, pulse]} />
            <Block style={[styles.rowBar2, bar, pulse]} />
          </View>
        </View>
      );
      break;
  }

  return (
    <View style={[styles.cell, style]} accessible={false}>
      {content}
    </View>
  );
}

// ---------- 骨架列表 ----------

// 自然高度变体：thread/post 由内容撑高（与真实卡片同构），不套固定行高。
const NATURAL_VARIANTS: readonly SkeletonVariant[] = ['thread', 'post'];

// 固定行高变体的缺省行高 = 各界面真实行高（骨架替换列表时块高度一致，切换不跳）
const DEFAULT_ITEM_HEIGHT: Partial<Record<SkeletonVariant, number>> = {
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
  const natural = NATURAL_VARIANTS.includes(variant);
  const height = itemHeight ?? (natural ? undefined : DEFAULT_ITEM_HEIGHT[variant]);

  return (
    <View
      style={[styles.list, natural && styles.listTight, style]}
      accessibilityRole="progressbar"
      accessibilityLabel="内容加载中"
    >
      {Array.from({ length: count }, (_, index) => (
        <View key={index} style={[styles.item, height != null && { height }]}>
          <SkeletonCell
            variant={variant}
            pulse={pulse}
            // 真实信息流图文混排：骨架按半数带图交替，首屏即含图片占位
            withMedia={index % 2 === 0}
          />
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
  // 自然高度变体（thread/post）：行距由卡片自身 marginVertical 4 承担
  //（两卡之间 8pt，与真实 TweetCard/PostCard 列表完全一致）
  listTight: {
    gap: 0,
  },
  item: {
    width: '100%',
    justifyContent: 'center',
  },
  cell: {
    width: '100%',
  },

  // ── thread（TweetCard 同形）──
  tWrap: {
    marginHorizontal: T_WRAP,
    marginVertical: 4,
    ...RadiusStyle.card,
    borderWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: T_PAD,
    paddingTop: 12,
    paddingBottom: 8,
  },
  tHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    height: T_AVATAR,
  },
  tAvatar: {
    width: T_AVATAR,
    height: T_AVATAR,
    borderRadius: T_AVATAR / 2,
    borderCurve: 'continuous',
  },
  tNameBar: {
    height: 13,
    width: 132,
    ...RadiusStyle.chip,
  },
  tTimeBar: {
    height: 11,
    width: 56,
    ...RadiusStyle.chip,
  },
  // 内容列缩进与名字列对齐（-6 收紧头部空白，同 TweetCard contentCol）
  tContent: {
    marginLeft: T_INDENT,
    marginTop: -6,
    gap: 6,
  },
  tTitle: {
    height: 16,
    ...RadiusStyle.chip,
  },
  // 摘要行：行高 22（bar 14 + 上方 8 间距的视觉折算）
  tLine: {
    height: 14,
    ...RadiusStyle.chip,
  },
  tMedia: {
    width: '100%',
    borderRadius: MEDIA_RADIUS,
    borderCurve: 'continuous',
  },
  tActions: {
    flexDirection: 'row',
    alignItems: 'center',
    height: 32,
    marginTop: 2,
  },
  tActionGroup: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
  },
  tActionIcon: {
    width: 17,
    height: 17,
    borderRadius: 9,
  },
  tActionText: {
    width: 30,
    height: 9,
    ...RadiusStyle.chip,
  },

  // ── post（PostCard 同形）──
  pWrap: {
    marginHorizontal: 10,
    marginVertical: 4,
    ...RadiusStyle.card,
    borderWidth: StyleSheet.hairlineWidth,
    padding: 16,
  },
  pHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    marginBottom: 10,
  },
  pAvatar: {
    width: 36,
    height: 36,
    borderRadius: 18,
    borderCurve: 'continuous',
  },
  pNickBar: {
    height: 12,
    width: 110,
    ...RadiusStyle.chip,
  },
  pBodyCol: {
    gap: 8,
  },
  pBody: {
    height: 14,
    ...RadiusStyle.chip,
  },
  pActionBar: {
    height: 10,
    width: '42%',
    ...RadiusStyle.chip,
    marginTop: 12,
  },

  // ── card ──
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
  cardMedia: {
    width: '100%',
    height: 160,
    ...RadiusStyle.cardLarge,
  },

  // ── row ──
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
