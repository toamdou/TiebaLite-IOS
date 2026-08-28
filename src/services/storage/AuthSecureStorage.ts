// ============================================================
// AuthSecureStorage - SecureStore-backed credentials
//
// BDUSS/STOKEN/COOKIE are sensitive login credentials and must
// never be written to the unified SQLite database in plaintext. This
// module keeps them in iOS Keychain via expo-secure-store while
// exposing a synchronous in-memory cache so existing sync getters
// (getBdussSync etc.) keep their signatures.
//
// Credentials are stored per account under:
//   tiebalite.account.<uid>.bduss|stoken|cookie|tbs|zid
// plus active-session keys (tiebalite.active.*) so switching
// accounts can restore the correct credential set.
// ============================================================

import * as SecureStore from 'expo-secure-store';
import {
  ensureUnifiedStorageReady,
  kvGetSync,
  kvRemoveSync,
  kvSetSync,
} from './unifiedDb';

// ------------------------------------------------------------
// Keys
// ------------------------------------------------------------

const ACTIVE_KEYS = {
  BDUSS: 'tiebalite.active.bduss',
  STOKEN: 'tiebalite.active.stoken',
  COOKIE: 'tiebalite.active.cookie',
  // F2（2026-08-26 内存安全审查）：tbs/zid 是会话令牌，MMKV 是 mmap 明文页
  // （RAM 与磁盘同时可见），一并迁入 Keychain。
  TBS: 'tiebalite.active.tbs',
  ZID: 'tiebalite.active.zid',
} as const;

/** Keep credentials readable by native background tasks after first unlock. */
const SECURE_STORE_OPTIONS: SecureStore.SecureStoreOptions = {
  keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
};

/**
 * SQLite kv-store key 表 —— 唯一权威来源（`keys` 单一常量表）：
 * AuthSQLiteStorage / accountCache 等一律 import 复用，不得各自定义。
 */
export const keys = {
  /** 仅存 uid（tbs/zid 已迁 Keychain，见 ACTIVE_KEYS）；历史形状曾含三字段。 */
  CURRENT_META: '@tiebalite:current_meta',
  LEGACY_BDUSS: '@tiebalite:bduss',
  LEGACY_STOKEN: '@tiebalite:stoken',
  LEGACY_COOKIE: '@tiebalite:cookie',
  LEGACY_UID: '@tiebalite:uid',
  LEGACY_TBS: '@tiebalite:tbs',
  LEGACY_ZID: '@tiebalite:zid',
  ACTIVE_ID: '@tiebalite:active_id',
  ACCOUNT_LIST: '@tiebalite:account_list',
  ACCOUNT_PREFIX: '@tiebalite:account:',
  /** 冷启动账号档案缓存（无凭据，仅供 UI 首帧渲染） */
  ACCOUNT_PROFILE_CACHE: '@tiebalite:account_profile_cache_v1',
} as const;

/** Plaintext keys removed after the one-time migration. */
export const LEGACY_PLAINTEXT_KEYS = [
  keys.LEGACY_BDUSS,
  keys.LEGACY_STOKEN,
  keys.LEGACY_COOKIE,
] as const;

/** Combined UID/TBS/ZID key still stored in SQLite (metadata only). */
export const CURRENT_META_KEY = keys.CURRENT_META;

function accountCredentialKey(
  uid: string,
  field: 'bduss' | 'stoken' | 'cookie' | 'tbs' | 'zid',
): string {
  return `tiebalite.account.${uid}.${field}`;
}

export interface AccountCredentials {
  bduss: string;
  stoken: string;
  cookie: string;
  /** 会话令牌，随账号隔离存 Keychain（切号恢复用，F2） */
  tbs: string;
  zid: string;
}

export interface CurrentMeta {
  uid: string;
  tbs: string;
  zid: string;
}

// ------------------------------------------------------------
// In-memory sync caches
// ------------------------------------------------------------

let memory: AccountCredentials = { bduss: '', stoken: '', cookie: '', tbs: '', zid: '' };
let meta: CurrentMeta = { uid: '', tbs: '', zid: '' };
let metaLoaded = false;
let hydratePromise: Promise<void> | null = null;
let hydrated = false;

/** 规范化错误输出（防 axios 错误对象打印时泄漏含 BDUSS 的 Cookie header）。 */
export function sanitizeError(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`;
  return String(error);
}

/** 安全 JSON 解析；解析失败返回 null。 */
export function parseJson<T>(raw: string | null | undefined): T | null {
  if (!raw) return null;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return null;
  }
}

/**
 * 从 SQLite 读活跃 uid。CURRENT_META 现在只含 uid（F2：tbs/zid 迁 Keychain）；
 * 解析兼容旧三字段 JSON 形状，兜底读单键遗留 LEGACY_UID。
 */
function loadUidFromSqlite(): string {
  try {
    const rawMeta = kvGetSync(keys.CURRENT_META);
    if (rawMeta) {
      const parsed = JSON.parse(rawMeta) as Partial<CurrentMeta>;
      return typeof parsed.uid === 'string' ? parsed.uid : '';
    }
  } catch {}
  return kvGetSync(keys.LEGACY_UID) ?? '';
}

function ensureMetaLoaded(): CurrentMeta {
  if (!metaLoaded) {
    // 冷启动 hydrate 前被同步调用时，tbs/zid 尚未从 Keychain 装载，返回空值
    // 与旧行为一致（凭据/会话令牌都以 hydrate 后为准）。
    meta = { uid: loadUidFromSqlite(), tbs: '', zid: '' };
    metaLoaded = true;
  }
  return meta;
}

/** 非空写 / 空删的 Keychain 单值持久化；删除缺失条目属预期路径，不告警。 */
function persistSecureValue(key: string, value: string): void {
  const write = value
    ? SecureStore.setItemAsync(key, value, SECURE_STORE_OPTIONS)
    : SecureStore.deleteItemAsync(key).catch(() => {
        // 条目本就不存在：静默（登出/清缓存高频路径，避免日志噪声）。
      });
  if (value) {
    write.catch((error) => {
      console.warn('[AuthSecureStorage] Failed to persist keychain value:', sanitizeError(error));
    });
  }
}

function persistMeta(next: CurrentMeta): void {
  meta = next;
  try {
    // CURRENT_META 只落 uid；tbs/zid 是会话令牌，走 Keychain（F2）。
    kvSetSync(keys.CURRENT_META, JSON.stringify({ uid: next.uid }));
  } catch (error) {
    console.warn('[AuthSecureStorage] Failed to persist current meta:', sanitizeError(error));
  }
  persistSecureValue(ACTIVE_KEYS.TBS, next.tbs ?? '');
  persistSecureValue(ACTIVE_KEYS.ZID, next.zid ?? '');
}

// ------------------------------------------------------------
// Credential sync getters / setters
// ------------------------------------------------------------

export function getBdussCached(): string {
  return memory.bduss;
}

export function getStokenCached(): string {
  return memory.stoken;
}

export function getCookieCached(): string {
  return memory.cookie;
}

// thermo 2026-08-26（Z7-B）：三个 set*Cached 原是同一「空值删 Keychain、
// 非空写 Keychain + 内存镜像」样板 ×3，收敛为配置驱动的单一实现。
const ACTIVE_FIELD_WRITERS = {
  bduss: (v: string) =>
    v
      ? SecureStore.setItemAsync(ACTIVE_KEYS.BDUSS, v, SECURE_STORE_OPTIONS)
      : SecureStore.deleteItemAsync(ACTIVE_KEYS.BDUSS),
  stoken: (v: string) =>
    v
      ? SecureStore.setItemAsync(ACTIVE_KEYS.STOKEN, v, SECURE_STORE_OPTIONS)
      : SecureStore.deleteItemAsync(ACTIVE_KEYS.STOKEN),
  cookie: (v: string) =>
    v
      ? SecureStore.setItemAsync(ACTIVE_KEYS.COOKIE, v, SECURE_STORE_OPTIONS)
      : SecureStore.deleteItemAsync(ACTIVE_KEYS.COOKIE),
} as const;

function setActiveField(field: keyof typeof ACTIVE_FIELD_WRITERS, value: string): void {
  const normalized = value ?? '';
  memory[field] = normalized;
  // 空值不落 Keychain（避免残留空条目）；内存已同步清空为 ''。
  ACTIVE_FIELD_WRITERS[field](normalized).catch((error) => {
    console.warn(`[AuthSecureStorage] Failed to persist ${field}:`, sanitizeError(error));
  });
}

export function setBdussCached(value: string): void {
  setActiveField('bduss', value ?? '');
}

export function setStokenCached(value: string): void {
  setActiveField('stoken', value ?? '');
}

export function setCookieCached(value: string): void {
  setActiveField('cookie', value ?? '');
}

// ------------------------------------------------------------
// Metadata sync getters / setters（uid 落 SQLite；tbs/zid 内存 + Keychain）
// ------------------------------------------------------------

export function getUidCached(): string {
  return ensureMetaLoaded().uid;
}

export function getTbsCached(): string {
  return ensureMetaLoaded().tbs;
}

export function getZidCached(): string {
  return ensureMetaLoaded().zid;
}

export function setUidCached(uid: string): void {
  persistMeta({ ...ensureMetaLoaded(), uid: uid ?? '' });
}

export function setTbsCached(tbs: string): void {
  persistMeta({ ...ensureMetaLoaded(), tbs: tbs ?? '' });
}

export function setZidCached(zid: string): void {
  persistMeta({ ...ensureMetaLoaded(), zid: zid ?? '' });
}

export function setCurrentMetaCached(next: CurrentMeta): void {
  persistMeta({
    uid: next.uid ?? '',
    tbs: next.tbs ?? '',
    zid: next.zid ?? '',
  });
}

export function clearMetaCache(): void {
  meta = { uid: '', tbs: '', zid: '' };
  metaLoaded = true;
  kvRemoveSync(keys.CURRENT_META);
  for (const key of [keys.LEGACY_UID, keys.LEGACY_TBS, keys.LEGACY_ZID]) {
    kvRemoveSync(key);
  }
  persistSecureValue(ACTIVE_KEYS.TBS, '');
  persistSecureValue(ACTIVE_KEYS.ZID, '');
}

/**
 * 仅清内存态（凭据 + meta），**不触碰 Keychain / SQLite 持久数据**。
 * 2026-08-27 新增：handleAuthExpired 的温和化——服务端单接口返回
 * error_code=1 时不应抹掉用户登录（旧实现 clearAllAuthSync 全毁，
 * 导致 reload 后必须重新登录）；临时登出后下次启动 checkAuth 可用
 * 持久数据自动恢复。
 */
export function clearMemoryOnly(): void {
  memory = { bduss: '', stoken: '', cookie: '', tbs: '', zid: '' };
  if (metaLoaded) {
    meta = { uid: '', tbs: '', zid: '' };
  }
}

// ------------------------------------------------------------
// Async per-account credential persistence
// ------------------------------------------------------------

export async function loadAccountCredentials(uid: string): Promise<AccountCredentials> {
  if (!uid) return { bduss: '', stoken: '', cookie: '', tbs: '', zid: '' };
  const [bduss, stoken, cookie, tbs, zid] = await Promise.all([
    SecureStore.getItemAsync(accountCredentialKey(uid, 'bduss')),
    SecureStore.getItemAsync(accountCredentialKey(uid, 'stoken')),
    SecureStore.getItemAsync(accountCredentialKey(uid, 'cookie')),
    SecureStore.getItemAsync(accountCredentialKey(uid, 'tbs')),
    SecureStore.getItemAsync(accountCredentialKey(uid, 'zid')),
  ]);
  return {
    bduss: bduss ?? '',
    stoken: stoken ?? '',
    cookie: cookie ?? '',
    tbs: tbs ?? '',
    zid: zid ?? '',
  };
}

/**
 * Persist credentials for an account, then mirror them into the active cache.
 * 账号隔离副本含 tbs/zid（切号恢复用）；活跃 tbs/zid 由 persistMeta 单点写
 * （saveAccountSync → setCurrentMetaCached），此处不重复写 ACTIVE 键。
 */
export async function persistAccountCredentials(
  uid: string,
  credentials: AccountCredentials,
): Promise<void> {
  if (!uid) return;
  const bduss = credentials.bduss ?? '';
  const stoken = credentials.stoken ?? '';
  const cookie = credentials.cookie ?? '';
  const tbs = credentials.tbs ?? '';
  const zid = credentials.zid ?? '';

  memory = { bduss, stoken, cookie, tbs, zid };

  await Promise.all([
    SecureStore.setItemAsync(accountCredentialKey(uid, 'bduss'), bduss, SECURE_STORE_OPTIONS),
    SecureStore.setItemAsync(accountCredentialKey(uid, 'stoken'), stoken, SECURE_STORE_OPTIONS),
    SecureStore.setItemAsync(accountCredentialKey(uid, 'cookie'), cookie, SECURE_STORE_OPTIONS),
    SecureStore.setItemAsync(ACTIVE_KEYS.BDUSS, bduss, SECURE_STORE_OPTIONS),
    SecureStore.setItemAsync(ACTIVE_KEYS.STOKEN, stoken, SECURE_STORE_OPTIONS),
    SecureStore.setItemAsync(ACTIVE_KEYS.COOKIE, cookie, SECURE_STORE_OPTIONS),
  ]);
  persistSecureValue(accountCredentialKey(uid, 'tbs'), tbs);
  persistSecureValue(accountCredentialKey(uid, 'zid'), zid);
}

export async function deleteAccountCredentials(uid: string): Promise<void> {
  if (!uid) return;
  await Promise.all([
    SecureStore.deleteItemAsync(accountCredentialKey(uid, 'bduss')),
    SecureStore.deleteItemAsync(accountCredentialKey(uid, 'stoken')),
    SecureStore.deleteItemAsync(accountCredentialKey(uid, 'cookie')),
    SecureStore.deleteItemAsync(accountCredentialKey(uid, 'tbs')).catch(() => {}),
    SecureStore.deleteItemAsync(accountCredentialKey(uid, 'zid')).catch(() => {}),
  ]);
}

export async function clearSecureCredentials(): Promise<void> {
  memory = { bduss: '', stoken: '', cookie: '', tbs: '', zid: '' };
  await Promise.all([
    SecureStore.deleteItemAsync(ACTIVE_KEYS.BDUSS),
    SecureStore.deleteItemAsync(ACTIVE_KEYS.STOKEN),
    SecureStore.deleteItemAsync(ACTIVE_KEYS.COOKIE),
  ]);
}

// ------------------------------------------------------------
// Redaction helpers for SQLite account metadata
// ------------------------------------------------------------

/**
 * 删除账号对象中的敏感字段，保留其余字段形状。bduss/sToken/cookie 是登录
 * 凭据；tbs/zid 是会话令牌（F2 迁 Keychain 后同样不进 MMKV）。
 */
export function redact<T extends object>(raw: T): T {
  const copy: T = { ...raw };
  for (const field of ['bduss', 'sToken', 'cookie', 'tbs', 'zid'] as const) {
    delete (copy as Record<string, unknown>)[field];
  }
  return copy;
}

function readRawAccount(uid: string): Record<string, unknown> | null {
  return parseJson<Record<string, unknown>>(kvGetSync(`${keys.ACCOUNT_PREFIX}${uid}`));
}

function readRawAccountList(): Record<string, unknown>[] {
  const parsed = parseJson<Record<string, unknown>[]>(kvGetSync(keys.ACCOUNT_LIST));
  return Array.isArray(parsed) ? parsed : [];
}

function writeRedactedAccountList(list: Record<string, unknown>[]): void {
  kvSetSync(keys.ACCOUNT_LIST, JSON.stringify(list.map(redact)));
}

// ------------------------------------------------------------
// Hydration / one-time migration
// ------------------------------------------------------------

function getStringField(account: Record<string, unknown> | null, field: string): string {
  const value = account?.[field];
  return typeof value === 'string' ? value : '';
}

/**
 * Load SecureStore credentials into memory and migrate legacy plaintext
 * SQLite keys / embedded account-JSON credentials once.
 *
 * Safe to call repeatedly: after the first successful run it becomes a
 * cheap no-op (new credentials are kept in memory by the sync setters).
 */
export async function hydrateSecureCredentials(): Promise<void> {
  await ensureUnifiedStorageReady();
  if (hydrated) return;
  if (hydratePromise) return hydratePromise;

  const run = (async () => {
    const activeId = kvGetSync(keys.ACTIVE_ID) ?? '';
    const activeAccount = activeId ? readRawAccount(activeId) : null;
    const legacyUid = kvGetSync(keys.LEGACY_UID) ?? '';
    const legacyTbs = kvGetSync(keys.LEGACY_TBS) ?? '';
    const legacyZid = kvGetSync(keys.LEGACY_ZID) ?? '';

    let bduss = await SecureStore.getItemAsync(ACTIVE_KEYS.BDUSS).catch(() => null);
    let stoken = await SecureStore.getItemAsync(ACTIVE_KEYS.STOKEN).catch(() => null);
    let cookie = await SecureStore.getItemAsync(ACTIVE_KEYS.COOKIE).catch(() => null);
    let activeTbs = await SecureStore.getItemAsync(ACTIVE_KEYS.TBS).catch(() => null);
    let activeZid = await SecureStore.getItemAsync(ACTIVE_KEYS.ZID).catch(() => null);

    // Legacy plaintext kv-store keys (one-time migration).
    const legacyBduss = kvGetSync(keys.LEGACY_BDUSS) ?? '';
    const legacyStoken = kvGetSync(keys.LEGACY_STOKEN) ?? '';
    const legacyCookie = kvGetSync(keys.LEGACY_COOKIE) ?? '';
    if (!bduss && legacyBduss) bduss = legacyBduss;
    if (!stoken && legacyStoken) stoken = legacyStoken;
    if (!cookie && legacyCookie) cookie = legacyCookie;

    // F2 迁移源：tbs/zid 原本明文散落在 CURRENT_META（三字段 JSON）、
    // 单键 LEGACY_TBS/ZID 与账号 JSON 里，Keychain 缺失时按序回填。
    const legacyMetaRaw = parseJson<Partial<CurrentMeta>>(kvGetSync(keys.CURRENT_META));
    const legacyMetaHasSecrets = !!(
      (legacyMetaRaw?.tbs && typeof legacyMetaRaw.tbs === 'string') ||
      (legacyMetaRaw?.zid && typeof legacyMetaRaw.zid === 'string')
    );
    if (!activeTbs) {
      activeTbs =
        (typeof legacyMetaRaw?.tbs === 'string' ? legacyMetaRaw.tbs : '') ||
        legacyTbs ||
        getStringField(activeAccount, 'tbs') ||
        null;
    }
    if (!activeZid) {
      activeZid =
        (typeof legacyMetaRaw?.zid === 'string' ? legacyMetaRaw.zid : '') ||
        legacyZid ||
        getStringField(activeAccount, 'zid') ||
        null;
    }

    // Old account JSONs embedded credentials too; migrate them as well.
    if (!bduss) bduss = getStringField(activeAccount, 'bduss') || null;
    if (!stoken) stoken = getStringField(activeAccount, 'sToken') || null;
    if (!cookie) cookie = getStringField(activeAccount, 'cookie') || null;

    // Migrate every account in the list into per-account SecureStore keys.
    const rawList = readRawAccountList();
    for (const raw of rawList) {
      const uid = getStringField(raw, 'uid');
      if (!uid) continue;
      const existing = await loadAccountCredentials(uid);
      const jsonBduss = getStringField(raw, 'bduss');
      const jsonStoken = getStringField(raw, 'sToken');
      const jsonCookie = getStringField(raw, 'cookie');
      const jsonTbs = getStringField(raw, 'tbs');
      const jsonZid = getStringField(raw, 'zid');
      if (!existing.bduss && jsonBduss) {
        await SecureStore.setItemAsync(
          accountCredentialKey(uid, 'bduss'),
          jsonBduss,
          SECURE_STORE_OPTIONS,
        );
      }
      if (!existing.stoken && jsonStoken) {
        await SecureStore.setItemAsync(
          accountCredentialKey(uid, 'stoken'),
          jsonStoken,
          SECURE_STORE_OPTIONS,
        );
      }
      if (!existing.cookie && jsonCookie) {
        await SecureStore.setItemAsync(
          accountCredentialKey(uid, 'cookie'),
          jsonCookie,
          SECURE_STORE_OPTIONS,
        );
      }
      // F2：账号 JSON 里内嵌的 tbs/zid 一并迁 Keychain。
      if (!existing.tbs && jsonTbs) {
        await SecureStore.setItemAsync(
          accountCredentialKey(uid, 'tbs'),
          jsonTbs,
          SECURE_STORE_OPTIONS,
        );
      }
      if (!existing.zid && jsonZid) {
        await SecureStore.setItemAsync(
          accountCredentialKey(uid, 'zid'),
          jsonZid,
          SECURE_STORE_OPTIONS,
        );
      }
    }

    // Persist the migrated active values.
    const migrated: AccountCredentials = {
      bduss: bduss ?? '',
      stoken: stoken ?? '',
      cookie: cookie ?? '',
      tbs: activeTbs ?? '',
      zid: activeZid ?? '',
    };
    if (activeId) {
      await Promise.all([
        SecureStore.setItemAsync(
          accountCredentialKey(activeId, 'bduss'),
          migrated.bduss,
          SECURE_STORE_OPTIONS,
        ),
        SecureStore.setItemAsync(
          accountCredentialKey(activeId, 'stoken'),
          migrated.stoken,
          SECURE_STORE_OPTIONS,
        ),
        SecureStore.setItemAsync(
          accountCredentialKey(activeId, 'cookie'),
          migrated.cookie,
          SECURE_STORE_OPTIONS,
        ),
        SecureStore.setItemAsync(ACTIVE_KEYS.BDUSS, migrated.bduss, SECURE_STORE_OPTIONS),
        SecureStore.setItemAsync(ACTIVE_KEYS.STOKEN, migrated.stoken, SECURE_STORE_OPTIONS),
        SecureStore.setItemAsync(ACTIVE_KEYS.COOKIE, migrated.cookie, SECURE_STORE_OPTIONS),
      ]);
      persistSecureValue(accountCredentialKey(activeId, 'tbs'), migrated.tbs);
      persistSecureValue(accountCredentialKey(activeId, 'zid'), migrated.zid);
    }

    // Delete legacy plaintext keys.
    for (const key of LEGACY_PLAINTEXT_KEYS) {
      kvRemoveSync(key);
    }
    for (const key of [keys.LEGACY_UID, keys.LEGACY_TBS, keys.LEGACY_ZID]) {
      kvRemoveSync(key);
    }

    // 活跃 meta 收敛（F2）：uid 读 SQLite，tbs/zid 用迁移结果；有旧明文
    // 痕迹时经 persistMeta 统一落盘（Keychain + 重写 uid-only CURRENT_META），
    // 否则只回填内存，避免每次冷启动对缺失键空删。
    const resolvedUid = legacyUid || loadUidFromSqlite() || activeId;
    if (legacyUid || legacyTbs || legacyZid || legacyMetaHasSecrets) {
      persistMeta({ uid: resolvedUid, tbs: migrated.tbs, zid: migrated.zid });
    } else {
      meta = { uid: resolvedUid, tbs: migrated.tbs, zid: migrated.zid };
      metaLoaded = true;
    }

    // Strip credentials from all SQLite account metadata.
    if (activeId) {
      const redacted = redact(activeAccount ?? {});
      kvSetSync(`${keys.ACCOUNT_PREFIX}${activeId}`, JSON.stringify(redacted));
    }
    for (const raw of rawList) {
      const uid = getStringField(raw, 'uid');
      if (!uid) continue;
      const existingRaw = readRawAccount(uid);
      if (existingRaw) {
        kvSetSync(`${keys.ACCOUNT_PREFIX}${uid}`, JSON.stringify(redact(existingRaw)));
      }
    }
    writeRedactedAccountList(rawList);

    memory = migrated;
  })();

  hydratePromise = run;
  try {
    await run;
    hydrated = true;
  } finally {
    if (hydratePromise === run) hydratePromise = null;
  }
}
