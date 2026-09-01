// ============================================================
// linkOpener — Unified link-opening utility respecting the
// user's "in-app browser" preference.
//
// - in-app:  expo-web-browser (SFSafariViewController on iOS)
// - external: Linking.openURL (system Safari)
// ============================================================

import { Appearance, Linking, Alert } from 'react-native';
import * as WebBrowser from 'expo-web-browser';
import { router } from 'expo-router';
import { getPreferences } from '@/services/storage/PreferencesStorage';
import { getThemeColors } from '@/theme/colors';

/**
 * 贴吧站内链接直达（2026-08-29 用户反馈）：帖子链接（/p/<tid>）与吧链接
 * （/f?kw=<吧名>）命中时直接站内跳转，不再开内置浏览器。仅识别无歧义的
 * 主站路径；短链（t.cn 等）无法静态还原，维持原行为。
 */
function tryTiebaInApp(raw: string): boolean {
  const thread = raw.match(
    /^https?:\/\/(?:www\.)?tieba\.baidu\.com\/p\/(\d+)/,
  );
  if (thread) {
    router.push(`/thread/${thread[1]}`);
    return true;
  }
  const forum = raw.match(
    /^https?:\/\/(?:www\.)?tieba\.baidu\.com\/f\?[^#]*\bkw=([^&#]+)/,
  );
  if (forum) {
    try {
      router.push(`/forum/${encodeURIComponent(decodeURIComponent(forum[1]))}`);
      return true;
    } catch {
      // kw 编码非法：回退原行为
    }
  }
  return false;
}

/**
 * 直连目标 host 校验（Mimosa：请求前校验，拒绝 localhost/环回/私有/保留）：
 * 仅放行 https 公开域名——拒绝 localhost、IP 字面量（含私有/保留网段）。
 */
function isPublicHttpUrl(target: URL): boolean {
  if (target.protocol !== 'https:') return false;
  const h = target.hostname.toLowerCase();
  if (h === '' || h === 'localhost' || h.endsWith('.localhost')) return false;
  // IP 字面量一律拒绝（无法可靠区分环回/私有/保留，公开站点用域名）
  if (/^\d{1,3}(\.\d{1,3}){3}$/.test(h)) return false;
  return true;
}

/**
 * 百度站外链接安全确认页（/mo/q/checkurl?url=…）：该 H5 确认页在应用内
 * SafariVC 打不开（依赖贴吧环境，2026-09-01 用户实测「打不开这个页面」）。
 * 点击本身就是跳转意图 → 解析 url 参数、host 校验后直接打开真实目标。
 */
function tryCheckUrlRedirect(raw: string): string | null {
  if (!/^https?:\/\/tieba\.baidu\.com\/mo\/q\/checkurl\?/i.test(raw)) return null;
  const m = raw.match(/[?&]url=([^&#]+)/i);
  if (!m) return null;
  try {
    const target = new URL(decodeURIComponent(m[1]));
    return isPublicHttpUrl(target) ? target.toString() : null;
  } catch {
    return null;
  }
}

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
    if (tryTiebaInApp(url)) return;

    const directTarget = tryCheckUrlRedirect(url);
    if (directTarget) {
      await WebBrowser.openBrowserAsync(directTarget, {
        dismissButtonStyle: 'done',
        presentationStyle:
          WebBrowser.WebBrowserPresentationStyle.AUTOMATIC,
        enableBarCollapsing: true,
      });
      return;
    }

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
