// ============================================================
// TiebaLite React Native - Theme System Barrel Export
// ============================================================

// Colors
export {
  getThemeColors,
  toLegacyThemeColors,
} from './colors';
export type { SemanticColors } from './colors';

// Typography
export {
  typographyStyles,
  typographyStyles as TypographyStyles,
} from './typography';
export type { TypographyStyle } from './typography';

// Spacing
export {
  Spacing,
  Radius,
  RadiusStyle,
  Shadows,
  IconSize,
} from './spacing';
export type { SpacingKey } from './spacing';

// Springs
export * from './springs';

// Glass surface material tokens
export { glassTokens } from './glass';
export type {
  GlassTokens,
  GlassTintTokens,
  GlassHighlightTokens,
  GlassBorderTokens,
  GlassBudgetTokens,
} from './glass';

// Haptic scene map
export { HAPTICS_MAP, hapticForScene } from './hapticsMap';
export type { HapticsScene } from './hapticsMap';

// Theme Context
export { ThemeProvider, useThemeContext, useAppTheme } from './ThemeContext';
export { default as ThemeContext } from './ThemeContext';
