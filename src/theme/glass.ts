// ============================================================
// TiebaLite - Glass Surface Material Tokens (玻璃面材质令牌)
//
// iOS 26 液态玻璃质感设计规范。单一声明，供 GlassView tint 属性、
// staticGlass 模拟降级与后续 NativeGlassSurface 消费。
// 设计文档 §3.1，精确值以本文件为准。
// ============================================================

import { StyleSheet } from 'react-native';

// ---------- 类型 ----------

export interface GlassTintTokens {
  /** 浅色玻璃 tintColor */
  light: string;
  /** 深色玻璃 tintColor */
  dark: string;
}

export interface GlassHighlightTokens {
  /** 浅色顶部高光渐变（staticGlass 模拟用） */
  light: readonly [string, string];
  /** 深色顶部高光渐变（staticGlass 模拟用） */
  dark: readonly [string, string];
}

export interface GlassBorderTokens {
  /** 浅色描边 */
  light: string;
  /** 深色描边 */
  dark: string;
  /** 描边宽度（hairline） */
  width: number;
}

export interface GlassBudgetTokens {
  /** 每屏实时玻璃（UIVisualEffectView）实例上限，超出即降级 */
  maxRealTimePerScreen: number;
}

export interface GlassTokens {
  tint: GlassTintTokens;
  highlight: GlassHighlightTokens;
  border: GlassBorderTokens;
  budget: GlassBudgetTokens;
}

// ---------- 令牌 ----------

export const glassTokens: GlassTokens = {
  tint: {
    light: 'rgba(255,255,255,0.35)',
    dark: 'rgba(255,255,255,0.06)',
  },
  highlight: {
    light: ['rgba(255,255,255,0.5)', 'rgba(255,255,255,0)'],
    dark: ['rgba(255,255,255,0.08)', 'rgba(255,255,255,0)'],
  },
  border: {
    light: 'rgba(255,255,255,0.5)',
    dark: 'rgba(0,0,0,0.3)',
    width: StyleSheet.hairlineWidth,
  },
  budget: {
    maxRealTimePerScreen: 1,
  },
};

export default glassTokens;
