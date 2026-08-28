// ============================================================
// AuthSQLiteStorage — SQLite account metadata + sync credential facade
//
// Kotlin 用 Room (SQLite) 持久化 Account，但 Expo 端凭据是敏感的：
//   - BDUSS/STOKEN/COOKIE → SecureStore（AuthSecureStorage）
//   - UID/TBS/ZID/账号列表/活跃 ID → unifiedDb（单一 SQLite 库）
//
// 同步 getter（getBdussSync/getStokenSync/getCookieSync 等）保留原有
// 签名，内部读取 AuthSecureStorage 的内存缓存；写入时先更新内存，
// 再异步写 SecureStore。冷启动后请先 await hydrateSecureCredentials()。
//
// key 常量表 / redact / sanitizeError / parseJson 一律复用
// AuthSecureStorage 的导出（唯一权威），避免两处定义漂移。
// ============================================================

import {
  kvBatchSync,
  kvGetSync,
  kvRemoveSync,
  kvSetSync,
} from './unifiedDb';
import type { Account } from '@/types';
import {
  getBdussCached,
  getStokenCached,
  getCookieCached,
  getUidCached,
  getTbsCached,
  getZidCached,
  setBdussCached,
  setStokenCached,
  setCookieCached,
  setTbsCached,
  setCurrentMetaCached,
  clearMetaCache,
  clearSecureCredentials,
  deleteAccountCredentials,
  persistAccountCredentials,
  LEGACY_PLAINTEXT_KEYS,
  keys,
  parseJson,
  redact,
  sanitizeError,
} from './AuthSecureStorage';
import type { AccountCredentials } from './AuthSecureStorage';

export {
  hydrateSecureCredentials,
  loadAccountCredentials,
  clearSecureCredentials,
} from './AuthSecureStorage';

// ---------- 存储 key 统一表：见 ./AuthSecureStorage 的 keys ----------

/** 按 uid 生成账号存储 key */
function accountKey(uid: string): string {
  return `${keys.ACCOUNT_PREFIX}${uid}`;
}

function getRawAccount(uid: string): Account | null {
  return parseJson<Account>(kvGetSync(accountKey(uid)));
}

function getRawAccountList(): Account[] {
  const list = parseJson<Account[]>(kvGetSync(keys.ACCOUNT_LIST));
  return Array.isArray(list) ? list : [];
}

/** 只有活跃账号能从内存缓存回填凭据；列表中的其他账号保持元数据。 */
function fillActiveCredentials(account: Account | null): Account | null {
  if (!account) return null;
  return {
    ...account,
    bduss: getBdussCached(),
    sToken: getStokenCached(),
    cookie: getCookieCached(),
    // F2：tbs/zid 也从内存 meta 回填，保证 activateAccount → saveAccountSync
    // 链路不会用空值覆盖 Keychain 里刚 hydrate 的会话令牌。
    tbs: getTbsCached(),
    zid: getZidCached(),
  };
}

/**
 * Execute a group of kv-store writes as a single synchronous batch. Sync
 * calls cannot interleave on the JS thread, so this acts as a single-writer
 * queue; if any write throws, all values touched by the batch are restored
 * from the snapshot taken before the first write.
 */
function writeKvBatch(writes: { key: string; value: string | null }[]): void {
  kvBatchSync(writes);
}

// ============================================================
// 同步单字段访问（签名保留，读 SecureStore 内存缓存）
// ============================================================

export function getBdussSync(): string {
  return getBdussCached();
}

export function getStokenSync(): string {
  return getStokenCached();
}

export function getUidSync(): string {
  return getUidCached();
}

export function getTbsSync(): string {
  return getTbsCached();
}

export function getZidSync(): string {
  return getZidCached();
}

export function getCookieSync(): string {
  return getCookieCached();
}

export function setBdussSync(bduss: string): void {
  setBdussCached(bduss ?? '');
}

export function setStokenSync(stoken: string): void {
  setStokenCached(stoken ?? '');
}

/** 写入当前账号 tbs（内存 + Keychain，经 persistMeta）；SQLite 不再落 tbs（F2）。
 *  第二参数为历史签名兼容保留（调用方按位置传入），当前无消费。 */
export function setTbsSync(tbs: string, _uid?: string): void {
  setTbsCached(tbs ?? '');
}

// ============================================================
// 账号持久化（凭据 → SecureStore，元数据 → SQLite）
// ============================================================

export function saveAccountSync(account: Account): void {
  if (!account.uid) {
    throw new Error('Cannot save account without uid');
  }

  const credentials: AccountCredentials = {
    bduss: account.bduss ?? '',
    stoken: account.sToken ?? '',
    cookie: account.cookie ?? '',
    tbs: account.tbs ?? '',
    zid: account.zid ?? '',
  };

  // 先更新内存缓存，再异步写 SecureStore（错误已接住，不产生未处理 Promise）。
  setBdussCached(credentials.bduss);
  setStokenCached(credentials.stoken);
  setCookieCached(credentials.cookie);
  void persistAccountCredentials(account.uid, credentials).catch((error) => {
    console.warn('[AuthSQLiteStorage] Failed to persist credentials:', sanitizeError(error));
  });

  const nextMeta = {
    uid: account.uid,
    tbs: account.tbs ?? '',
    zid: account.zid ?? '',
  };

  // SQLite 只写元数据，合并为：账号 JSON + 活跃 ID + 账号列表。
  // CURRENT_META 只经 setCurrentMetaCached（persistMeta）单点写入，
  // 不再在批量中重复写同一 key（审查 #11 双写去重）。
  const metadata = redact(account);
  const list = getRawAccountList().filter((a) => a.uid !== account.uid);
  list.push(metadata);
  writeKvBatch([
    { key: accountKey(account.uid), value: JSON.stringify(metadata) },
    { key: keys.ACTIVE_ID, value: account.uid },
    { key: keys.ACCOUNT_LIST, value: JSON.stringify(list) },
  ]);
  setCurrentMetaCached(nextMeta);
}

export function getAccountListSync(): Account[] {
  return getRawAccountList();
}

/**
 * 删除账号。必须先记录 activeId 再删 JSON/列表，否则“删除的是当前账号”
 * 的判断会因 JSON 已消失而永远为 false。
 */
export function deleteAccountSync(uid: string): void {
  const activeId = kvGetSync(keys.ACTIVE_ID) ?? '';

  kvRemoveSync(accountKey(uid));
  const list = getRawAccountList().filter((a) => a.uid !== uid);
  kvSetSync(keys.ACCOUNT_LIST, JSON.stringify(list));

  void deleteAccountCredentials(uid).catch((error) => {
    console.warn('[AuthSQLiteStorage] Failed to delete account credentials:', sanitizeError(error));
  });

  if (activeId === uid) {
    clearAllAuthSync();
  }
}

export function clearAllAuthSync(): void {
  kvRemoveSync(keys.ACTIVE_ID);
  for (const key of LEGACY_PLAINTEXT_KEYS) {
    kvRemoveSync(key);
  }
  kvRemoveSync(keys.LEGACY_UID);
  kvRemoveSync(keys.LEGACY_TBS);
  kvRemoveSync(keys.LEGACY_ZID);
  clearMetaCache();
  void clearSecureCredentials().catch((error) => {
    console.warn('[AuthSQLiteStorage] Failed to clear secure credentials:', sanitizeError(error));
  });
}

// ============================================================
// 冷启动恢复（对齐 Kotlin AccountUtil.init）
// ============================================================

/** 同步恢复当前活跃账号；调用前请先 await hydrateSecureCredentials()。 */
export function restoreAccountSync(): Account | null {
  const activeId = kvGetSync(keys.ACTIVE_ID);
  if (!activeId) return null;
  return fillActiveCredentials(getRawAccount(activeId));
}