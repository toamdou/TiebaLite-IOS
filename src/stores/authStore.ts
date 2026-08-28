// ============================================================
// authStore - Minimal Zustand auth state
//
// Single login path matching Kotlin AccountUtil flow:
//   WebView login → extract user info → save → switch account
//
// 持久化策略（与 Kotlin Room DB 对齐，但凭据不再明文落 SQLite）：
//   - BDUSS/STOKEN/COOKIE → SecureStore（AuthSecureStorage）
//   - UID/TBS/ZID/账号列表/活跃 ID → unifiedDb（单一 SQLite 库）
//   - 冷启动先 await hydrateSecureCredentials() 再恢复账号
//   - 登录/切换成功后重启通知轮询，登出/过期时停止
//
// 激活账号的序列（saveAccountSync/setAuthCredentials/syncNativeCookies/
// 后台快照/档案缓存/轮询重启）统一收敛到 AuthService.activateAccount()，
// 本 Store 不再重复执行，只负责状态回填与 UI 侧联动。
// ============================================================

import { create } from 'zustand';
import type { Account } from '@/types';
import type { LoginUserInfo } from '@/services/auth/AuthService';
import {
  restoreAccountSync,
  saveAccountSync,
  loadAccountCredentials,
} from '@/services/storage/AuthSQLiteStorage';
import {
  getCachedAccountProfile,
  saveAccountProfile,
  clearAccountProfile,
} from '@/services/auth/accountCache';
import { hydrateSecureCredentials } from '@/services/storage/AuthSecureStorage';
import { clearBackgroundSnapshot } from '@/services/nativeBackground';

// ── 启动热路径裁剪（冷启动 TTI）──
// 本 store 经根 _layout 进首帧模块图。下列重依赖一律延迟到调用点 require：
//   - AuthService / api 端点 → nitro-fetch 图
//   - NotificationPoller / forumFollowed / CookieService → 网络与原生服务层
// 轻量存储层（SQLite/SecureStore/档案缓存/后台快照）保持静态：checkAuth
// 首帧就要用，且自身不带 api 端点依赖。
/* eslint-disable @typescript-eslint/no-require-imports -- 启动热路径惰性加载 */
const lazyAuthService = () =>
  require('@/services/auth/AuthService') as typeof import('@/services/auth/AuthService');
const lazyPoller = () =>
  require('@/services/NotificationPoller') as typeof import('@/services/NotificationPoller');
const lazyForumFollowed = () =>
  require('@/services/forumFollowed') as typeof import('@/services/forumFollowed');
const lazyInterceptors = () =>
  require('@/services/api/interceptors') as typeof import('@/services/api/interceptors');
const lazyCookieService = () =>
  require('@/services/cookies/CookieService') as typeof import('@/services/cookies/CookieService');
const lazyUserEndpoints = () =>
  require('@/services/api/endpoints/user') as typeof import('@/services/api/endpoints/user');
/* eslint-enable @typescript-eslint/no-require-imports */

export interface AuthState {
  isLoggedIn: boolean;
  isLoading: boolean;
  account: Account | null;
  error: string | null;

  login(user: LoginUserInfo): Promise<void>;
  logout(): Promise<void>;
  checkAuth(): Promise<void>;
  switchAccount(account: Account): Promise<void>;
}

/** 登出态统一清理：凭据、原生快照、后台同步、档案缓存、关注列表缓存。 */
function teardownLoggedOut(
  set: (partial: Partial<AuthState>) => void,
  error: string | null,
): void {
  lazyInterceptors().clearAuthCredentials();
  clearBackgroundSnapshot();
  lazyPoller().cancelNativeBackgroundSync();
  void clearAccountProfile();
  lazyForumFollowed().invalidateFollowedForumsCache();
  set({ isLoggedIn: false, isLoading: false, account: null, error });
}

async function refreshAccountProfile(account: Account): Promise<Account> {
  try {
    const { profile: fetchProfile } = lazyUserEndpoints();
    const userProfile = await fetchProfile(account.uid);
    const user = userProfile.user;
    const next: Account = {
      ...account,
      nameShow: user.nameShow || account.nameShow,
      portrait: user.portrait || account.portrait,
      levelId: user.levelId,
      levelName: user.levelName,
      intro: user.intro || account.intro,
      fansNum: user.fansNum ?? account.fansNum,
      concernNum: user.concernNum ?? account.concernNum,
      postNum: user.postNum ?? account.postNum,
    };
    saveAccountSync(next);
    await saveAccountProfile(next);
    return next;
  } catch {
    return account;
  }
}

/** Kick off the login-state dependent screens after auth changes. */
async function refreshPostLoginStores(): Promise<void> {
  try {
    const { useForumStore } = await import('./forumStore');
    void useForumStore.getState().loadFollowedForums();
  } catch {}
  try {
    const { useNotificationStore } = await import('./notificationStore');
    void useNotificationStore.getState().loadNotificationCounts();
  } catch {}
}

/**
 * 用后台拉取的 profile 回填 account，但仅当回填仍属于当前活跃账号时生效。
 * 快速切换账号时，晚到的旧账号响应不得覆盖刚切到的新账号（否则通知基线/凭据错位）。
 */
function applyRefreshedProfile(account: Account, refreshed: Account): void {
  const current = useAuthStore.getState().account;
  if (current?.uid && current.uid === account.uid && current.uid === refreshed.uid) {
    useAuthStore.setState({ account: refreshed });
  }
}

export const useAuthStore = create<AuthState>((set) => ({
  isLoggedIn: false,
  isLoading: false,
  account: null,
  error: null,

  login: async (user) => {
    set({ isLoading: true, error: null });
    try {
      const account = await lazyAuthService().login(user);
      // 激活序列（持久化/鉴权态/原生 Cookie/快照/档案缓存/轮询重启）
      // 已在 AuthService.login → activateAccount 内完成。
      set({ isLoggedIn: true, isLoading: false, account, error: null });
      void refreshAccountProfile(account).then((refreshed) => {
        applyRefreshedProfile(account, refreshed);
      });
      lazyForumFollowed().invalidateFollowedForumsCache();
      void refreshPostLoginStores();
      // 重新登录需恢复原生后台通知同步（登出时被 cancelNativeBackgroundSync 取消）
      lazyPoller().ensureBackgroundSync();
    } catch (e: any) {
      set({ isLoading: false, error: e?.message ?? 'Login failed' });
      throw e;
    }
  },

  logout: async () => {
    set({ isLoading: true });
    const previousUid = useAuthStore.getState().account?.uid;
    try {
      const next = await lazyAuthService().logout();
      if (next) {
        // 切号激活（setAuthCredentials/saveAccountProfile/轮询重启等）
        // 已在 AuthService.logout → activateAccount 内完成。
        set({ isLoggedIn: true, isLoading: false, account: next, error: null });
      } else {
        lazyInterceptors().clearAuthCredentials();
        lazyPoller().stopNotificationPoller();
        lazyPoller().cancelNativeBackgroundSync();
        void clearAccountProfile();
        lazyForumFollowed().invalidateFollowedForumsCache();
        if (previousUid) {
          await lazyPoller().clearNotificationBaseline(previousUid);
        }
        set({ isLoggedIn: false, isLoading: false, account: null, error: null });
      }
    } catch (e: any) {
      // AuthService.logout 已先删除账号；即使原生 Cookie 清除校验失败，
      // 也按登出处理并停止轮询，避免残留已删除账号的登录态。
      lazyPoller().stopNotificationPoller();
      lazyInterceptors().clearAuthCredentials();
      clearBackgroundSnapshot();
      lazyPoller().cancelNativeBackgroundSync();
      void clearAccountProfile();
      lazyForumFollowed().invalidateFollowedForumsCache();
      if (previousUid) {
        await lazyPoller().clearNotificationBaseline(previousUid);
      }
      set({
        isLoggedIn: false,
        isLoading: false,
        account: null,
        error: e?.message ?? 'Logout failed',
      });
    }
  },

  /**
   * 冷启动鉴权检查。
   *
   * SecureStore/SQLite 中的凭据是权威来源；原生 Cookie 只在本地完全没有
   * 凭据时作为恢复来源，不反向覆盖已保存账号。
   */
  checkAuth: async () => {
    set({ isLoading: true });
    try {
      const cached = await getCachedAccountProfile();
      if (cached?.uid) {
        set({ account: cached, error: null });
      }
      await hydrateSecureCredentials();
      const account = restoreAccountSync();
      if (__DEV__) {
        console.warn(
          `[auth] checkAuth: uid=${account?.uid ?? '(none)'} bduss=${account?.bduss ? 'YES' : 'NO'} stoken=${account?.sToken ? 'YES' : 'NO'} cookie=${account?.cookie ? 'YES' : 'NO'}`,
        );
      }

      if (account?.uid) {
        const hasLocalCredentials = !!(account.bduss || account.sToken || account.cookie);
        let restored = account;

        if (!hasLocalCredentials) {
          // 旧版本或 SecureStore 丢失时，仅在本地无凭据时尝试原生 Cookie 恢复。
          // 只回填 BDUSS/STOKEN；zid 不回填（由 SQLite 元数据持有，见 CookieService）。
          try {
            const cookies = await lazyCookieService().getTiebaAuthCookies();
            if (cookies.bduss) {
              restored = { ...account, bduss: cookies.bduss, sToken: cookies.stoken };
            } else if (__DEV__) {
              console.warn('[auth] checkAuth: 原生 cookie 兜底无 BDUSS');
            }
          } catch (e: any) {
            if (__DEV__) console.warn('[auth] checkAuth: 原生 cookie 兜底失败:', e?.message);
          }
        }

        if (restored.bduss) {
          // 统一激活序列（含 saveAccountSync/syncNativeCookies/档案缓存）；
          // 不重启轮询（restartPoller: false，冷启动轮询由 setupNotifications 负责）。
          await lazyAuthService().activateAccount(restored, { restartPoller: false });
          void refreshAccountProfile(restored).then((refreshed) => {
            applyRefreshedProfile(restored, refreshed);
          });
          void refreshPostLoginStores();
          set({
            isLoggedIn: true,
            isLoading: false,
            account: restored,
            error: null,
          });
        } else {
          // 有账号元数据但无凭据；统一 teardown（含 invalidateFollowedForumsCache，
          // 此前该分支漏调，导致旧吧关注缓存残留，审查 #8）。
          teardownLoggedOut(set, '登录信息缺失，请重新登录');
        }
      } else {
        teardownLoggedOut(set, null);
      }
    } catch (e: any) {
      if (__DEV__) console.warn('[auth] checkAuth 异常:', e?.message ?? String(e));
      teardownLoggedOut(set, e?.message ?? 'Check auth failed');
    }
  },

  switchAccount: async (account: Account) => {
    set({ isLoading: true });
    try {
      await hydrateSecureCredentials();
      const credentials = await loadAccountCredentials(account.uid);
      const bduss = account.bduss || credentials.bduss;
      const sToken = account.sToken || credentials.stoken;
      if (!bduss) {
        throw new Error('该账号缺少登录凭据，请重新登录');
      }
      const switched = await lazyAuthService().login({
        uid: account.uid,
        name: account.name,
        nameShow: account.nameShow,
        portrait: account.portrait,
        tbs: account.tbs || credentials.tbs,
        bduss,
        sToken,
        cookie: account.cookie || credentials.cookie,
        zid: account.zid || credentials.zid,
      });
      set({
        isLoggedIn: true,
        isLoading: false,
        account: { ...switched, bduss, sToken },
        error: null,
      });
      void refreshAccountProfile({ ...switched, bduss, sToken }).then((refreshed) => {
        applyRefreshedProfile({ ...switched, bduss, sToken }, refreshed);
      });
      lazyForumFollowed().invalidateFollowedForumsCache();
      void refreshPostLoginStores();
      // 切换账号后同样需要恢复原生后台通知同步
      lazyPoller().ensureBackgroundSync();
    } catch (e: any) {
      set({ isLoading: false, error: e?.message ?? 'Switch account failed' });
    }
  },
}));