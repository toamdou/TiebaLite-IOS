import '@/services/devNoiseFilter'; // 必须最先执行：过滤 expo-notifications Keychain 已知噪声（见文件头注释）
import React, { useEffect, useCallback, useMemo } from 'react';
import { View, Pressable, Appearance } from 'react-native';
import { Text } from '../components/ui/CompatText';
import { Stack, useRouter } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { enableFreeze } from 'react-native-screens';
import { GestureHandlerRootView } from 'react-native-gesture-handler';

import * as SplashScreen from 'expo-splash-screen';
import * as Linking from 'expo-linking';
import * as Notifications from 'expo-notifications';
import * as SystemUI from 'expo-system-ui';
import { Image } from 'expo-image';
import { applyCacheMaxSize, maybeAutoCleanCache } from '@/services/cache/cacheMaintenance';
import { TiebaNative } from '../../modules/tieba-native/src/TiebaNative';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { SafeAreaProvider, initialWindowMetrics } from 'react-native-safe-area-context';

// 模拟器上 expo-notifications 读 Keychain 注册信息偶尔失败的已知无害噪声
// （ERR_NOTIFICATIONS_KEYCHAIN_ACCESS，仅影响推送注册缓存，不影响功能）：
// 加入 LogBox 忽略列表，避免每次启动/轮询都弹开发告警遮挡调试。
if (__DEV__) {
  require('react-native').LogBox.ignoreLogs([
    /Error reading persisted server registration info/,
    /ERR_NOTIFICATIONS_KEYCHAIN_ACCESS/,
  ]);
}

import { ThemeProvider, useThemeColors } from '@/theme/ThemeContext';
import { getThemeColors } from '@/theme/colors';
import { ToastHost } from '@/components/ui/Toast';
import { usePreferencesStore } from '@/stores/preferencesStore';
import { LIGHT_THEME_OPTIONS, DARK_THEME_OPTIONS } from '@/constants/app';

import { useAuthStore } from '@/stores/authStore';
import { useAppLockStore } from '@/stores/appLockStore';
import { AppLockGate } from '@/components/AppLockGate';
import {
  installHapticEngineLifecycle,
  stopAllHapticsSafe,
} from '@/utils/haptics';
import { useAppPreference } from '@/hooks/useAppPreference';
import { useClipboardDetector } from '@/hooks/useClipboardDetector';
import { ensureUnifiedStorageReady } from '@/services/storage/unifiedDb';
import { extractThreadId, extractForumName } from '@/utils';

// ⚠️ 启动热路径：api/endpoints（接口 barrel）、interceptors、
// NotificationPoller、BackgroundSignService、liveActivity、ClipboardLinkDialog、
// accountCache、AuthSQLiteStorage、forumFollowed、api/config、tieba-system
// 一律延迟到使用点 dynamic import —— 这些模块图不需要在 splash 前执行，
// 把它们从首帧模块图里摘掉可显著缩短 Hermes 模块执行时间。
// devNoiseFilter 必须保持第一行 import（过滤基建最先执行）。
// 注：client.ts 传输层已为 nitro-fetch（原生 URLSession），包本体在
// client.ts 内惰性 require，不随本文件首帧执行。

// SDK 57 性能优化：非活动屏幕冻结渲染
enableFreeze(true);

// 全局 JS 错误兜底：render 错误由下方 ErrorBoundary 接住，但事件回调 /
// 定时器 / Promise 链里的未捕获异常会直接闪退且无任何痕迹。这里注册
// 全局 handler 记录（并避免 RN 默认的红屏在 dev 之外直接崩进程）。
{
  const g = globalThis as unknown as {
    ErrorUtils?: { setGlobalHandler?: (handler: (error: Error, isFatal?: boolean) => void) => void };
  };
  // Release 构建的 JS 错误落盘限频：会话级最多 20 条，防错误风暴写爆磁盘。
  // 模块经 dynamic import 惰性加载（不进首帧图）；appendJsError 内部对
  // 旧二进制/Debug 原生均有兜底，永不抛错。
  let jsErrorsLogged = 0;
  g.ErrorUtils?.setGlobalHandler?.((error: Error, isFatal?: boolean) => {
    const summary = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
    console.warn(`[GlobalError] fatal=${isFatal} ${summary}`);
    if (!__DEV__ && jsErrorsLogged < 20) {
      jsErrorsLogged += 1;
      const stackHead = error instanceof Error
        ? (error.stack ?? '').split('\n').slice(0, 5).join(' | ')
        : '';
      void import('../../modules/tieba-system/src')
        .then((m) => m.appendJsError(`fatal=${isFatal ? 1 : 0} ${summary}${stackHead ? ` @ ${stackHead}` : ''}`))
        .catch(() => {});
    }
  });
}

Notifications.setNotificationHandler({
  handleNotification: async (notification) => {
    const data = notification.request.content.data as Record<string, unknown> | undefined;
    if (data?.type === 'sign_progress') {
      return { shouldShowBanner: false, shouldShowList: true, shouldPlaySound: false, shouldSetBadge: false };
    }
    return { shouldShowBanner: true, shouldShowList: true, shouldPlaySound: true, shouldSetBadge: true };
  },
  // Docs §setNotificationHandler: handler must respond within 3s or the
  // notification is discarded — surface failures instead of failing silently.
  handleError: (notificationId, error) => {
    console.warn(`[Notifications] Failed to handle notification ${notificationId}:`, error);
  },
});

SplashScreen.preventAutoHideAsync().catch(() => {});
// 收起时交叉溶解而非硬切（iOS）；280ms 与首页首帧内容渐入衔接
SplashScreen.setOptions({ fade: true, duration: 280 });

// expo-system-ui: 在组件树之外设置根视图背景色（避免启动白屏闪烁）。
// 启动阶段没有 React Context，这里同步镜像 ThemeContext 的主题解析逻辑，
// 用当前偏好 + 系统外观算出启动背景色 —— 暗色用户不会再看到 #F2F2F7 白底。
// 运行时的主题变化仍由 RootLayoutInner 的 effect 同步（见下）。
function resolveStartupBackgroundColor(): string {
  const prefs = usePreferencesStore.getState().preferences;
  const systemIsDark = Appearance.getColorScheme() === 'dark';
  const isDark = prefs.followSystemDarkMode ? systemIsDark : prefs.darkMode;
  const lightThemes = new Set(LIGHT_THEME_OPTIONS.map((t) => t.key));
  const darkThemes = new Set(DARK_THEME_OPTIONS.map((t) => t.key));
  const lightTheme = lightThemes.has(prefs.lightTheme) ? prefs.lightTheme : 'tieba';
  const darkTheme = darkThemes.has(prefs.darkTheme) ? prefs.darkTheme : 'dark';
  const effectiveTheme = isDark ? darkTheme : lightTheme;
  return getThemeColors(effectiveTheme, prefs.customPrimaryColor, isDark).background;
}
SystemUI.setBackgroundColorAsync(resolveStartupBackgroundColor()).catch(() => {});

const queryClient = new QueryClient({
  defaultOptions: { queries: { retry: 1, staleTime: 15 * 1000, gcTime: 30 * 1000 }, mutations: { retry: 0 } },
});

// Global error boundary — catches render errors in the app tree and shows a
// fallback UI with a retry button instead of a hard crash. Retry remounts the
// subtree via a changing key so stale render state cannot survive.

// ErrorBoundary 是 class 组件，无法直接使用 useThemeColors Hook；
// 兜底 UI 作为独立函数组件渲染，在 ThemeProvider 内读取 colors.text，
// 保证深色模式下"出错了/重试"文字可见。
function ErrorFallback({ onRetry }: { onRetry: () => void }) {
  const { colors } = useThemeColors();
  return (
    <View style={{ flex: 1, justifyContent: 'center', alignItems: 'center', gap: 12 }}>
      <Text style={{ fontSize: 16, color: colors.text }}>出错了</Text>
      <Pressable onPress={onRetry}>
        <Text style={{ fontSize: 16, fontWeight: '600', color: colors.text }}>重试</Text>
      </Pressable>
    </View>
  );
}

class ErrorBoundary extends React.Component<
  { children: React.ReactNode },
  { hasError: boolean; attempt: number }
> {
  state = { hasError: false, attempt: 0 };
  static getDerivedStateFromError() {
    return { hasError: true };
  }
  componentDidCatch(error: Error, errorInfo: React.ErrorInfo) {
    // Log a sanitized summary only; never include raw render output or
    // component stacks that could embed user content.
    const summary = error instanceof Error ? `${error.name}: ${error.message}` : String(error);
    console.warn('[ErrorBoundary] render error:', summary);
    console.warn('[ErrorBoundary] componentStack length:', errorInfo.componentStack?.length ?? 0);
  }
  handleRetry = () => {
    this.setState((state) => ({ hasError: false, attempt: state.attempt + 1 }));
  };
  render() {
    if (this.state.hasError) {
      // ErrorFallback 是函数组件，可在 ThemeProvider 内读取 useThemeColors，
      // 保证深色模式下兜底文字（colors.text）可见。
      return <ErrorFallback onRetry={this.handleRetry} />;
    }
    return (
      <View key={this.state.attempt} style={{ flex: 1 }}>
        {this.props.children}
      </View>
    );
  }
}

type ScreenDef = { name: string; title: string };

const SCREENS: readonly ScreenDef[] = [
  { name: 'forum/[name]',          title: '' },
  { name: 'forum/[name]/detail',   title: '吧详情' },
  { name: 'forum/[name]/bawu',     title: '吧务团队' },
  { name: 'forum/[name]/members',  title: '吧成员' },
  { name: 'forum/[name]/rules',    title: '吧规' },
  { name: 'forum/[name]/search',   title: '吧内搜索' },
  { name: 'thread/[id]',           title: '' },
  { name: 'thread/[id]/subposts',  title: '楼中楼' },
  { name: 'search/index',          title: '搜索' },
  { name: 'user/[uid]',            title: '' },
  { name: 'history',               title: '浏览记录' },
  { name: 'threadstore',           title: '我的收藏' },
  { name: 'webview',               title: '' },
  { name: 'topic/[id]',            title: '话题' },
  { name: 'settings/index',        title: '设置' },
  { name: 'settings/theme',        title: '个性化' },
  { name: 'settings/account',      title: '账号管理' },
  { name: 'settings/edit-profile', title: '编辑资料' },
  { name: 'settings/block',        title: '屏蔽设置' },
  { name: 'settings/habit',        title: '使用习惯' },
  { name: 'settings/image',        title: '图片与流量' },
  { name: 'settings/oksign',       title: '一键签到设置' },
  { name: 'settings/more',         title: '更多设置' },
  { name: 'settings/logs',         title: '崩溃与卡顿日志' },
  { name: 'settings/about',        title: '关于' },
];

function RootLayoutInner() {
  const { colors, isDark } = useThemeColors();
  const checkAuth = useAuthStore((s) => s.checkAuth);
  const router = useRouter();
  const toolbarPrimaryColor = useAppPreference('toolbarPrimaryColor', false);
  const statusBarFontDark = useAppPreference('statusBarFontDark', false);
  // 震动反馈总开关同步给原生：闸住 chrome 按压触觉（返回钮/导航右钮/底栏项
  // 的 UIImpactFeedbackGenerator 在 swizzle 原生侧，读不到 MMKV 偏好）。
  const hapticFeedback = useAppPreference('hapticFeedback', true);
  useEffect(() => {
    TiebaNative.setHapticFeedbackEnabled(hapticFeedback ?? true);
  }, [hapticFeedback]);
  // headerTint 需随主题明暗自适应：深色模式下导航栏是深色液态玻璃，
  // 勾选"工具栏使用主色调"时若再按 statusBarFontDark 取黑色字会黑字贴深底
  // 不可见，故深色一律用浅色（onNavBarSurface），浅色才尊重 statusBarFontDark。
  const headerTint = toolbarPrimaryColor
    ? (isDark
        ? colors.onNavBarSurface
        : (statusBarFontDark ? '#000' : '#FFF'))
    : colors.text;

  // 主题变化时同步原生根视图背景色（expo-system-ui runtime API）
  useEffect(() => {
    SystemUI.setBackgroundColorAsync(colors.background).catch(() => {});
  }, [colors.background]);

  // 触觉引擎生命周期：安装当下预热，active 预热 / background 销毁（内部有
  // 总开关门控——关闭时引擎也不驻留）
  useEffect(() => {
    installHapticEngineLifecycle();
  }, []);

  // 状态栏字色下发：Info.plist 为 UIViewControllerBasedStatusBarAppearance=true
  // （VC-based），expo-status-bar 的旧式 setStyle 在此模式下是 no-op，状态栏
  // 永远黑字、深色底上时间/信号不可见（2026-08-28 用户反馈）。改用 native-stack
  // 的 statusBarStyle 逐屏下发（screens 走子 VC preferredStatusBarStyle，此模式下才生效）。
  const statusBarStyle: 'light' | 'dark' = toolbarPrimaryColor
    ? (isDark ? 'light' : (statusBarFontDark ? 'dark' : 'light'))
    : (isDark ? 'light' : 'dark');

  const screenOpts = useMemo(() => ({
    gestureEnabled: true,
    statusBarStyle,
    headerTintColor: headerTint,
    headerBackVisible: true,
    // 'default' 会把上一屏标题（如 tabs 页的“(tabs)”）当作返回文字显示；
    // 仅要箭头图标，用 'minimal'（iOS 只画 chevron，不带文字）。
    headerBackButtonDisplayMode: 'minimal' as const,
    // 导航栏材质：headerBlurEffect 经 RNScreens 写 item 级 appearance，配合原生
    // 模块的 bar 级 forceNavBarLiquidGlass（systemMaterial）。注意 expo-router 57
    // 的 native-stack fork 用 headerTransparent 而不是 headerTranslucent 控制
    // translucent（后者被静默忽略）；headerTransparent=true 让内容容器延伸到
    // 导航栏下方（RNSScreenView 从 y=0 起），列表才能从 bar 下滚过、玻璃透出
    // 内容；否则 bar 背后是纯背景色（浅色=白、深色模式=窗白底），看起来
    // "纯色无玻璃"且"深色模式标题栏白色"。
    // ⚠️ iOS 27 实测：item 级 appearance 材质已被 UIKit 弃走（渲染层
    // effect=none），真正让玻璃出现的是 tieba-native 渲染层
    // forceNavBarLiquidGlass + 下方 scrollEdgeEffects hidden。本 prop 仅作
    // 旧系统兜底，排查玻璃问题勿从这里入手。
    headerBlurEffect: 'systemMaterial' as const,
    headerTransparent: true,
    headerShadowVisible: false,
    // 滚动时不附加 scrollEdge 材质（'hidden'）：否则 iOS 27 滚动瞬间系统给
    // bar 加实心背景，玻璃失效（用户实测"滑动时顶栏不透明"）。
    scrollEdgeEffects: {
      top: 'hidden' as const,
      bottom: 'hidden' as const,
      left: 'hidden' as const,
      right: 'hidden' as const,
    },
    headerStyle: { backgroundColor: 'transparent' },
    contentStyle: { backgroundColor: colors.background },
    freezeOnBlur: true,
  }), [headerTint, statusBarStyle, colors.background]);

  useEffect(() => {
    let cancelled = false;
    async function init() {
      // 冷启动关键路径计时（仅 dev Metro 可见）：splash 残留排查用——
      // 各阶段相对 init 起点的毫秒数，定位 hideAsync 前哪一环最慢。
      const bootT0 = Date.now();
      const bootMark = (label: string) => {
        if (__DEV__) console.log(`[boot] ${label} +${Date.now() - bootT0}ms`);
      };
      // 缓存上限由设置驱动（默认 400MB）：套用 expo-image 磁盘/内存上限 +
      // 原生缩略图上限。同步且幂等，不阻塞启动。
      applyCacheMaxSize(usePreferencesStore.getState().preferences.cacheMaxSizeMb ?? 400);
      // 启动顺序：SQLite 打开 + kv 搬运（几十 ms 量级，各迁移有持久化标记，
      // 稳态零扫描）→ 鉴权收敛后再放行 splash。鉴权是本地读取、很快。这样
      // 首屏状态一次到位，不会出现
      // “未登录 → 转圈 → 未登录”的抖动，也远快于旧实现（首屏等全量迁移）。
      try {
        await ensureUnifiedStorageReady().catch(() => {});
        bootMark('storage');
        // 缓存定期自动清理（设置中可选天数）：kv 已就绪，启动时后台检查一次
        void maybeAutoCleanCache().catch(() => {});
      } catch {
        // 存储初始化失败也不阻塞启动：鉴权照常走（checkAuth 内部有兜底）
      }
      // 应用锁解析与鉴权并行：两者都只读本地（Keychain），互不依赖；串行
      // 白付一次 Keychain 往返（splash 残留 1s 排查时收敛进关键路径）。
      const appLockReady = useAppLockStore
        .getState()
        .hydrate()
        .then(() => bootMark('appLock'))
        .catch(() => {});
      // clientId 预热只依赖 kv(MMKV)，与鉴权无依赖且请求方（client.ts）自身
      // 会惰性取值——不阻塞 splash 收起，仅提前触发生成。
      void import('@/services/api/config')
        .then((m) => m.getClientId())
        .then(() => bootMark('clientId'))
        .catch(() => {});
      try {
        // 等鉴权收敛再放行首屏（避免“未登录→转圈→未登录”抖动）。加 1.5s 保险
        // 闸：即使 Keychain/迁移异常卡住，splash 也不无限期占用，随后由内容页
        // 自身的 loading 态兜底（正常路径鉴权几十毫秒完成，闸不生效）。
        await Promise.race([
          checkAuth().then(() => bootMark('auth')),
          new Promise((resolve) => setTimeout(resolve, 1500)),
        ]);
        bootMark('authGate');
      } catch {
        // 鉴权失败仍放行首屏（checkAuth 内部本就有兜底）
      }
      // 首屏内容预热提前到 splash 收起前发起：「1 秒进主页且内容必刷新」由
      // SWR 语义保证——先画缓存/骨架，网络返回即覆盖，不产生过时信息。
      // - 关注吧列表（首页内容）：fetchAllFollowedForums 自带 in-flight 去重，
      //   首页挂载时 useFocusEffect 的重复调用直接复用同一 Promise；
      // - 推荐流（动态页首屏 seed）：warmHomeFeed 幂等 + 超时守卫。
      const bootState = useAuthStore.getState();
      if (bootState.isLoggedIn) {
        void import('@/services/forumFollowed').then((m) => m.fetchAllFollowedForums()).catch(() => {});
      }
      void import('@/services/api/endpoints/feed').then((m) => m.warmHomeFeed()).catch(() => {});
      if (!cancelled) {
        // 应用锁与 splash 解耦并行（2026-08-28）：splash 不再等 Keychain
        // 标志解析（appLockReady）——dev 下 SecureStore 读会被 Metro 按需
        // 打包排队拖到 ~2.9s，splash 等它等于白白多等 1.4s。改成立即收起、
        // appLockReady 完成后同步补锁：lock() 走原生遮罩同步立现（内部
        // syncShieldUnlocked(false) 同步下发），即使 hydrate 稍晚完成，锁面
        // 也会在内容露出的当帧盖住，不闪内容帧；未开启/读取失败（已兜底）
        // 则完全无感。
        try { await SplashScreen.hideAsync(); bootMark('splashHidden'); } catch {}
        void appLockReady.then(() => {
          if (cancelled) return;
          if (useAppLockStore.getState().enabled) useAppLockStore.getState().lock();
        });
      }
      void import('@/services/sign/BackgroundSignService')
        .then((m) => m.ensureAutoSignScheduled())
        .catch(() => {});
      const state = useAuthStore.getState();
      if (state.isLoggedIn) {
        try {
          // 登录态刷新链路的模块都不在首帧热路径，这里汇聚成一次动态加载
          // （catch 分支另用同步 require 取引用，见下）
          const [
            { getUserInfo },
            { saveAccountProfile },
            { saveAccountSync },
          ] = await Promise.all([
            import('@/services/api/endpoints'),
            import('@/services/auth/accountCache'),
            import('@/services/storage/AuthSQLiteStorage'),
          ]);
          const info = await getUserInfo();
          const current = useAuthStore.getState().account;
          if (current && info?.id != null) {
            const next = {
              ...current,
              nameShow: info.nameShow || current.nameShow,
              portrait: info.portrait || current.portrait,
              levelId: info.levelId,
              levelName: info.levelName,
              intro: info.intro || current.intro,
              fansNum: info.fansNum ?? current.fansNum,
              concernNum: info.concernNum ?? current.concernNum,
              postNum: info.postNum ?? current.postNum,
            };
            saveAccountSync(next);
            void saveAccountProfile(next);
            useAuthStore.setState({ account: next });
          }
        } catch (e: any) {
          // catch 作用域看不到 try 内的动态解构：这里用同步 require 从模块
          // 缓存取引用（模块已在 try 中加载，require 是 O(1) 查表）。
          const { TiebaApiError } = require('@/services/api/interceptors') as typeof import('@/services/api/interceptors');
          if (e instanceof TiebaApiError && e.isAuthError) {
            const { clearAuthCredentials } = require('@/services/api/interceptors') as typeof import('@/services/api/interceptors');
            const { stopNotificationPoller, cancelNativeBackgroundSync } = require('@/services/NotificationPoller') as typeof import('@/services/NotificationPoller');
            const { clearAccountProfile } = require('@/services/auth/accountCache') as typeof import('@/services/auth/accountCache');
            const { invalidateFollowedForumsCache } = require('@/services/forumFollowed') as typeof import('@/services/forumFollowed');
            clearAuthCredentials();
            stopNotificationPoller();
            cancelNativeBackgroundSync();
            void clearAccountProfile();
            invalidateFollowedForumsCache();
            useAuthStore.setState({ isLoggedIn: false, account: null, error: '登录已过期，请重新登录' });
          }
        }
      }
    }
    init();
    return () => { cancelled = true; };
  }, [checkAuth]);

  const handleDeepLink = useCallback((url: string | null) => {
    if (!url) return;
    const m = url.match(/tiebalite:\/\/notifications\/(\d+)/) || url.match(/tblite:\/\/notifications\/(\d+)/);
    if (m) { router.push({ pathname: '/(tabs)/notifications', params: { initialTab: parseInt(m[1], 10) } }); return; }
    // 官方贴吧 scheme（Kotlin MainActivityV2.checkIntent 同款）：贴吧 H5 页的
    // "打开APP"按钮在双端都发 com.baidu.tieba://unidispatch/{frs,pb}——
    // /pb?tid= 进帖、/frs?kw= 进吧。Info.plist 已声明同款 scheme 接管。
    if (/^com\.baidu\.tieba:\/\//i.test(url)) {
      try {
        const u = new URL(url);
        const path = u.pathname.toLowerCase();
        if (path === '/pb') {
          const tid = u.searchParams.get('tid');
          if (tid) { router.push(`/thread/${tid}`); return; }
        } else if (path === '/frs') {
          const kw = u.searchParams.get('kw');
          if (kw) { router.push(`/forum/${encodeURIComponent(kw)}`); return; }
        }
      } catch {}
      return;
    }
    const tid = extractThreadId(url); if (tid) { router.push(`/thread/${tid}`); return; }
    const fn = extractForumName(url); if (fn) { router.push(`/forum/${encodeURIComponent(fn)}`); }
  }, [router]);

  useEffect(() => {
    Linking.getInitialURL().then(handleDeepLink).catch(() => {});
    const s1 = Linking.addEventListener('url', (e) => handleDeepLink(e.url));
    (async () => {
      const r = await Notifications.getLastNotificationResponseAsync();
      if (r?.notification.request.content.data?.url) handleDeepLink(r.notification.request.content.data.url as string);
      Notifications.clearLastNotificationResponseAsync();
    })();
    const s2 = Notifications.addNotificationResponseReceivedListener((r) => {
      if (r.notification.request.content.data?.url) handleDeepLink(r.notification.request.content.data.url as string);
    });
    return () => { s1.remove(); s2.remove(); };
  }, [handleDeepLink]);

  // 剪贴板贴吧链接检测：识别到 tieba 帖子/吧链接时弹窗引导打开。hook 内部已做
  // 内容 hash 去重 + 3s 节流 + 卸载守卫（首帧检测 + 原生剪贴板变更事件）；
  // 对话框经 dynamic import 延迟加载，不进首帧模块图。
  // 设置-使用习惯-剪贴板链接识别 可整体关闭（关闭后不读剪贴板、无系统粘贴提示）。
  const clipboardLinkDetection = useAppPreference('clipboardLinkDetection', true);
  const { detectedLink, clearDetectedLink } = useClipboardDetector(clipboardLinkDetection);
  useEffect(() => { if (detectedLink) {
    void import('@/components/ClipboardLinkDialog')
      .then((m) => m.showClipboardLinkDialog(detectedLink, clearDetectedLink))
      .catch(() => {});
  } }, [detectedLink, clearDetectedLink]);
  useEffect(() => {
    // Requests notification permission and starts the foreground poller
    // when notifications are allowed.（延迟加载：轮询模块不参与首帧）
    let disposed = false;
    let stopPoller: (() => void) | undefined;
    void import('@/services/NotificationPoller')
      .then((m) => {
        if (disposed) return;
        m.setupNotifications();
        stopPoller = m.stopNotificationPoller;
        return import('@/services/liveActivity').then((la) => la.recoverStaleSignLiveActivities());
      })
      .catch(() => {});
    return () => { disposed = true; stopPoller?.(); };
  }, []);

  // 全局内存警告（iOS）：expo-image 没有内存缓存上限，系统发出低内存
  // 告警时主动清空内存缓存，把解码的原图占用的内存还给系统，避免被
  // watchdog 强杀。卸载时清理监听。（tieba-system 模块延迟加载）
  useEffect(() => {
    let disposed = false;
    let sub: { remove(): void } | null | undefined = undefined;
    void import('../../modules/tieba-system/src')
      .then((m) => {
        if (disposed) return;
        sub = m.onMemoryWarning(() => {
          Image.clearMemoryCache().catch(() => {});
        });
      })
      .catch(() => {});
    return () => { disposed = true; sub?.remove(); };
  }, []);

  return (
    <View
      style={{ flex: 1, backgroundColor: colors.background }}
      onLayout={() => {
        // 首帧布局完成即收起 splash（与 init 链的 hideAsync 幂等竞速）：
        // 旧实现 splash 等 auth/appLock 全链收敛（实测 +800ms），首帧出现后
        // 图标仍盖在主页上（2026-08-28 真机反馈）。首帧时内容页自身渲染
        // 中性 loading 态（isLoading），无「未登录→已登录」闪变。
        // 应用锁开启也照收（不再等 Keychain 解析）：init 链在
        // appLockReady 完成后同步 lock()，原生遮罩立现即覆盖，不闪内容帧。
        SplashScreen.hideAsync().catch(() => {});
      }}
    >
      {/* toolbarPrimaryColor=true 时深色模式一律浅字（白字贴深色导航栏），
          浅色模式才尊重 statusBarFontDark 偏好——与 headerTint 的取色同源。 */}
      <StatusBar style={statusBarStyle} />
      <Stack
        screenOptions={screenOpts}
        screenListeners={{
          // 路由移除时停掉所有在播触觉，防跨页余震（包 README 推荐的全局挂法）
          beforeRemove: () => stopAllHapticsSafe(),
        }}
      >
        {/* (tabs) 作为根栈最底屏：long-press 返回菜单会列出栈内各屏标题
            需要给根屏一个友好 title（否则显示原始路由名“(tabs)”）。 */}
        <Stack.Screen name="(tabs)" options={{ title: '首页', headerShown: false, contentStyle: { backgroundColor: colors.background } }} />
        <Stack.Screen name="login" options={{ title: '登录', presentation: 'formSheet' as const, headerBackVisible: false, sheetGrabberVisible: true, contentStyle: { backgroundColor: colors.background } }} />
        {/* 「更多」formSheet（登录页同款静态声明）：页面内动态 presentation 在
            expo-router 57 fork 不生效（点更多变成 push 进新页） */}
        <Stack.Screen
          name="thread/[id]/more"
          options={{
            presentation: 'formSheet' as const,
            headerShown: false,
            // 固定 detents：贴底 + 可拖拽展开（fitToContents 时 sheet 不贴底、
            // 高度=内容且不可拉伸——用户实测「底部没贴合+空白+拉伸不了」）
            sheetAllowedDetents: [0.3, 0.55, 0.9],
            sheetInitialDetentIndex: 0,
            sheetGrabberVisible: true,
            sheetCornerRadius: 28,
            contentStyle: { backgroundColor: colors.background },
          }}
        />
        <Stack.Screen
          name="forum/[name]"
          options={{
            title: '',
            gestureEnabled: true,
            fullScreenGestureEnabled: true,
          }}
          dangerouslySingular={(segment) => segment}
        />
        <Stack.Screen
          name="thread/[id]"
          options={{
            title: '',
            gestureEnabled: true,
            // 返回空白实验（2026-08-25）：从楼中楼 pop 回帖子页整页空白。
            // 已排除：JS 数据/状态在 push/pop 间稳定（thread 页无 focus 逻辑、
            // 无重拉取）、常驻 overlay（Toast/ImageViewer 隐藏时均 null）、
            // 正下方一屏不被冻结（fork shouldFreeze 豁免 isBelowFocused）。
            // 剩 native-stack 重新展示层；先按社区标准方案关掉本组屏幕的
            // freezeOnBlur（消除挂起-恢复环节），不行再试 gestureEnabled/
            // animation 降级交互式返回。
            freezeOnBlur: false,
          }}
        />
        {/* 楼中楼 — 全屏 push 页面 */}
        <Stack.Screen
          name="thread/[id]/subposts"
          options={{
            title: '楼中楼',
            gestureEnabled: true,
            freezeOnBlur: false,
          }}
          dangerouslySingular={(segment) => segment}
        />
        {SCREENS.filter((s) => !['forum/[name]', 'thread/[id]', 'thread/[id]/subposts'].includes(s.name)).map((s) => (
          <Stack.Screen key={s.name} name={s.name} options={{ title: s.title }} />
        ))}
      </Stack>
    </View>
  );
}

export default function RootLayout() {
  return (
    <GestureHandlerRootView style={{ flex: 1 }}>
      {/* SafeAreaContext.md §Optimization: initialMetrics skips the async
          bridge delay on first render. Provider never remounts here. */}
      <SafeAreaProvider initialMetrics={initialWindowMetrics}>
        <QueryClientProvider client={queryClient}>
          <ThemeProvider>
            <ErrorBoundary>
              <RootLayoutInner />
              {/* 全局底部药丸提示（保存成功等轻量反馈） */}
              <ToastHost />
              {/* 应用锁覆盖层：必须挂在最后，锁定时盖住全部内容并拦截触摸 */}
              <AppLockGate />
            </ErrorBoundary>
          </ThemeProvider>
        </QueryClientProvider>
      </SafeAreaProvider>
    </GestureHandlerRootView>
  );
}
