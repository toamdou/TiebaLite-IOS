// CookieService — iOS 原生 Cookie 读取/写入/清除，对齐 Kotlin CookieManager。
// 原生模块不可用时读取静默降级；登录/切换会主动写入 BDUSS/STOKEN，
// 登出会校验清除结果，避免“只清不写”或清除失败被吞掉。

// require() 加载的原生模块无法静态校验类型；按调用点实际用法声明最小句柄
// 契约。模块缺失时（Expo Go 无原生模块）getCookieManager() 返回 null 静默降级。
// `any` 会遮住成员调用错误，这里用显式句柄类型替代。
interface CookieManagerHandle {
  set(
    url: string,
    cookie: {
      name: string;
      value: string;
      domain: string;
      path: string;
      secure: boolean;
      httpOnly: boolean;
      maxAge: number;
    },
    isWkWebView: boolean,
  ): Promise<unknown>;
  get(
    url: string,
    isWkWebView: boolean,
  ): Promise<Record<string, { name?: string; value?: string }> | null | undefined>;
  clearAllStores(): Promise<unknown>;
}

const TIEBA_COOKIE_URL = 'https://tieba.baidu.com/';

let cookieManager: CookieManagerHandle | null = null;
let cookieManagerChecked = false;

function getCookieManager(): CookieManagerHandle | null {
  if (!cookieManagerChecked) {
    cookieManagerChecked = true;
    try {
      // eslint-disable-next-line @typescript-eslint/no-require-imports -- native module is lazy-loaded so Expo Go still falls back without crashing.
      const mod = require('@preeternal/react-native-cookie-manager');
      cookieManager = (mod?.default as CookieManagerHandle | undefined) ?? null;
    } catch {
      cookieManager = null;
    }
  }
  return cookieManager;
}

function sanitizeError(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`;
  return String(error);
}

/** 把已登录账号的 Cookie 同步到 iOS Foundation 与 WKWebView 两个存储。 */
export async function setNativeCookies(
  bduss: string,
  stoken: string,
  cookie?: string,
): Promise<void> {
  const manager = getCookieManager();
  if (!manager) return;

  const entries = new Map<string, string>();
  if (bduss) entries.set('BDUSS', bduss);
  if (stoken) entries.set('STOKEN', stoken);
  if (cookie) {
    for (const part of cookie.split(';')) {
      const eq = part.indexOf('=');
      if (eq <= 0) continue;
      const name = part.slice(0, eq).trim().toUpperCase();
      const value = part.slice(eq + 1).trim();
      if (name && value && !entries.has(name)) {
        entries.set(name, value);
      }
    }
  }

  // 双存储拆分（2026-08-26 内存/冷启动）：Foundation（NSHTTPCookieStorage，
  // URLSession 请求会话）立即写——API 首请求需要；WKWebView 存储首次访问
  // 会拉起 WebContent 进程（~200MB 常驻，真机实测切后台后 +200MB 一次到位），
  // 平时绝不触碰——只在真正要开 WebView（登录页/链接页）前经
  // ensureNativeWkCookies() 补齐。
  const cookieSpecs = [...entries].map(([name, value]) => ({
    name,
    value,
    domain: '.baidu.com',
    path: '/',
    secure: true,
    httpOnly: name === 'BDUSS' || name === 'STOKEN',
    maxAge: 315360000,
  }));
  lastCookieSpecs = cookieSpecs;
  await Promise.all(
    cookieSpecs.map((spec) => manager.set(TIEBA_COOKIE_URL, spec, false)),
  );
}

// 最近一次同步的 cookie 规格缓存：WK 存储只在 WebView 即将加载前补写。
let lastCookieSpecs: { name: string; value: string; domain: string; path: string; secure: boolean; httpOnly: boolean; maxAge: number }[] = [];
let wkCookiesSynced = false;

/** WebView 加载前调用：把当前会话 cookie 补写进 WKWebView 存储（幂等，
 *  只在首次真正需要 WebView 时拉起 WebContent 进程）。 */
export async function ensureNativeWkCookies(): Promise<void> {
  if (wkCookiesSynced || lastCookieSpecs.length === 0) return;
  wkCookiesSynced = true;
  const manager = getCookieManager();
  if (!manager) return;
  try {
    await Promise.all(
      lastCookieSpecs.map((spec) => manager.set(TIEBA_COOKIE_URL, spec, true)),
    );
  } catch {} // WebView 存储写入失败不阻塞页面加载（会话由 Foundation 存储兜底）
}

/** 与 setNativeCookies 同义的便捷命名。 */
export async function syncNativeCookies(
  bduss: string,
  stoken: string,
  cookie?: string,
): Promise<void> {
  return setNativeCookies(bduss, stoken, cookie);
}

function normalizeCookies(
  cookies: Record<string, { name?: string; value?: string }> | null | undefined,
): Record<string, string> {
  const result: Record<string, string> = {};
  if (!cookies) return result;
  for (const [name, cookie] of Object.entries(cookies)) {
    if (cookie && typeof cookie.value === 'string') {
      result[name.toUpperCase()] = cookie.value;
    }
  }
  return result;
}

/**
 * 读取指定 URL 下的 iOS 原生 Cookie。
 * 同时读取 Foundation 与 WKWebView 两个存储，保证 WebView 登录后的 HttpOnly Cookie 可见。
 */
export async function getNativeCookies(
  url: string = TIEBA_COOKIE_URL,
): Promise<Record<string, string>> {
  const manager = getCookieManager();
  if (!manager) return {};

  const merged: Record<string, string> = {};
  try {
    Object.assign(merged, normalizeCookies(await manager.get(url, false)));
  } catch {}

  try {
    Object.assign(merged, normalizeCookies(await manager.get(url, true)));
  } catch {}

  return merged;
}

/**
 * 读取 iOS 原生 Cookie 中的 BDUSS/STOKEN —— 冷启动恢复专用，
 * 全仓仅 authStore.checkAuth 一处消费（仅在本地无凭据时调用）。
 *
 * 窄契约：只返回 {bduss, stoken}。zid 不回填：即使原生 Cookie 里带
 * BAIDUZID 也不读取——账号 zid 由 SQLite 元数据持有，冷启动恢复不依赖
 * 原生 Cookie（对齐 Kotlin AccountUtil.init 语义）。
 *
 * 不做内存凭据兜底：调用方保证仅在 SecureStore 无凭据（内存缓存为空）时
 * 才走到这里，兜底只会掩盖“凭据确实丢失”的事实。
 */
export async function getTiebaAuthCookies(): Promise<{ bduss: string; stoken: string }> {
  const cookies = await getNativeCookies(TIEBA_COOKIE_URL);
  return {
    bduss: cookies.BDUSS ?? '',
    stoken: cookies.STOKEN ?? '',
  };
}

/**
 * 清除 iOS 原生 Cookie 存储，对齐 Kotlin AccountUtil.exit() 的
 * CookieManager.removeAllCookies()。同时清理 Foundation 与默认
 * WKWebView 存储。返回 false 表示清除失败，供登出流程校验。
 */
export async function clearNativeCookies(): Promise<boolean> {
  const manager = getCookieManager();
  if (!manager) return true; // 当前构建没有原生模块时无可清理项
  try {
    const result = await manager.clearAllStores();
    return result !== false;
  } catch (error) {
    console.warn('[CookieService] clearNativeCookies failed:', sanitizeError(error));
    return false;
  }
}