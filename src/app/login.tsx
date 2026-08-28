/**
 * WebView-based Login Page (aligned with Kotlin LoginPage.kt + AccountUtil.fetchAccountFlow)
 *
 * Flow:
 * 1. WebView loads wappass.baidu.com passport
 * 2. User logs in within WebView
 * 3. Redirect to tieba.baidu.com detected
 * 4. 🔑 Native module reads BDUSS/STOKEN from iOS cookie storage
 *    — mirrors Kotlin's CookieManager.getInstance().getCookie(url) → parseCookie()
 * 5. RN 端调用 fetchAccountLogin()（对齐 Kotlin fetchAccountFlow 的 RN 侧实现：
 *    user 信息 GET /c/s/u?cmd=newuserinfo；tbs 缺失时用 /c/s/login 解析
 *    （fetchTbs，anti.tbs 与 Kotlin 同源）；nameShow 走 /c/s/initNickname）
 * 6. Complete Account stored in SQLite + native Cookie store (bduss, sToken, cookie, zid all populated)
 * 7. setAuthCredentials() called → all subsequent API requests carry BDUSS/STOKEN
 */

import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import {
  View, StyleSheet, Alert,
} from 'react-native';
import { Stack, router } from 'expo-router';
import { WebView } from 'react-native-webview';
import type { WebViewNavigation } from 'react-native-webview';
import {
  Button, Label, VStack, HStack, Spacer, Text, Image,
  ProgressView, Divider, ContentUnavailableView,
} from '@expo/ui/swift-ui';
import {
  buttonStyle, controlSize, frame, tint,
  font, foregroundStyle, padding,
} from '@expo/ui/swift-ui/modifiers';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { SymbolView } from '@/components/ui/SymbolView';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { hapticForScene } from '@/theme/hapticsMap';
import { useAppTheme } from '@/theme/ThemeContext';
import { Spacing } from '@/theme';
import type { SemanticColors } from '@/theme';
import { useAuthStore } from '@/stores/authStore';
import { getNativeCookies } from '@/services/cookies/CookieService';
import { setAuthCredentials } from '@/services/api/interceptors';
import { fetchAccountLogin } from '@/services/api/endpoints/auth';
// 可信域名清单收敛到 constants/webViewHosts（thermo Z5-C，内置浏览器同源）
import { LOGIN_TRUSTED_HOSTS, isTrustedHost } from '@/constants/webViewHosts';

/** Baidu passport → redirects to tieba after successful login */
const LOGIN_URL =
  'https://wappass.baidu.com/passport?login&u=https%3A%2F%2Ftieba.baidu.com%2Findex%2Ftbwise%2Fmine';

const isTrustedLoginUrl = (rawUrl: string): boolean => isTrustedHost(rawUrl, LOGIN_TRUSTED_HOSTS);

/** Maximum wait time for login */
const TIMEOUT_MS = 60000;

// 账号信息获取已下沉到 services/api/endpoints/auth.ts 的 fetchAccountLogin()
// （对齐 Kotlin AccountUtil.fetchAccountFlow；2026-08-25 收敛自本文件的手抄实现）。

/** 全屏状态遮罩：absolute 铺满 + SwiftUI 垂直居中骨架（loading/extracting/success/error 共用）。 */
function FullscreenOverlay({
  colors,
  spacing = 12,
  background = false,
  children,
}: {
  colors: SemanticColors;
  spacing?: number;
  background?: boolean;
  children: ReactNode;
}) {
  return (
    <ThemedHost
      style={[styles.overlay, background ? { backgroundColor: colors.windowBackground } : undefined]}
    >
      <VStack
        alignment="center"
        spacing={spacing}
        modifiers={[frame({ maxWidth: 10000, maxHeight: 10000 })]}
      >
        <Spacer />
        {children}
        <Spacer />
      </VStack>
    </ThemedHost>
  );
}

type LoadingState = 'loading' | 'extracting' | 'success' | 'error' | null;

export default function LoginPage() {
  const { colors } = useAppTheme();
  const { login } = useAuthStore();

  const webViewRef = useRef<WebView>(null);
  const loginProcessedRef = useRef(false);
  // 用 ref 记录 loadingState，避免 handleNavigationStateChange 闭包在
  // loadingState 变化时被反复重建（进而导致 onNavigationStateChange 重绑定 / overlay 闪烁）。
  const loadingStateRef = useRef<LoadingState>('loading');

  const [loadingState, setLoadingState] = useState<LoadingState>('loading');
  const [error, setError] = useState<string | null>(null);
  const [showWebView, setShowWebView] = useState(false);

  const updateLoadingState = useCallback((next: LoadingState) => {
    loadingStateRef.current = next;
    setLoadingState(next);
  }, []);

  // ---------- Auto-dismiss after success ----------
  useEffect(() => {
    if (loadingState === 'success') {
      const timer = setTimeout(() => {
        if (router.canGoBack()) {
          router.back();
        } else {
          router.replace('/(tabs)/profile');
        }
      }, 1500);
      return () => clearTimeout(timer);
    }
  }, [loadingState]);

  // ---------- Login timeout ----------
  useEffect(() => {
    if (loadingStateRef.current !== 'loading' && loadingStateRef.current !== null) return;
    const timeout = setTimeout(() => {
      if (!loginProcessedRef.current) {
        updateLoadingState('error');
        setError('登录超时，请在页面中完成百度账号登录后重试');
        hapticForScene('action-fail');
      }
    }, TIMEOUT_MS);
    return () => clearTimeout(timeout);
  }, [loadingState, updateLoadingState]);

  // ---------- Show WebView after short delay ----------
  useEffect(() => {
    const timer = setTimeout(() => setShowWebView(true), 300);
    return () => clearTimeout(timer);
  }, []);

  // ---------- Handle WebView navigation (detects redirect to tieba = login complete) ----------
  //
  // 对齐 Kotlin LoginWebViewClient.shouldOverrideUrlLoading():
  //   检测到贴吧重定向 → CookieManager.getCookie(url) → parse BDUSS/STOKEN
  //   → fetchAccountFlow(bduss, sToken, cookie)
  // 只保留 IPA / dev-client 原生 Cookie 读取路径，RN 端调 API（完全对齐 Kotlin）。
  const handleNavigationStateChange = useCallback(
    async (navState: WebViewNavigation) => {
      const url = navState.url;

      // Detect redirect to tieba after successful Baidu passport login
      if (
        !loginProcessedRef.current &&
        (url.startsWith('https://tieba.baidu.com/index/tbwise/') ||
         url.startsWith('https://tiebac.baidu.com/index/tbwise/'))
      ) {
        loginProcessedRef.current = true;
        updateLoadingState('extracting');
        hapticForScene('press');

        // 轮询等待原生 Cookie 同步（sharedCookiesEnabled → NSHTTPCookieStorage）：
        // BDUSS 随通行证重定向立即下发，STOKEN 随贴吧落地页 Set-Cookie 到达，
        // 两者异步不同步——只等 BDUSS 会拿到缺 STOKEN 的半成品（/c/s/login 与
        // proto 均回 110001"未知错误"，2026-08-27 三路全挂的一致症状）。
        // 必须两键齐备（上限 6s）；STOKEN 始终不来=百度未完成凭据下发，直接报错，
        // 不再发起任何 API 调用（无谓请求与封号风险的来源）。
        let nativeCookies = await getNativeCookies('https://tieba.baidu.com');
        let cookieTries = 0;
        while (cookieTries < 40 && !(nativeCookies.BDUSS && nativeCookies.STOKEN)) {
          await new Promise((r) => setTimeout(r, 150));
          nativeCookies = await getNativeCookies('https://tieba.baidu.com');
          cookieTries += 1;
        }
        const nativeBduss = nativeCookies.BDUSS || '';
        const nativeStoken = nativeCookies.STOKEN || '';
        if (__DEV__) {
          // 一次登录的凭据诊断：BDUSS 缺失=WebView Cookie 同步问题（非 API 侧）；
          // STOKEN 缺失=落地页 Set-Cookie 未及时到达（索 6s 轮询已耗尽）。
          console.warn(
            `[login] cookies from tieba.baidu.com: BDUSS=${nativeBduss ? 'YES' : 'NO'} STOKEN=${nativeStoken ? 'YES' : 'NO'} (tries=${cookieTries}, keys=${Object.keys(nativeCookies).join(',')})`,
          );
        }

        if (nativeBduss && nativeStoken) {
          try {
            // 设置凭据使后续 API 调用携带 BDUSS/STOKEN
            // （对齐 Kotlin: interceptor 自动注入 CommonParam + Cookie header）
            setAuthCredentials(nativeBduss, nativeStoken);

            // 调用 RN 端 API 获取账号信息（对齐 Kotlin fetchAccountFlow）
            const accountData = await fetchAccountLogin(nativeBduss, nativeStoken);

            const cookieStr = Object.entries(nativeCookies)
              .map(([k, v]) => `${k}=${v}`)
              .join('; ');
            const nativeZid =
              nativeCookies.BAIDUZID ||
              nativeCookies.ZID ||
              nativeCookies.BAIDUID ||
              '';
            await login({
              uid: accountData.uid,
              name: accountData.name,
              nameShow: accountData.nameShow,
              portrait: accountData.portrait,
              tbs: accountData.tbs,
              bduss: nativeBduss,
              sToken: nativeStoken,
              cookie: cookieStr,
              zid: nativeZid,
            });

            hapticForScene('action-success');
            updateLoadingState('success');
            return;
          } catch (e: any) {
            updateLoadingState('error');
            setError(
              e?.message
                ? `登录信息提取失败：${e.message}`
                : '登录信息提取失败，请重试。',
            );
            hapticForScene('action-fail');
            loginProcessedRef.current = false;
          }
        } else if (!nativeBduss) {
          updateLoadingState('error');
          setError(
            '无法读取登录凭据（BDUSS）。\n\n' +
            '请在开发构建中登录，或确认系统 Cookie 已写入。',
          );
          hapticForScene('action-fail');
          loginProcessedRef.current = false;
        } else {
          // BDUSS 已有但 STOKEN 迟迟不到：百度凭据未下发完整。继续调 API
          // 必然全路 110001 且徒增风控暴露，这里直接本地失败（Kotlin 侧
          // loginFlow 的 stoken 也是必填，同判据）。
          updateLoadingState('error');
          setError(
            '登录凭据不完整（已取得 BDUSS，STOKEN 未下发）。\n\n' +
            '请重新登录一次；若仍复现，把 Metro 里 [login] 开头的日志发给开发者。',
          );
          hapticForScene('action-fail');
          loginProcessedRef.current = false;
        }
      } else if (loadingStateRef.current === 'loading' && url.includes('passport.baidu.com')) {
        // Baidu passport loaded — hide loading spinner
        updateLoadingState(null);
      }
    },
    [login, updateLoadingState],
  );

  // ---------- Hide loading spinner when WebView first loads ----------
  const handleLoadEnd = useCallback(() => {
    if (loadingStateRef.current === 'loading') {
      updateLoadingState(null);
    }
  }, [updateLoadingState]);

  // ---------- WebView error ----------
  const handleWebViewError = useCallback(() => {
    if (!loginProcessedRef.current) {
      updateLoadingState('error');
      setError('页面加载失败，请检查网络连接后重试');
    }
  }, [updateLoadingState]);

  // ---------- Help ----------
  const handleHelp = useCallback(() => {
    Alert.alert(
      '登录帮助',
      '1. 在页面中输入你的百度账号和密码\n' +
        '2. 如需验证，请按页面提示完成\n' +
        '3. 登录成功后会自动跳转至贴吧\n' +
        '4. 应用将自动获取用户信息\n\n' +
        '如自动获取失败，可能是百度安全策略所致。\n' +
        '建议重新尝试或检查网络连接。',
      [{ text: '知道了', style: 'cancel' }],
    );
  }, []);

  // ---------- Retry ----------
  const handleRetry = useCallback(() => {
    loginProcessedRef.current = false;
    updateLoadingState('loading');
    setError(null);
    webViewRef.current?.reload();
  }, [updateLoadingState]);

  // ---------- Close ----------
  const handleClose = useCallback(() => {
    router.back();
  }, []);

  return (
    <View style={{ flex: 1, backgroundColor: colors.windowBackground }}>
      <Stack.Screen
        options={{
          title: '登录百度账号',
          headerTransparent: true,
          headerShadowVisible: false,
          headerTintColor: colors.text,
          // 关闭入口：左上角 xmark（用户要求显式关闭钮）+ formSheet 抓条手势
          //（_layout.tsx 已设 sheetGrabberVisible: true + headerBackVisible: false）。
          headerLeft: () => (
            <HdrPressable
              onPress={handleClose}
              style={styles.headerIconBtn}
              flashRadius={11}
              accessibilityLabel="关闭登录"
              accessibilityRole="button"
            >
              <SymbolView
                name="xmark"
                size={22}
                weight="medium"
                tintColor={colors.textSecondary}
              />
            </HdrPressable>
          ),
          headerRight: () => (
            <HdrPressable
              onPress={handleHelp}
              style={styles.headerIconBtn}
              flashRadius={11}
              accessibilityLabel="登录帮助"
              accessibilityRole="button"
            >
              <SymbolView
                name="questionmark.circle"
                size={22}
                weight="medium"
                tintColor={colors.primary}
              />
            </HdrPressable>
          ),
        }}
      />

      {/* Loading Overlay — 原生 SwiftUI ProgressView（WebView 此时 opacity 0，
          无需 scrim 遮罩，居中指示器即系统观感） */}
      {loadingState === 'loading' && (
        <FullscreenOverlay colors={colors}>
          <ProgressView />
          <Text modifiers={[font({ textStyle: 'subheadline' }), foregroundStyle({ type: 'hierarchical', style: 'secondary' })]}>
            正在加载登录页面...
          </Text>
        </FullscreenOverlay>
      )}

      {/* Extracting Overlay */}
      {loadingState === 'extracting' && (
        <FullscreenOverlay colors={colors}>
          <ProgressView />
          <Text modifiers={[font({ textStyle: 'subheadline' }), foregroundStyle({ type: 'hierarchical', style: 'secondary' })]}>
            正在获取用户信息...
          </Text>
        </FullscreenOverlay>
      )}

      {/* Success Overlay — 原生 SF Symbol 成功态 */}
      {loadingState === 'success' && (
        <FullscreenOverlay colors={colors}>
          <Image systemName="checkmark.circle.fill" size={56} color={colors.success} />
          <Text modifiers={[font({ textStyle: 'title3', weight: 'semibold' })]}>登录成功</Text>
        </FullscreenOverlay>
      )}

      {/* Error State — ContentUnavailableView + 系统按钮，全原生错误页 */}
      {loadingState === 'error' && (
        <FullscreenOverlay colors={colors} spacing={16} background>
          <ContentUnavailableView
            title="登录失败"
            description={error || '请确认页面中已成功登录百度账号'}
            systemImage="exclamationmark.triangle"
          />
          <Button
            onPress={handleRetry}
            modifiers={[buttonStyle('borderedProminent'), controlSize('large'), tint(colors.primary), frame({ maxWidth: 9999 })]}
          >
            <Label title="重新加载" systemImage="arrow.clockwise" />
          </Button>
          <Button
            onPress={handleClose}
            modifiers={[buttonStyle('bordered'), controlSize('large'), frame({ maxWidth: 9999 })]}
          >
            <Label title="返回" />
          </Button>
        </FullscreenOverlay>
      )}

      {/* WebView */}
      {showWebView && (
        <WebView
          ref={webViewRef}
          source={{ uri: LOGIN_URL }}
          style={{
            flex: 1,
            opacity:
              loadingState === 'loading' ||
              loadingState === 'extracting' ||
              loadingState === 'success'
                ? 0
                : 1,
          }}
          javaScriptEnabled
          domStorageEnabled
          sharedCookiesEnabled
          onLoadEnd={handleLoadEnd}
          onError={handleWebViewError}
          onNavigationStateChange={handleNavigationStateChange}
          onShouldStartLoadWithRequest={(request) => isTrustedLoginUrl(request.url)}
          userAgent="Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"
          startInLoadingState={false}
          allowsBackForwardNavigationGestures={false}
        />
      )}

      {/* Security Notice — 原生 SwiftUI 底栏：系统分隔线 + caption 说明文字
           （bottom 加大：formSheet 底部 home indicator 区无 insets，固定让位
           防说明被屏幕底边裁掉——2026-08-27 真机反馈） */}
      <ThemedHost matchContents={{ vertical: true }} style={{ alignSelf: 'stretch' }}>
        <VStack spacing={0} modifiers={[frame({ maxWidth: 10000 })]}>
          <Divider />
          <HStack alignment="center" spacing={8} modifiers={[padding({ horizontal: Spacing.lg, top: Spacing.md, bottom: Spacing.xl })]}>
            <Image systemName="lock.shield.fill" size={14} color={colors.textSecondary} />
            <Text modifiers={[font({ textStyle: 'caption' }), foregroundStyle({ type: 'hierarchical', style: 'secondary' })]}>
              登录凭据仅保存在本机安全存储（Keychain）与 Cookie 存储中，仅用于请求百度接口。
            </Text>
          </HStack>
        </VStack>
      </ThemedHost>
    </View>
  );
}

// ---------- Styles ----------

const styles = StyleSheet.create({
  headerIconBtn: {
    width: 36,
    height: 36,
    justifyContent: 'center',
    alignItems: 'center',
  } as any,
  // 遮罩层：absolute 铺满，SwiftUI 内容在 Host 内用 Spacer 垂直居中
  overlay: {
    position: 'absolute',
    top: 0, left: 0, right: 0, bottom: 0,
    zIndex: 10,
  } as any,
});
