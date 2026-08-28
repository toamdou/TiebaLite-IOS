// ============================================================
// Shared Auth State — avoids circular imports between
// config.ts and interceptors.ts
//
// Kotlin 用 AccountUtil.getBduss() / getSToken() 直接读
// Room DB 字段，无需 async。
//
// Expo 端凭据不再明文写入统一 SQLite 库：
//   getBduss() → AuthSecureStorage 内存缓存（SecureStore 已 hydrate）
//   setAuthState(bduss, stoken) → 先更新内存，再异步写 SecureStore
//
// 冷启动时必须先 await hydrateSecureCredentials()，否则同步 getter
// 返回空值。
// ============================================================

import {
  getBdussSync,
  getStokenSync,
  getUidSync,
  getTbsSync,
  getZidSync,
  getCookieSync,
  setBdussSync,
  setStokenSync,
  setTbsSync,
  clearAllAuthSync,
} from '@/services/storage/AuthSQLiteStorage';

/** 对齐 Kotlin AccountUtil.getBduss() — 同步，无 async gap */
export function getBduss(): string {
  return getBdussSync();
}

/** 对齐 Kotlin AccountUtil.getSToken() */
export function getStoken(): string {
  return getStokenSync();
}

/** 对齐 Kotlin AccountUtil.getUid() */
export function getUid(): string {
  return getUidSync();
}

/** 对齐 Kotlin AccountUtil.getAccountInfo { tbs } */
export function getTbs(): string {
  return getTbsSync();
}

/** 写入 tbs（供 fetchTbs/登录后自动获取 tbs 使用；复用现有持久化路径，不新建 store） */
export function setTbs(tbs: string, uid?: string): void {
  setTbsSync(tbs ?? '', uid);
}

/** 对齐 Kotlin AccountUtil.getAccountInfo { zid } */
export function getZid(): string {
  return getZidSync();
}

/** 对齐 Kotlin AccountUtil.getCookie() */
export function getCookie(): string {
  return getCookieSync();
}

/**
 * 设置 BDUSS 和 STOKEN（先更新内存，再异步写 SecureStore）。
 * 对齐 Kotlin:
 *   account.bduss = bduss; account.sToken = sToken;
 *   DatabaseUtil.updateAccount(account)
 */
export function setAuthState(bduss: string | null, stoken: string | null): void {
  // 空值也要清理，避免切换/登录到无凭据账号时残留上一个账号的 BDUSS/STOKEN。
  setBdussSync(bduss ?? '');
  setStokenSync(stoken ?? '');
}

/** 清除鉴权状态（对齐 Kotlin AccountUtil.exit → deleteAccount + removeAllCookies） */
export function clearAuthState(): void {
  clearAllAuthSync();
}
