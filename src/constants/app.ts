/**
 * TiebaLite React Native - App Constants
 * Migrated from com.huanchengfly.tieba.post.Consts
 */

// 3 seconds between each forum sign

import type { ThemeName } from '@/types'; export const APP_NAME = '贴吧Lite';
export const APP_VERSION = '1.0.0';

// Auto sign
// 对齐 Kotlin IOKSigner.getSignDelay()：非慢速模式固定 2000ms；
// 慢速模式 3500-8000ms 随机（见 runSignBatch.ts）。
export const AUTO_SIGN_MIN_INTERVAL_MS = 2000;

/** Single source of truth for selectable theme names and their labels. */
export const THEME_OPTIONS: { key: ThemeName; label: string; mode: 'light' | 'dark' }[] = [
  // 「默认」= 初始内置态：配色同 tieba/dark，且设置页行图标保持五彩（不染主色）
  { key: 'default', label: '默认', mode: 'light' },
  { key: 'tieba', label: '贴吧蓝', mode: 'light' },
  { key: 'blue', label: '系统蓝', mode: 'light' },
  { key: 'black', label: '经典黑', mode: 'light' },
  { key: 'pink', label: '粉色', mode: 'light' },
  { key: 'red', label: '红色', mode: 'light' },
  { key: 'purple', label: '紫色', mode: 'light' },
  { key: 'custom', label: '自定义', mode: 'light' },
  { key: 'default', label: '默认', mode: 'dark' },
  { key: 'dark', label: '暗夜', mode: 'dark' },
  { key: 'blue_dark', label: '暗夜蓝', mode: 'dark' },
  { key: 'grey_dark', label: '暗夜灰', mode: 'dark' },
  { key: 'amoled_dark', label: '纯黑', mode: 'dark' },
];

export const LIGHT_THEME_OPTIONS = THEME_OPTIONS.filter((t) => t.mode === 'light');
export const DARK_THEME_OPTIONS = THEME_OPTIONS.filter((t) => t.mode === 'dark');
