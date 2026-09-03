// ============================================================
// TiebaLite React Native - Split Theme Context (Performance)
//
// Theme state is persisted through the Zustand preferences store;
// this context only splits color consumers from action consumers to
// avoid unnecessary re-renders.
// ============================================================

import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
} from 'react';
import { Appearance, useColorScheme } from 'react-native';

import type { ThemeColors, ThemeName } from '@/types';
import { getThemeColors, toLegacyThemeColors } from './colors';
import type { SemanticColors } from './colors';
import { usePreferencesStore } from '@/stores/preferencesStore';
import { LIGHT_THEME_OPTIONS, DARK_THEME_OPTIONS } from '@/constants/app';

// ---------- Types ----------

interface ThemeColorsValue {
  colors: SemanticColors;
  themeColors: ThemeColors;
  isDark: boolean;
  lightThemeName: ThemeName;
  darkThemeName: ThemeName;
  themeName: ThemeName;
  followSystemDarkMode: boolean;
  darkMode: boolean;
}

interface ThemeActionsValue {
  setTheme: (name: ThemeName) => void;
  setLightTheme: (name: ThemeName) => void;
  setDarkTheme: (name: ThemeName) => void;
  setDarkMode: (enabled: boolean) => void;
  setFollowSystemDarkMode: (follow: boolean) => void;
  setCustomPrimaryColor: (color: string) => void;
  /** @deprecated Use setFollowSystemDarkMode */
  setFollowSystem: (follow: boolean) => void;
}

const ThemeColorsContext = createContext<ThemeColorsValue | null>(null);
const ThemeActionsContext = createContext<ThemeActionsValue | null>(null);

const LIGHT_THEME_NAMES = new Set<ThemeName>(LIGHT_THEME_OPTIONS.map((t) => t.key));
const DARK_THEME_NAMES = new Set<ThemeName>(DARK_THEME_OPTIONS.map((t) => t.key));

export function ThemeProvider({ children }: { children: React.ReactNode }) {
  const systemColorScheme = useColorScheme();
  const systemIsDark = systemColorScheme === 'dark';

  const preferences = usePreferencesStore((s) => s.preferences);
  const setPreference = usePreferencesStore((s) => s.setPreference);

  const lightThemeName: ThemeName = LIGHT_THEME_NAMES.has(preferences.lightTheme)
    ? preferences.lightTheme
    : 'tieba';
  const darkThemeName: ThemeName = DARK_THEME_NAMES.has(preferences.darkTheme)
    ? preferences.darkTheme
    : 'dark';
  const darkMode = preferences.darkMode;
  const followSystemDarkMode = preferences.followSystemDarkMode;
  const customPrimaryColor = preferences.customPrimaryColor;

  const isDark = followSystemDarkMode ? systemIsDark : darkMode;
  const effectiveTheme: ThemeName = isDark ? darkThemeName : lightThemeName;

  const colors = useMemo<SemanticColors>(
    () => getThemeColors(effectiveTheme, customPrimaryColor, isDark),
    [effectiveTheme, customPrimaryColor, isDark],
  );

  // 应用内深色下发到整个原生窗口：纯 UIKit 面（TiebaSegmentedControlView 等
  // 非 expo-ui 宿主控件）只跟系统 trait，"深色常驻 + 系统浅色"时会以浅色样式
  // 出现在黑色页面上。override 值恒等于 isDark，与 useColorScheme 回读一致，
  // 不产生回环。键盘/系统菜单等独立窗口仍跟系统（iOS 平台边界，无法覆盖）。
  //
  // 2026-09-02 修复（自动切换失效）：Appearance.setColorScheme 是强制覆盖——
  // 一旦传入具体值，useColorScheme() 返回锁定值、系统主题变化不再触发重渲染，
  // followSystemDarkMode=true 时"系统切深色应用无反应"（真机实测）。跟随模式下
  // 必须传 null 恢复系统联动；仅手动深色/浅色（!followSystem）才下发具体值。
  useEffect(() => {
    if (followSystemDarkMode) {
      // 'unspecified' = 恢复系统跟随（RN 内部回读系统当前值；传具体值
      // 会覆盖系统、useColorScheme 锁定 → 自动切换失效，2026-09-02 修复）。
      Appearance.setColorScheme('unspecified');
      try {
        require('../../modules/tieba-native/src/TiebaNative').TiebaNative.setChromeUserInterfaceStyle(null);
      } catch {}
    } else {
      Appearance.setColorScheme(isDark ? 'dark' : 'light');
      try {
        require('../../modules/tieba-native/src/TiebaNative').TiebaNative.setChromeUserInterfaceStyle(isDark);
      } catch {}
    }
  }, [isDark, followSystemDarkMode]);

  const themeColors = useMemo<ThemeColors>(
    () => toLegacyThemeColors(colors, effectiveTheme),
    [colors, effectiveTheme],
  );

  const setLightTheme = useCallback(
    (name: ThemeName) => setPreference('lightTheme', name),
    [setPreference],
  );
  const setDarkTheme = useCallback(
    (name: ThemeName) => setPreference('darkTheme', name),
    [setPreference],
  );
  const setTheme = useCallback(
    (name: ThemeName) => {
      setPreference('lightTheme', name);
      setPreference('darkTheme', name);
    },
    [setPreference],
  );
  const setDarkMode = useCallback(
    (enabled: boolean) => setPreference('darkMode', enabled),
    [setPreference],
  );
  const setFollowSystemDarkMode = useCallback(
    (follow: boolean) => setPreference('followSystemDarkMode', follow),
    [setPreference],
  );
  const setCustomPrimaryColor = useCallback(
    (color: string) => setPreference('customPrimaryColor', color),
    [setPreference],
  );
  const setFollowSystem = setFollowSystemDarkMode;

  const colorsValue = useMemo<ThemeColorsValue>(
    () => ({
      colors,
      themeColors,
      isDark,
      lightThemeName,
      darkThemeName,
      themeName: effectiveTheme,
      followSystemDarkMode,
      darkMode,
    }),
    [colors, themeColors, isDark, lightThemeName, darkThemeName, effectiveTheme, followSystemDarkMode, darkMode],
  );

  const actionsValue = useMemo<ThemeActionsValue>(
    () => ({
      setTheme,
      setLightTheme,
      setDarkTheme,
      setDarkMode,
      setFollowSystemDarkMode,
      setCustomPrimaryColor,
      setFollowSystem,
    }),
    [setTheme, setLightTheme, setDarkTheme, setDarkMode, setFollowSystemDarkMode, setCustomPrimaryColor, setFollowSystem],
  );

  return (
    <ThemeColorsContext.Provider value={colorsValue}>
      <ThemeActionsContext.Provider value={actionsValue}>
        {children}
      </ThemeActionsContext.Provider>
    </ThemeColorsContext.Provider>
  );
}

export function useThemeColors(): ThemeColorsValue {
  const ctx = useContext(ThemeColorsContext);
  if (!ctx) throw new Error('useThemeColors must be used within ThemeProvider');
  return ctx;
}

export function useThemeActions(): ThemeActionsValue {
  const ctx = useContext(ThemeActionsContext);
  if (!ctx) throw new Error('useThemeActions must be used within ThemeProvider');
  return ctx;
}

export function useThemeContext(): ThemeColorsValue & ThemeActionsValue {
  const colors = useThemeColors();
  const actions = useThemeActions();
  return useMemo(() => ({ ...colors, ...actions }), [colors, actions]);
}

/** @deprecated Use useThemeColors() for UI components, useThemeActions() for controls */
export const useAppTheme = useThemeContext;

export default ThemeColorsContext;
