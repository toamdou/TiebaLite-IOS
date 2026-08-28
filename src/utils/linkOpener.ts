// ============================================================
// linkOpener — Unified link-opening utility respecting the
// user's "in-app browser" preference.
//
// - in-app:  expo-web-browser (SFSafariViewController on iOS)
// - external: Linking.openURL (system Safari)
// ============================================================

import { Appearance, Linking, Alert } from 'react-native';
import * as WebBrowser from 'expo-web-browser';
import { getPreferences } from '@/services/storage/PreferencesStorage';
import { getThemeColors } from '@/theme/colors';

/**
 * Open a URL based on the user's `useBuiltInBrowser` preference.
 *
 * @param url - The URL to open.
 * @param forceInApp - 预留：强制应用内打开。当前全仓无调用方（外链语义收紧时
 *   启用，第三方链接默认走系统 Safari 的行为来自动变化）；保留参数以免
 *   调用点语义漂移。
 */
export async function openLink(
  url: string,
  forceInApp?: boolean,
): Promise<void> {
  try {
    const prefs = await getPreferences();
    const useInApp = forceInApp ?? (prefs.useBuiltInBrowser ?? true);

    if (useInApp) {
      // SafariVC 的 controlsColor 跟随当前应用内主题主色（非 React 环境，
      // 用 Appearance 读系统外观 + 偏好里的手动深色开关自行解析）
      const isDark = prefs.followSystemDarkMode
        ? Appearance.getColorScheme() === 'dark'
        : (prefs.darkMode ?? false);
      const themed = getThemeColors(
        isDark ? prefs.darkTheme : prefs.lightTheme,
        prefs.customPrimaryColor,
        isDark,
      );
      await WebBrowser.openBrowserAsync(url, {
        controlsColor: themed.primary,
        dismissButtonStyle: 'done',
        presentationStyle:
          WebBrowser.WebBrowserPresentationStyle.AUTOMATIC,
        enableBarCollapsing: true,
        readerMode: false,
      });
    } else {
      const canOpen = await Linking.canOpenURL(url);
      if (canOpen) {
        await Linking.openURL(url);
      } else {
        Alert.alert('无法打开链接', url);
      }
    }
  } catch {
    // Fallback to Linking
    try {
      await Linking.openURL(url);
    } catch {
      Alert.alert('无法打开链接', url);
    }
  }
}
