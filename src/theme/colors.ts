// ============================================================
// TiebaLite React Native - iOS System Color Palette
// ui-ux-pro-max: 知识蓝 #2563EB + 白卡片 + 中性灰层级
// design-taste-frontend: 全部使用 iOS 系统级色值，不用自定义灰
// ============================================================

import type { ThemeColors, ThemeName } from '@/types';

// ---------- Semantic Color Tokens ----------
export interface SemanticColors {
  primary: string;
  primaryLight: string;
  primaryDark: string;
  accent: string;

  background: string;
  windowBackground: string;
  surface: string;
  surfaceSecondary: string;
  surfaceTertiary: string;

  /** Glass surface color (for reduceTransparency fallback) */
  glassSurface: string;
  /** Glass surface in dark mode */
  glassSurfaceDark: string;

  card: string;
  floorCard: string;
  cardElevated: string;

  toolbar: string;
  toolbarSurface: string;
  onToolbarSurface: string;
  navBar: string;
  navBarSurface: string;
  onNavBarSurface: string;
  tabBar: string;
  tabBarBorder: string;

  text: string;
  textSecondary: string;
  textTertiary: string;
  textDisabled: string;
  textOnPrimary: string;
  textLink: string;

  chip: string;
  onChip: string;
  chipSelected: string;
  switchTrack: string;
  switchTrackActive: string;
  switchThumb: string;

  divider: string;
  separator: string;
  border: string;

  /** 浅灰/深灰半透明分组底（分区 header / 楼层 blockTip 等） */
  groupFill: string;
  /** 卡片细描边（比 border 更淡，用于卡片轮廓） */
  borderCard: string;

  unselected: string;
  placeholder: string;
  disabled: string;

  success: string;
  warning: string;
  error: string;
  info: string;

  /** 点赞激活色（iOS systemPink） */
  liked: string;

  // ---------- iOS 系统级语义别名（设计系统契约 v2） ----------
  /** iOS label（同 text） */
  label: string;
  /** iOS secondaryLabel（同 textSecondary） */
  secondaryLabel: string;
  /** iOS tertiaryLabel（同 textTertiary） */
  tertiaryLabel: string;
  /** iOS opaqueSeparator（不透明分隔线） */
  opaqueSeparator: string;
  /** iOS systemBackground */
  systemBackground: string;
  /** iOS secondarySystemBackground */
  secondarySystemBackground: string;
  /** iOS tertiarySystemBackground */
  tertiarySystemBackground: string;
  /** iOS systemGroupedBackground（分组列表页底色，同 background） */
  systemGroupedBackground: string;
  /** iOS secondarySystemGroupedBackground（分组卡片/行面，同 card） */
  secondarySystemGroupedBackground: string;
  /** 全局主题色（tint / accent 别名，随主题主色） */
  tint: string;
  /** 危险色（同 error） */
  danger: string;
  /** 链接色（同 textLink） */
  link: string;

  shadow: string;
  indicator: string;
  overlay: string;
  scrim: string;

  isNight: boolean;
}

// ---------- Light Palette (iOS System) ----------
const LIGHT: SemanticColors = {
  // 品牌蓝 — ui-ux-pro-max 知识蓝
  primary: '#2563EB',
  primaryLight: 'rgba(37,99,235,0.10)',
  primaryDark: '#1D4ED8',
  accent: '#2563EB',

  // iOS groupedBackground
  background: '#F2F2F7',
  windowBackground: '#FFFFFF',
  surface: '#FFFFFF',
  surfaceSecondary: '#F2F2F7',
  surfaceTertiary: '#E5E5EA',

  // iOS 26 glass surface (reduceTransparency fallback)
  glassSurface: '#F2F2F7',
  glassSurfaceDark: '#1C1C1E',

  // iOS secondaryGroupedBackground
  card: '#FFFFFF',
  floorCard: '#FFFFFF',
  cardElevated: '#FFFFFF',

  // 导航/工具栏
  toolbar: '#F2F2F7',
  toolbarSurface: '#FFFFFF',
  onToolbarSurface: '#000000',
  navBar: '#F2F2F7',
  navBarSurface: '#FFFFFF',
  onNavBarSurface: '#000000',
  tabBar: 'rgba(249,249,249,0.94)',
  tabBarBorder: 'rgba(60,60,67,0.12)',

  // iOS label 层级
  text: '#000000',
  textSecondary: 'rgba(60,60,67,0.6)',
  textTertiary: 'rgba(60,60,67,0.3)',
  textDisabled: 'rgba(60,60,67,0.2)',
  textOnPrimary: '#FFFFFF',
  textLink: '#2563EB',

  // Chip / Switch
  chip: 'rgba(37,99,235,0.10)',
  onChip: '#2563EB',
  chipSelected: '#2563EB',
  switchTrack: 'rgba(120,120,128,0.16)',
  switchTrackActive: '#34C759',
  switchThumb: '#FFFFFF',

  // iOS separator
  divider: 'rgba(60,60,67,0.12)',
  separator: 'rgba(60,60,67,0.12)',
  border: 'rgba(60,60,67,0.12)',
  groupFill: 'rgba(120,120,128,0.08)',
  borderCard: 'rgba(0,0,0,0.06)',

  unselected: 'rgba(60,60,67,0.3)',
  placeholder: 'rgba(60,60,67,0.3)',
  disabled: 'rgba(60,60,67,0.12)',

  // iOS system colors
  success: '#34C759',
  warning: '#FF9500',
  error: '#FF3B30',
  info: '#2563EB',
  liked: '#FF2D55',

  // iOS 系统级语义别名（亮色）
  label: '#000000',
  secondaryLabel: 'rgba(60,60,67,0.6)',
  tertiaryLabel: 'rgba(60,60,67,0.3)',
  opaqueSeparator: 'rgba(60,60,67,0.29)',
  systemBackground: '#FFFFFF',
  secondarySystemBackground: '#F2F2F7',
  tertiarySystemBackground: '#FFFFFF',
  systemGroupedBackground: '#F2F2F7',
  secondarySystemGroupedBackground: '#FFFFFF',
  tint: '#2563EB',
  danger: '#FF3B30',
  link: '#2563EB',

  shadow: '#000000',
  indicator: '#2563EB',
  overlay: 'rgba(0,0,0,0.4)',
  scrim: 'rgba(0,0,0,0.3)',

  isNight: false,
};

// ---------- Dark Palette (iOS System, Pure Black OLED) ----------
const DARK: SemanticColors = {
  // 品牌蓝暗色提亮
  primary: '#60A5FA',
  primaryLight: 'rgba(96,165,250,0.14)',
  primaryDark: '#FFFFFF',
  accent: '#60A5FA',

  // 纯黑 OLED
  background: '#000000',
  windowBackground: '#000000',
  surface: '#1C1C1E',
  surfaceSecondary: '#1C1C1E',
  surfaceTertiary: '#2C2C2E',

  // iOS 26: glass elements in dark mode should use glassEffectStyle='regular'
  // (frosted) rather than 'clear' to maintain readability on pure black OLED
  // backgrounds.
  glassSurface: '#1C1C1E',
  glassSurfaceDark: '#1C1C1E',

  // iOS dark elevated
  card: '#1C1C1E',
  floorCard: '#1C1C1E',
  cardElevated: '#2C2C2E',

  // 导航/工具栏
  toolbar: '#000000',
  toolbarSurface: '#1C1C1E',
  onToolbarSurface: '#FFFFFF',
  navBar: '#000000',
  navBarSurface: '#1C1C1E',
  onNavBarSurface: '#FFFFFF',
  tabBar: 'rgba(22,22,22,0.94)',
  tabBarBorder: 'rgba(84,84,88,0.65)',

  // iOS dark label 层级
  text: '#FFFFFF',
  textSecondary: 'rgba(235,235,245,0.6)',
  textTertiary: 'rgba(235,235,245,0.3)',
  textDisabled: 'rgba(235,235,245,0.2)',
  textOnPrimary: '#FFFFFF',
  textLink: '#60A5FA',

  // Chip / Switch
  chip: 'rgba(96,165,250,0.14)',
  onChip: '#60A5FA',
  chipSelected: '#60A5FA',
  switchTrack: 'rgba(120,120,128,0.32)',
  switchTrackActive: '#30D158',
  switchThumb: '#FFFFFF',

  // iOS dark separator
  divider: 'rgba(84,84,88,0.65)',
  separator: 'rgba(84,84,88,0.65)',
  border: 'rgba(84,84,88,0.65)',
  groupFill: 'rgba(255,255,255,0.08)',
  borderCard: 'rgba(255,255,255,0.08)',

  unselected: 'rgba(235,235,245,0.3)',
  placeholder: 'rgba(235,235,245,0.3)',
  disabled: 'rgba(84,84,88,0.65)',

  // iOS dark system colors
  success: '#30D158',
  warning: '#FF9F0A',
  error: '#FF453A',
  info: '#60A5FA',
  liked: '#FF375F',

  // iOS 系统级语义别名（暗色）
  label: '#FFFFFF',
  secondaryLabel: 'rgba(235,235,245,0.6)',
  tertiaryLabel: 'rgba(235,235,245,0.3)',
  opaqueSeparator: 'rgba(84,84,88,0.65)',
  systemBackground: '#000000',
  secondarySystemBackground: '#1C1C1E',
  tertiarySystemBackground: '#2C2C2E',
  systemGroupedBackground: '#000000',
  secondarySystemGroupedBackground: '#1C1C1E',
  tint: '#60A5FA',
  danger: '#FF453A',
  link: '#60A5FA',

  shadow: '#000000',
  indicator: '#60A5FA',
  overlay: 'rgba(0,0,0,0.6)',
  scrim: 'rgba(0,0,0,0.5)',

  isNight: true,
};

// ---------- Color Utilities ----------
type Rgb = { r: number; g: number; b: number };

function hexToRgb(hex: string): Rgb | null {
  const match = /^#?([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(hex.trim());
  if (!match) return null;
  const raw = match[1];
  const expanded = raw.length === 3
    ? raw.split('').map((c) => c + c).join('')
    : raw;
  const value = parseInt(expanded, 16);
  return {
    r: (value >> 16) & 0xff,
    g: (value >> 8) & 0xff,
    b: value & 0xff,
  };
}

function normalizeHex(hex: string | undefined): string | null {
  const rgb = hexToRgb(hex ?? '');
  if (!rgb) return null;
  return `#${[rgb.r, rgb.g, rgb.b].map((v) => v.toString(16).toUpperCase().padStart(2, '0')).join('')}`;
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function rgba(hex: string, alpha: number): string {
  const rgb = hexToRgb(hex);
  if (!rgb) return hex;
  const a = Math.round(clamp(alpha, 0, 1) * 100) / 100;
  return `rgba(${rgb.r},${rgb.g},${rgb.b},${a})`;
}

function shade(hex: string, amount: number): string {
  const rgb = hexToRgb(hex);
  if (!rgb) return hex;
  const channel = (value: number) => clamp(Math.round(value + amount), 0, 255);
  return `#${[channel(rgb.r), channel(rgb.g), channel(rgb.b)].map((v) => v.toString(16).toUpperCase().padStart(2, '0')).join('')}`;
}

const darken = (hex: string, amount: number) => shade(hex, -amount);
const lighten = (hex: string, amount: number) => shade(hex, amount);

function mixHex(hexA: string, hexB: string, weightB: number): string {
  const a = hexToRgb(hexA);
  const b = hexToRgb(hexB);
  if (!a || !b) return hexA;
  const channel = (aValue: number, bValue: number) =>
    Math.round(aValue + (bValue - aValue) * clamp(weightB, 0, 1));
  return `#${[channel(a.r, b.r), channel(a.g, b.g), channel(a.b, b.b)].map((v) => v.toString(16).toUpperCase().padStart(2, '0')).join('')}`;
}

function darkAdapted(hex: string): string {
  const rgb = hexToRgb(hex);
  if (!rgb) return hex;
  const luminance = (0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b) / 255;
  return mixHex(hex, '#FFFFFF', luminance < 0.4 ? 0.45 : 0.25);
}

function withPrimary(base: SemanticColors, primary: string): SemanticColors {
  const rgb = hexToRgb(primary);
  if (!rgb) return base;
  const isNight = base.isNight;
  const luminance = (0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b) / 255;
  return {
    ...base,
    primary,
    primaryLight: rgba(primary, isNight ? 0.16 : 0.10),
    primaryDark: isNight ? lighten(primary, 28) : darken(primary, 26),
    accent: primary,
    chip: rgba(primary, isNight ? 0.16 : 0.10),
    onChip: primary,
    chipSelected: primary,
    switchTrackActive: primary,
    textLink: primary,
    info: primary,
    indicator: primary,
    tint: primary,
    link: primary,
    textOnPrimary: luminance > 0.55 ? '#000000' : '#FFFFFF',
  };
}

// ---------- Theme Definitions ----------
interface ThemeDefinition {
  primary: string;
  darkPrimary?: string;
  darkOnly?: boolean;
  surfaces?: Partial<SemanticColors>;
}

/** 自定义主题默认主色（preferences.ts 默认值同源引用，避免双源漂移） */
export const DEFAULT_CUSTOM_PRIMARY = '#4477E0';
const DEFAULT_TRANSLUCENT_ALPHA = 0.85;

const THEME_DEFINITIONS: Record<string, ThemeDefinition> = {
  blue: {
    primary: '#007AFF',
    darkPrimary: '#64A5FF',
  },
  black: {
    primary: '#000000',
    darkPrimary: '#E5E5EA',
  },
  pink: {
    primary: '#FF9A9E',
    darkPrimary: '#FFB3B7',
  },
  red: {
    primary: '#C51100',
    darkPrimary: '#FF6B62',
  },
  purple: {
    primary: '#512DA8',
    darkPrimary: '#B39DDB',
  },
  blue_dark: {
    darkOnly: true,
    primary: '#64A5FF',
    surfaces: {
      background: '#17212B',
      windowBackground: '#17212B',
      surface: '#202B37',
      surfaceSecondary: '#1B2733',
      surfaceTertiary: '#263442',
      glassSurface: '#202B37',
      glassSurfaceDark: '#202B37',
      card: '#202B37',
      floorCard: '#242F3D',
      cardElevated: '#263442',
      systemGroupedBackground: '#17212B',
      secondarySystemGroupedBackground: '#202B37',
      toolbar: '#17212B',
      toolbarSurface: '#242F3D',
      navBar: '#1B2733',
      navBarSurface: '#242F3D',
      tabBar: 'rgba(23,33,43,0.94)',
      tabBarBorder: 'rgba(120,130,145,0.35)',
      divider: 'rgba(120,130,145,0.28)',
      separator: 'rgba(120,130,145,0.28)',
      border: 'rgba(120,130,145,0.28)',
      unselected: '#5A6670',
    },
  },
  grey_dark: {
    darkOnly: true,
    primary: '#9AA3B2',
    surfaces: {
      background: '#202020',
      windowBackground: '#202020',
      surface: '#2A2A2A',
      surfaceSecondary: '#242424',
      surfaceTertiary: '#323232',
      glassSurface: '#2A2A2A',
      glassSurfaceDark: '#2A2A2A',
      card: '#2A2A2A',
      floorCard: '#1E1E1E',
      cardElevated: '#323232',
      systemGroupedBackground: '#202020',
      secondarySystemGroupedBackground: '#2A2A2A',
      toolbar: '#202020',
      toolbarSurface: '#2C2C2C',
      navBar: '#303030',
      navBarSurface: '#2C2C2C',
      tabBar: 'rgba(32,32,32,0.94)',
      tabBarBorder: 'rgba(120,120,128,0.35)',
      divider: 'rgba(120,120,128,0.28)',
      separator: 'rgba(120,120,128,0.28)',
      border: 'rgba(120,120,128,0.28)',
      unselected: '#808080',
    },
  },
};

// Pure black OLED variant: true black backgrounds with lifted gray-black
// elevated surfaces (#121214~#16161A) so cards stay separable from the void.
const AMOLED_DARK: SemanticColors = {
  ...withPrimary(DARK, '#5B9BFF'),
  background: '#000000',
  windowBackground: '#000000',
  surface: '#121214',
  surfaceSecondary: '#121214',
  surfaceTertiary: '#1C1C1E',
  glassSurface: '#121214',
  glassSurfaceDark: '#121214',
  card: '#121214',
  floorCard: '#16161A',
  cardElevated: '#1C1C1E',
  systemGroupedBackground: '#000000',
  secondarySystemGroupedBackground: '#121214',
  toolbar: '#000000',
  toolbarSurface: '#151518',
  navBar: '#000000',
  navBarSurface: '#151518',
  tabBar: 'rgba(0,0,0,0.96)',
  tabBarBorder: 'rgba(84,84,88,0.4)',
  divider: 'rgba(84,84,88,0.4)',
  separator: 'rgba(84,84,88,0.4)',
  border: 'rgba(84,84,88,0.4)',
  unselected: '#808080',
  placeholder: 'rgba(230,231,238,0.3)',
  disabled: 'rgba(84,84,88,0.6)',
};

// ---------- Public API ----------
export function getThemeColors(
  themeName?: ThemeName,
  customPrimary?: string,
  isDark: boolean = false,
): SemanticColors {
  const name = themeName ?? 'tieba';

  // 「默认」= 初始内置配色：浅色走 LIGHT、深色走 DARK（与 tieba 同色，
  // 差异仅在消费侧据此保持行图标五彩态，见 settings/index.tsx）。
  if (name === 'default') return isDark ? DARK : LIGHT;
  // Default theme keeps the historical LIGHT/DARK behavior.
  if (name === 'tieba') return isDark ? DARK : LIGHT;
  // Dark-named themes are dark regardless of the mode flag.
  if (name === 'dark') return DARK;
  if (name === 'amoled_dark') return AMOLED_DARK;

  if (name === 'custom') {
    const primary = normalizeHex(customPrimary) ?? DEFAULT_CUSTOM_PRIMARY;
    return withPrimary(isDark ? DARK : LIGHT, isDark ? darkAdapted(primary) : primary);
  }

  if (name === 'translucent') {
    return translucentPalette(isDark ? DARK.primary : LIGHT.primary, DEFAULT_TRANSLUCENT_ALPHA);
  }

  const definition = THEME_DEFINITIONS[name];
  const effectiveDark = isDark || definition?.darkOnly === true;
  const base = effectiveDark ? DARK : LIGHT;
  if (!definition) return base;

  const primary = effectiveDark
    ? (definition.darkOnly
        ? definition.primary
        : (definition.darkPrimary ?? darkAdapted(definition.primary)))
    : definition.primary;
  let colors = withPrimary(base, primary);
  if (definition.surfaces) colors = { ...colors, ...definition.surfaces };
  return colors;
}

export function toLegacyThemeColors(semantic: SemanticColors, themeName: ThemeName): ThemeColors {
  return {
    theme: themeName,
    primary: semantic.primary,
    accent: semantic.accent,
    background: semantic.background,
    windowBackground: semantic.windowBackground,
    card: semantic.card,
    floorCard: semantic.floorCard,
    toolbar: semantic.toolbar,
    toolbarSurface: semantic.toolbarSurface,
    onToolbarSurface: semantic.onToolbarSurface,
    navBar: semantic.navBar,
    navBarSurface: semantic.navBarSurface,
    onNavBarSurface: semantic.onNavBarSurface,
    text: semantic.text,
    textSecondary: semantic.textSecondary,
    textDisabled: semantic.textDisabled,
    textOnPrimary: semantic.textOnPrimary,
    chip: semantic.chip,
    onChip: semantic.onChip,
    divider: semantic.divider,
    unselected: semantic.unselected,
    placeholder: semantic.placeholder,
    shadow: semantic.shadow,
    indicator: semantic.indicator,
    isNight: semantic.isNight,
  };
}

/**
 * Returns a translucent variant of the base palette.
 *
 * The original Kotlin app derived a per-theme translucent palette by blending
 * the theme's primary color (`basePrimary`) at `alpha` opacity over surface
 * colors for glass/translucent surfaces. This builds a light palette whose
 * surfaces and chips are semi-transparent and tinted with `basePrimary`.
 */
export function translucentPalette(basePrimary: string, alpha: number = DEFAULT_TRANSLUCENT_ALPHA): SemanticColors {
  const primary = normalizeHex(basePrimary) ?? LIGHT.primary;
  const a = clamp(alpha, 0, 1);
  const tint = (amount: number) => rgba(primary, a * amount);
  const white = (amount: number) => rgba('#FFFFFF', a * amount);

  return {
    ...withPrimary(LIGHT, primary),
    primaryLight: tint(0.12),
    background: rgba('#F2F2F7', a * 0.68),
    windowBackground: white(0.82),
    surface: white(0.72),
    surfaceSecondary: rgba('#F2F2F7', a * 0.64),
    surfaceTertiary: tint(0.06),
    glassSurface: white(0.58),
    glassSurfaceDark: rgba('#1C1C1E', a * 0.5),
    card: white(0.78),
    floorCard: white(0.6),
    cardElevated: white(0.84),
    toolbar: white(0.64),
    toolbarSurface: white(0.78),
    navBar: white(0.64),
    navBarSurface: white(0.78),
    tabBar: white(0.84),
    tabBarBorder: tint(0.22),
    chip: tint(0.14),
    divider: tint(0.18),
    separator: tint(0.18),
    border: tint(0.18),
    unselected: tint(0.34),
    placeholder: tint(0.22),
    disabled: tint(0.14),
    isNight: false,
  };
}

