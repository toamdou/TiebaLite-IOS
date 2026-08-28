// ============================================================
// TiebaLite React Native - Native Tabs Layout
//
// Uses expo-router/unstable-native-tabs for platform-native
// tab bar rendering. On iOS 26+ this automatically gets the
// Liquid Glass material via the system UITabBarController.
// iOS native tab bar layout.
//
// Removed: custom JS tab bar, expo-glass-tabs, expo-blur
// dependency for the tab bar, expo-glass-effect for tab bar.
// §4.2: 底栏滚动收纳由 minimizeBehavior=onScrollDown 原生驱动（iOS 26+ 药丸收纳
// 动画）：下滑收纳、上滑恢复，动画由 UIKit 原生药丸收纳控制，滚动观察交给 UIKit。
// ============================================================

import { DeviceEventEmitter } from 'react-native';
import { useEffect, useRef } from 'react';
import { DarkTheme, DefaultTheme, ThemeProvider, usePathname, useRouter } from 'expo-router';
import { NativeTabs } from 'expo-router/unstable-native-tabs';

import { useThemeColors } from '@/theme/ThemeContext';
import { useNotificationStore } from '@/stores/notificationStore';
import { usePreferencesStore } from '@/stores/preferencesStore';
import { useAppPreference } from '@/hooks/useAppPreference';
import { hapticForScene } from '@/theme/hapticsMap';
import { TAB_RESELECT_EVENT } from '@/constants/events';

// ── Main Tab Layout ──
export default function TabLayout() {
  const { colors, isDark } = useThemeColors();
  const pathname = usePathname();
  const totalUnread = useNotificationStore((s) => s.counts.total);
  // 底栏滚动收纳开关（设置→使用习惯→浏览；关闭=常驻）
  const tabBarMinimizeEnabled = useAppPreference('tabBarMinimizeEnabled', true);

  // 正常切 tab 的选择触觉（重复点击同 tab 走下方 reselect 的 press，不重复）。
  // 首挂载不震；pathname 变化即 tab 切换（含深链直达），统一 selection 档。
  const lastTabPathRef = useRef<string | null>(null);
  // 仅「tab 路由 ↔ tab 路由」的 pathname 变化才算 tab 切换并播 segment 触觉。
  // push/pop（进帖/进设置/返回）同样改 pathname，不能借此播触觉——否则每次
  // 导航都多振一下：「返回上一级之后又振动一次」的系统根因（真机实测
  // 2026-08-27：返回键自身触觉尚在去重窗口内，第二振全来自这里）。
  const isTabPath = (p: string) => ['/', '/explore', '/notifications', '/profile'].includes(p === '' ? '/' : p);
  useEffect(() => {
    const prev = lastTabPathRef.current;
    lastTabPathRef.current = pathname;
    if (prev === null) return; // 首挂载不震
    if (prev === pathname) return;
    if (isTabPath(prev) && isTabPath(pathname)) {
      void hapticForScene('segment');
    }
  }, [pathname]);

  // ── 启动默认页（设置→使用习惯→首页）：水合完成后的首个导航周期，
  // 若仍停在初始关注页则一次性 replace 到偏好页。深链/通知直达
  // （pathname 非 '/'）不干预。
  const router = useRouter();
  const startTab = useAppPreference('startTab', 'index');
  const startAppliedRef = useRef(false);
  useEffect(() => {
    if (startAppliedRef.current) return;
    if (!usePreferencesStore.getState().hasHydrated) return;
    startAppliedRef.current = true;
    const target = startTab ?? 'index';
    if (target !== 'index' && (pathname === '/' || pathname === '')) {
      const route = target === 'explore' ? '/explore' : target === 'notifications' ? '/notifications' : '/profile';
      router.replace(route);
    }
  }, [pathname, startTab, router]);

  // NativeTabs.Trigger exposes a tabPress listener. Emit only when the tapped
  // tab is already focused AND tapped twice within the double-tap window —
  // 单击已聚焦 tab 静默（2026-08-27 用户要求：单击不动作，双击回顶+刷新，
  // 与顶栏双击回顶同语义；原实现单击即触发 reselect，表现为"单击回顶"）。
  const DOUBLE_TAP_WINDOW_MS = 400;
  const lastTabTapRef = useRef<Record<string, number>>({});
  const handleTabReselect = (tabName: string, tabPath: string) => {
    if (pathname === tabPath || (tabPath === '/' && (pathname === '' || pathname === '/'))) {
      const now = Date.now();
      const lastTap = lastTabTapRef.current[tabName] ?? 0;
      lastTabTapRef.current[tabName] = now;
      if (now - lastTap > DOUBLE_TAP_WINDOW_MS) return; // 单击不动作
      hapticForScene('press');
      lastTabTapRef.current[tabName] = 0; // 双击只触发一次
      DeviceEventEmitter.emit(TAB_RESELECT_EVENT, tabName);
    }
  };

  // §2.1 NOTE: The user preference to hide the Explore tab (previously
  // stored in AsyncStorage as '@tiebalite:pref_hideExplore') is no longer
  // applied here. Dynamically adding/removing NativeTabs.Trigger at runtime
  // causes a full remount and state loss (per official docs). All tabs must
  // be rendered statically. If hiding Explore is required in the future,
  // consider a config-plugin-level approach or a separate layout.

  return (
    // 使用应用自身的 isDark（而非系统 useColorScheme）驱动 react-navigation
    // ThemeProvider，使 tab 标签/图标配色与应用内容主题一致——应用"强制深色 +
    // 系统浅色"时不再出现 tab 亮色标签配深色内容页的脱节。
    <ThemeProvider value={isDark ? DarkTheme : DefaultTheme}>
      {/* §2.4: ThemeProvider prevents white background flash and liquid
          glass flicker on iOS 26 dark mode. */}
      <NativeTabs
          // §4.2: onScrollDown —— 下滑收纳 / 上滑恢复，动画由 UIKit 原生药丸收纳
          // 控制；滚动观察交给 UIKit。收纳开关在 设置→使用习惯→浏览
          //（tabBarMinimizeEnabled），关闭时 never = 底栏常驻。
          minimizeBehavior={tabBarMinimizeEnabled ? 'onScrollDown' : 'never'}
          // ⚠️ 不要传 backgroundColor：react-native-screens 的
          // RNSTabBarAppearanceCoordinator 只要发现 tabBarBackgroundColor != nil
          // 就会强制写 tabBarAppearance.backgroundColor（连 'transparent' 也会
          // 覆盖系统玻璃材质）→ 玻璃消失、bar 变纯色。
          //
          // ⚠️ blurEffect / shadowColor 一律不传：任何 bar 级 appearance 写入
          //（backgroundEffect/backgroundColor）都会让 UIKit 退出自动 Liquid Glass
          // 渲染管线，底栏退化成旧磨砂材质（实心色带）。保持 appearance 原生态，
          // 由系统自动渲染真液态玻璃（tieba-native 不再做任何 forceLiquidGlass）。
          //
          // 滚动隐藏交给 minimizeBehavior；不使用 NativeTabs 的 hidden prop
          //（那是 setTabBarHidden:animated:NO 瞬移，无动画）。
          // Tint color for selected tab icon + label.
          // §4.14: This is the opaque selection accent (solid `colors.primary`,
          // no alpha channel), NOT a translucent glass fill — so it must stay
          // fully opaque for the selected tab to remain legible.
          tintColor={colors.primary}
          // Label styling
          labelStyle={{
            fontSize: 10,
            fontWeight: '600',
          }}
        >
          {/* 关注 (Home / Feed) */}
          <NativeTabs.Trigger
            name="index"
            listeners={{
              tabPress: () => handleTabReselect('index', '/'),
            }}
          >
            <NativeTabs.Trigger.Icon
              sf={{ default: 'house', selected: 'house.fill' }}
              md={{ default: 'home', selected: 'home_filled' }}
            />
            <NativeTabs.Trigger.Label>关注</NativeTabs.Trigger.Label>
          </NativeTabs.Trigger>

          {/* 动态 (Explore) — always rendered statically (§2.1) */}
          <NativeTabs.Trigger
            name="explore"
            listeners={{
              tabPress: () => handleTabReselect('explore', '/explore'),
            }}
          >
            <NativeTabs.Trigger.Icon
              sf={{ default: 'safari', selected: 'safari.fill' }}
              md={{ default: 'explore', selected: 'explore' }}
            />
            <NativeTabs.Trigger.Label>动态</NativeTabs.Trigger.Label>
          </NativeTabs.Trigger>

          {/* 消息 (Notifications) */}
          <NativeTabs.Trigger
            name="notifications"
            listeners={{
              tabPress: () => handleTabReselect('notifications', '/notifications'),
            }}
          >
            <NativeTabs.Trigger.Icon
              sf={{ default: 'bell', selected: 'bell.fill' }}
              md={{ default: 'notifications', selected: 'notifications' }}
            />
            <NativeTabs.Trigger.Label>消息</NativeTabs.Trigger.Label>
            {/* §4.1: Notification badge showing unread count */}
            {totalUnread > 0 && (
              <NativeTabs.Trigger.Badge>
                {totalUnread > 99 ? '99+' : String(totalUnread)}
              </NativeTabs.Trigger.Badge>
            )}
          </NativeTabs.Trigger>

          {/* 我的 (Profile) */}
          <NativeTabs.Trigger
            name="profile"
            listeners={{
              tabPress: () => handleTabReselect('profile', '/profile'),
            }}
          >
            <NativeTabs.Trigger.Icon
              sf={{ default: 'person', selected: 'person.fill' }}
              md={{ default: 'person', selected: 'person' }}
            />
            <NativeTabs.Trigger.Label>我的</NativeTabs.Trigger.Label>
          </NativeTabs.Trigger>
      </NativeTabs>
    </ThemeProvider>
  );
}
