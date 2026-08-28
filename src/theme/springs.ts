// ============================================================
// TiebaLite React Native - Unified Spring Tokens
// Apple Design: damping ratio + response model
// ============================================================

import { Easing } from 'react-native-reanimated';

/**
 * Press feedback scale values
 */
export const PRESS_SCALE = {
  /** Standard card / button press */
  default: 0.97,
  /** Smaller elements (chips, icons) */
  small: 0.93,
  /** Large surfaces (sheets) */
  large: 0.99,
} as const;

// ------------------------------------------------------------
// 动效令牌（设计系统契约 v2）
// damping/stiffness 采用 Reanimated 弹簧模型（damping 越高越不弹）
// ------------------------------------------------------------

/** PRESS_ENTER — 按压进入：快速起压，轻微回弹 */
export const PRESS_ENTER = {
  damping: 18,
  stiffness: 320,
  mass: 1,
} as const;

/** MOMENTUM — 手势释放/拖拽惯性，轻微过冲 */
export const MOMENTUM = {
  damping: 16,
  stiffness: 220,
  mass: 1,
} as const;

/**
 * CHROME_HIDE — chrome 控件随滚动收放（FAB/浮动条类）。
 * 对齐 iOS 原生：Safari 工具栏/导航栏的滚动收纳是临界阻尼、无过冲；
 * ζ = 28 / (2·√220) ≈ 0.94。交互回弹（查看器/点赞 pop）仍用 MOMENTUM
 * 的轻微弹性。
 */
export const CHROME_HIDE = {
  damping: 28,
  stiffness: 220,
  mass: 1,
} as const;

/** EASE_OUT — 标准退场缓动（Reanimated 4 等效 cubic-bezier(0.32, 0.72, 0.00, 1.00)） */
export const EASE_OUT = Easing.bezier(0.32, 0.72, 0.0, 1.0);

/** DURATION — 时长令牌（ms） */
export const DURATION = {
  /** 入场 */
  enter: 220,
  /** 退场 */
  exit: 180,
  /** 级联入场间隔 */
  stagger: 35,
} as const;
