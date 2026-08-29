// ============================================================
// TiebaLite React Native - iOS Dynamic Type Scale
// design-taste-frontend: SF Pro Text + SF Pro Rounded (数字)
// 通过字号×字重跳跃实现对比，不加载第三方字体
// ============================================================

import { StyleSheet } from 'react-native';

// ---------- Typography Token ----------
export interface TypographyStyle {
  fontSize: number;
  lineHeight: number;
  fontWeight: '400' | '500' | '600' | '700' | '900';
  letterSpacing?: number;
}

// ---------- RN StyleSheet shortcuts ----------
// （唯一生效入口：历史遗留的 `Typography` 对象与 typographyStyles 完全重复，
//   已删除；改动字号请同步这里。）
export const typographyStyles = StyleSheet.create({
  largeTitle: {
    fontSize: 34,
    lineHeight: 41,
    fontWeight: '700',
    letterSpacing: -0.5,
  },
  title2: {
    fontSize: 22,
    lineHeight: 28,
    fontWeight: '700',
    letterSpacing: -0.4,
  },
  title3: {
    fontSize: 20,
    lineHeight: 25,
    fontWeight: '600',
    letterSpacing: -0.4,
  },
  headline: {
    fontSize: 17,
    lineHeight: 22,
    fontWeight: '600',
    letterSpacing: 0,
  },
  body: {
    fontSize: 17,
    lineHeight: 24,
    fontWeight: '400',
    letterSpacing: 0,
  },
  bodyBold: {
    fontSize: 17,
    lineHeight: 24,
    fontWeight: '600',
    letterSpacing: 0,
  },
  subhead: {
    fontSize: 15,
    lineHeight: 20,
    fontWeight: '400',
    letterSpacing: 0,
  },
  subheadBold: {
    fontSize: 15,
    lineHeight: 20,
    fontWeight: '600',
    letterSpacing: 0,
  },
  callout: {
    fontSize: 16,
    lineHeight: 21,
    fontWeight: '400',
    letterSpacing: 0,
  },
  calloutBold: {
    fontSize: 16,
    lineHeight: 21,
    fontWeight: '600',
    letterSpacing: 0,
  },
  footnote: {
    fontSize: 13,
    lineHeight: 18,
    fontWeight: '400',
    letterSpacing: 0,
  },
  footnoteBold: {
    fontSize: 13,
    lineHeight: 18,
    fontWeight: '600',
    letterSpacing: 0,
  },
  caption1: {
    fontSize: 12,
    lineHeight: 16,
    fontWeight: '400',
    letterSpacing: 0,
  },
  caption1Bold: {
    fontSize: 12,
    lineHeight: 16,
    fontWeight: '600',
    letterSpacing: 0,
  },
  caption2: {
    fontSize: 11,
    lineHeight: 13,
    fontWeight: '400',
    letterSpacing: 0,
  },
  caption2Bold: {
    fontSize: 11,
    lineHeight: 13,
    fontWeight: '600',
    letterSpacing: 0,
  },
  /** 热榜排名、统计数字 */
  number: {
    fontSize: 20,
    lineHeight: 24,
    fontWeight: '700',
    letterSpacing: 0,
    fontVariant: ['tabular-nums'],
  },
});

// Legacy compatibility export
export { typographyStyles as TypographyStyles };
