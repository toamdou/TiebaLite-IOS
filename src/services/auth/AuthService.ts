// ============================================================
// AuthService - Auth persistence (aligned with Kotlin AccountUtil)
//
// Kotlin flow:
//   WebView login → CookieManager.getCookie(url) → parse BDUSS/STOKEN
//   → fetchAccountFlow(bduss, sToken, cookie) → Room DB (SQLite)
//
// Expo flow:
//   WebView login → JS extraction → SecureStore (凭据) + SQLite (元数据)
//
// BDUSS/STOKEN/COOKIE 只进 SecureStore；SQLite 仅保存账号元数据。
//
// 激活账号的唯一入口是 activateAccount()——login / logout 切下一号 /
// authStore 的 login / switchAccount / checkAuth 五个调用点共用，
// 保证「持久化、运行时鉴权态、原生 Cookie、后台快照、档案缓存、轮询」
// 的序列只有一份（审查 #2）。
// ============================================================

import { Account } from '@/types';
import {
  saveAccountSync,
  restoreAccountSync,
  deleteAccountSync,
  getAccountListSync,
  loadAccountCredentials,
} from '@/services/storage/AuthSQLiteStorage';
import { setAuthCredentials } from '@/services/api/interceptors';
import { clearNativeCookies, syncNativeCookies } from '@/services/cookies/CookieService';
import {
  clearBackgroundSnapshot,
  resetBackgroundForums,
  syncBackgroundSnapshot,
} from '@/services/nativeBackground';
import { saveAccountProfile } from '@/services/auth/accountCache';
import {
  startNotificationPoller,
  stopNotificationPoller,
} from '@/services/NotificationPoller';

export type LoginUserInfo = {
  uid: string;
  name: string;
  nameShow: string;
  portrait: string;
  tbs: string;
  /** BDUSS session token */
  bduss: string;
  /** STOKEN security token */
  sToken: string;
  /** Raw cookie string */
  cookie: string;
  /** ZID / BAIDUID */
  zid: string;
};

export interface ActivateAccountOptions {
  /** 是否重启前台通知轮询（stop → start）；登录/切号/登出切下一号为 true，冷启动 checkAuth 为 false。 */
  restartPoller?: boolean;
}

/**
 * 激活账号单点序列（对齐 Kotlin switchAccount → global state）。
 *
 * 顺序保证（部分失败一致性，审查 #3）：唯一可能失败的异步步骤
 * syncNativeCookies 必须最先执行——失败时尚未写入任何持久化状态，
 * 调用方 catch 后 UI 报错与 SQLite/Keychain 状态一致（不会出现
 * “UI 提示失败但凭据已落库、下次冷启动又自动登录”的撕裂）。
 *
 * 执行顺序：
 *   1. 原生 Cookie 写入（可失败，失败即中止且零持久化副作用）
 *   2. saveAccountSync：SQLite 元数据 + SecureStore 凭据 + 内存缓存
 *   3. setAuthCredentials：运行时鉴权态
 *   4. resetBackgroundForums + syncBackgroundSnapshot：原生后台快照
 *      （读取内存鉴权态，必须在第 3 步之后）
 *   5. saveAccountProfile：冷启动首帧档案缓存（best-effort）
 *   6. 可选 restartPoller：stopNotificationPoller + startNotificationPoller
 */
export async function activateAccount(
  account: Account,
  options: ActivateAccountOptions = {},
): Promise<Account> {
  // 1. 原生 Cookie 先行
  await syncNativeCookies(account.bduss, account.sToken, account.cookie);
  // 2. 持久化（SQLite 元数据 + Keychain 凭据）
  saveAccountSync(account);
  // 3. 运行时鉴权态
  setAuthCredentials(account.bduss, account.sToken);
  // 4. 原生后台快照
  resetBackgroundForums();
  syncBackgroundSnapshot();
  // 5. 冷启动档案缓存
  void saveAccountProfile(account).catch(() => {});
  // 6. 通知轮询重启（可选）
  if (options.restartPoller) {
    stopNotificationPoller();
    startNotificationPoller();
  }
  return account;
}

/**
 * 登录 (对齐 Kotlin AccountUtil.fetchAccountFlow → DatabaseUtil.upsertAccountByUid)
 *
 * 登录成功后:
 * 1. 构建 Account 对象
 * 2. activateAccount 立即激活鉴权状态（对齐 Kotlin switchAccount → global state）
 */
export async function login(user: LoginUserInfo): Promise<Account> {
  if (!user.bduss) {
    throw new Error('缺少 BDUSS，无法完成登录');
  }
  const account: Account = {
    id: 0,
    uid: user.uid,
    name: user.name,
    nameShow: user.nameShow || user.name,
    portrait: user.portrait,
    bduss: user.bduss,
    sToken: user.sToken,
    tbs: user.tbs,
    cookie: user.cookie || `BDUSS=${user.bduss}; Path=/; Max-Age=315360000; Domain=.baidu.com; Httponly`,
    uuid: user.uid,
    zid: user.zid,
  };

  // 激活单点：持久化 + 鉴权态 + 原生 Cookie/快照 + 档案缓存 + 轮询重启
  await activateAccount(account, { restartPoller: true });
  return account;
}

/**
 * 登出 (对齐 Kotlin AccountUtil.exit)
 * 如果仍有其他账号，自动切换到列表中的第一个账号。
 */
export async function logout(): Promise<Account | null> {
  // 先清除原生 Cookie 存储（对齐 Kotlin AccountUtil.exit → removeAllCookies），
  // 校验成功后才删账号数据：旧顺序先删后校验，Cookie 清除失败时账号已毁
  // 但界面报失败（2026-08-27 审计修正）。
  const cleared = await clearNativeCookies();
  if (!cleared) {
    throw new Error('清除原生 Cookie 失败，请重试');
  }

  // 从 SQLite 读取当前 uid 然后删除
  const account = restoreAccountSync();
  if (account) {
    deleteAccountSync(account.uid);
  }

  // 凭据按账号隔离在 SecureStore；并行加载所有剩余账号的凭据，
  // 取首个仍有 BDUSS 的账号（Promise.all 保持列表顺序，与原串行循环等价）。
  const remaining = getAccountListSync();
  const credentialsList = await Promise.all(
    remaining.map((meta) => loadAccountCredentials(meta.uid)),
  );
  const index = credentialsList.findIndex((credentials) => credentials.bduss);
  const next: Account | null =
    index >= 0
      ? { ...remaining[index], ...credentialsList[index] }
      : null;
  if (next) {
    // 切下一号 = 激活新账号（含 saveAccountProfile，防止 checkAuth 冷启动
    // 闪旧账号档案，审查 #1）
    await activateAccount(next, { restartPoller: true });
  } else {
    clearBackgroundSnapshot();
  }
  return next;
}

/**
 * 冷启动恢复 (对齐 Kotlin AccountUtil.init)
 *
 * 同步从 SQLite 读取活跃账号，无 async gap。
 * 对齐 Kotlin:
 *   val loginUser = context.getSharedPreferences("accountData", ...).getInt("now", -1)
 *   getAccountInfo(loginUser)
 */
export async function restoreAccount(): Promise<Account | null> {
  return restoreAccountSync();
}