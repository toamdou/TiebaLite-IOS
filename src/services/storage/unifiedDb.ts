// ============================================================
// Unified storage facade
//
// Key-value state (preferences, account metadata, block lists, live
// activity id, notification baselines, BAIDUID, etc.) lives in a
// dedicated MMKV instance: fully synchronous reads/writes, persisted
// outside SQLite. The legacy SQLite kv table is kept only as a frozen
// rollback snapshot and is drained once into MMKV on first run.
// search_history / visit_history stay in SQLite (relational queries).
// Credentials (BDUSS/STOKEN/COOKIE) stay exclusively in Keychain via
// expo-secure-store and are never written here.
// ============================================================

import { createMMKV } from 'react-native-mmkv';
import KVStorage from 'expo-sqlite/kv-store';
import {
  deleteDatabaseAsync,
  openDatabaseAsync,
  type SQLiteDatabase,
} from 'expo-sqlite';

const DB_NAME = 'tiebalite.db';
const MIGRATION_KEY = '@tiebalite:unified_migration_v1';
// 旧 SQLite kv 表 → MMKV 一次性搬运的标记（存在 MMKV 里）
const KV_TABLE_MIGRATION_KEY = '@tiebalite:mmkv_kv_table_drain_v1';

let dbPromise: Promise<SQLiteDatabase> | null = null;

// kv 后端：专用 MMKV 实例，读写全同步、独立于 SQLite 文件持久化。
const kvStore = createMMKV({ id: 'tiebalite.kv' });
// 本次会话已完成 kv 表搬运（标记命中后不再扫表）
let sqliteKvDrained = false;

interface SearchHistoryRow {
  forum_id: string;
  keyword: string;
  timestamp: number;
}

interface VisitHistoryRow {
  id: number;
  type: 'thread' | 'forum';
  thread_id: string;
  forum_id: string;
  forum_name: string;
  avatar: string;
  title: string;
  author_name: string;
  author_portrait: string;
  timestamp: number;
}

async function createSchemaAsync(database: SQLiteDatabase): Promise<void> {
  await database.execAsync(`
    CREATE TABLE IF NOT EXISTS kv (
      key TEXT PRIMARY KEY NOT NULL,
      value TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS search_history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      forum_id TEXT NOT NULL DEFAULT '',
      keyword TEXT NOT NULL,
      timestamp INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_search_history_scope_time
      ON search_history(forum_id, timestamp DESC, id DESC);
    CREATE TABLE IF NOT EXISTS visit_history (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      type TEXT NOT NULL,
      thread_id TEXT NOT NULL DEFAULT '',
      forum_id TEXT NOT NULL DEFAULT '',
      forum_name TEXT NOT NULL DEFAULT '',
      avatar TEXT NOT NULL DEFAULT '',
      title TEXT NOT NULL DEFAULT '',
      author_name TEXT NOT NULL DEFAULT '',
      author_portrait TEXT NOT NULL DEFAULT '',
      timestamp INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_visit_history_type_time
      ON visit_history(type, timestamp DESC, id DESC);
  `);

  // 既有库升级：旧表无 author_portrait 列，补列（CREATE IF NOT EXISTS 不会加列）
  const hasPortraitCol = await database.getFirstAsync<{ name: string }>(
    `SELECT name FROM pragma_table_info('visit_history') WHERE name = 'author_portrait'`,
  );
  if (!hasPortraitCol) {
    await database.execAsync(
      `ALTER TABLE visit_history ADD COLUMN author_portrait TEXT NOT NULL DEFAULT '';`,
    );
  }
}

async function migrateLegacyKvStoreAsync(database: SQLiteDatabase): Promise<void> {
  try {
    const marker = await database.getFirstAsync<{ value: string }>(
      'SELECT value FROM kv WHERE key = ?',
      MIGRATION_KEY,
    );
    if (marker) return;

    const keys = await KVStorage.getAllKeys();
    if (keys.length > 0) {
      await database.withTransactionAsync(async () => {
        for (const key of keys) {
          const existing = await database.getFirstAsync<{ value: string }>(
            'SELECT value FROM kv WHERE key = ?',
            key,
          );
          if (existing) continue;
          const value = await KVStorage.getItem(key);
          if (value == null) continue;
          await database.runAsync(
            'INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)',
            key,
            value,
          );
        }
      });
    }
    await database.runAsync(
      'INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)',
      MIGRATION_KEY,
      JSON.stringify({ migratedAt: Date.now() }),
    );
    try {
      await KVStorage.clear();
    } catch {}
  } catch (error) {
    console.warn('[UnifiedDb] Legacy kv-store migration failed:', error);
  }
}

async function migrateLegacySqliteTablesAsync(
  database: SQLiteDatabase,
): Promise<void> {
  try {
    const searchCount =
      (await database.getFirstAsync<{ count: number }>(
        'SELECT COUNT(*) AS count FROM search_history',
      ))?.count ?? 0;
    if (searchCount === 0) {
      try {
        const legacy = await openDatabaseAsync('tiebalite_search_history.db');
        const rows = await legacy.getAllAsync<SearchHistoryRow>(
          'SELECT forum_id, keyword, timestamp FROM search_history ORDER BY timestamp DESC, id DESC',
        );
        if (rows.length > 0) {
          await database.withTransactionAsync(async () => {
            for (const row of rows) {
              await database.runAsync(
                'INSERT INTO search_history (forum_id, keyword, timestamp) VALUES (?, ?, ?)',
                row.forum_id,
                row.keyword,
                row.timestamp,
              );
            }
          });
        }
        await legacy.closeAsync();
        try {
          await deleteDatabaseAsync('tiebalite_search_history.db');
        } catch {}
      } catch {}
    }

    const visitCount =
      (await database.getFirstAsync<{ count: number }>(
        'SELECT COUNT(*) AS count FROM visit_history',
      ))?.count ?? 0;
    if (visitCount === 0) {
      try {
        const legacy = await openDatabaseAsync('tiebalite_visit_history.db');
        const rows = await legacy.getAllAsync<VisitHistoryRow>(
          `SELECT id, type, thread_id, forum_id, forum_name, avatar, title, author_name, timestamp
           FROM visit_history ORDER BY timestamp DESC, id DESC`,
        );
        if (rows.length > 0) {
          await database.withTransactionAsync(async () => {
            for (const row of rows) {
              await database.runAsync(
                `INSERT INTO visit_history (
                  type, thread_id, forum_id, forum_name, avatar, title, author_name, author_portrait, timestamp
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
                row.type,
                row.thread_id,
                row.forum_id,
                row.forum_name,
                row.avatar,
                row.title,
                row.author_name,
                row.author_portrait ?? '',
                row.timestamp,
              );
            }
          });
        }
        await legacy.closeAsync();
        try {
          await deleteDatabaseAsync('tiebalite_visit_history.db');
        } catch {}
      } catch {}
    }
  } catch (error) {
    console.warn('[UnifiedDb] Legacy SQLite migration failed:', error);
  }
}

/**
 * 一次性把旧 SQLite kv 表内容搬进 MMKV（连同历史迁移标记键）。表保留作
 * 回滚快照，此后不再读写；标记存 MMKV，contains 守卫防止搬运窗口内
 * 已直写 MMKV 的新值被表内旧值覆盖。
 */
async function drainSqliteKvTableIntoMmkvAsync(
  database: SQLiteDatabase,
): Promise<void> {
  if (sqliteKvDrained) return;
  if (kvStore.contains(KV_TABLE_MIGRATION_KEY)) {
    sqliteKvDrained = true;
    return;
  }
  const rows = await database.getAllAsync<{ key: string; value: string }>(
    'SELECT key, value FROM kv',
  );
  for (const row of rows) {
    if (kvStore.contains(row.key)) continue;
    kvStore.set(row.key, row.value);
  }
  kvStore.set(
    KV_TABLE_MIGRATION_KEY,
    JSON.stringify({ migratedAt: Date.now() }),
  );
  sqliteKvDrained = true;
}

export async function getDbAsync(): Promise<SQLiteDatabase> {
  if (!dbPromise) {
    dbPromise = (async () => {
      const database = await openDatabaseAsync(DB_NAME);
      await createSchemaAsync(database);
      await migrateLegacyKvStoreAsync(database);
      await migrateLegacySqliteTablesAsync(database);
      await drainSqliteKvTableIntoMmkvAsync(database);
      return database;
    })();
  }
  return dbPromise;
}

// ------------------------------------------------------------
// Sync kv API (MMKV-backed; fully synchronous, no queue)
// ------------------------------------------------------------

export function kvGetSync(key: string): string | null {
  // 与旧实现同款懒启动：尽早触发库打开与 kv 表搬运
  if (!dbPromise) void getDbAsync().catch(() => {});
  return kvStore.getString(key) ?? null;
}

export function kvSetSync(key: string, value: string): void {
  // MMKV 写入同步落盘，无需内存缓存/写队列/pending 防覆盖机制
  kvStore.set(key, value);
}

export function kvRemoveSync(key: string): void {
  kvStore.remove(key);
}

export function kvBatchSync(
  writes: { key: string; value: string | null }[],
): void {
  for (const write of writes) {
    if (write.value === null) {
      kvStore.remove(write.key);
    } else {
      kvStore.set(write.key, write.value);
    }
  }
}

export function getAllKeysSync(prefix?: string): string[] {
  return kvStore
    .getAllKeys()
    .filter((key) => !prefix || key.startsWith(prefix))
    .sort();
}

export function clearAllKvSync(prefix?: string): void {
  if (prefix) {
    for (const key of kvStore.getAllKeys()) {
      if (key.startsWith(prefix)) kvStore.remove(key);
    }
    return;
  }
  // 全清时保留两个迁移标记：否则旧 kv 表/legacy 源若未同时清空，
  // 下次启动会把旧数据重新灌回（清空复活）。
  const markers = [MIGRATION_KEY, KV_TABLE_MIGRATION_KEY];
  const preserved = markers
    .map((key) => [key, kvStore.getString(key)] as const)
    .filter((pair): pair is readonly [string, string] => pair[1] != null);
  kvStore.clearAll();
  for (const [key, value] of preserved) kvStore.set(key, value);
}

// ------------------------------------------------------------
// Async kv API
// ------------------------------------------------------------

export async function ensureUnifiedStorageReady(): Promise<void> {
  // 启动链路收敛点：库打开、遗留迁移与 kv 表搬运全部就绪后才返回，
  // 不拖住 splash 隐藏 / checkAuth 等路径（各迁移均有持久化标记）。
  await getDbAsync();
}

export async function kvGet(key: string): Promise<string | null> {
  await ensureUnifiedStorageReady();
  return kvGetSync(key);
}

export async function kvSet(key: string, value: string): Promise<void> {
  await ensureUnifiedStorageReady();
  kvSetSync(key, value);
}

export async function kvRemove(key: string): Promise<void> {
  await ensureUnifiedStorageReady();
  kvRemoveSync(key);
}

export async function kvMultiGet(
  keys: string[],
): Promise<[string, string | null][]> {
  await ensureUnifiedStorageReady();
  return keys.map((key) => [key, kvGetSync(key)]);
}

export async function kvMultiSet(
  entries: [string, string][],
): Promise<void> {
  await ensureUnifiedStorageReady();
  kvBatchSync(entries.map(([key, value]) => ({ key, value })));
}

export async function kvMultiRemove(keys: string[]): Promise<void> {
  await ensureUnifiedStorageReady();
  kvBatchSync(keys.map((key) => ({ key, value: null })));
}

export async function getAllKeys(prefix?: string): Promise<string[]> {
  await ensureUnifiedStorageReady();
  return getAllKeysSync(prefix);
}

// ------------------------------------------------------------
// Clear helpers
// ------------------------------------------------------------

export async function clearLegacyStorage(): Promise<void> {
  try {
    await KVStorage.clear();
  } catch {
    // Legacy kv-store may not exist on every build.
  }
}

export async function clearAllUnifiedStorage(): Promise<void> {
  const database = await getDbAsync();
  await database.execAsync(
    'DELETE FROM kv; DELETE FROM search_history; DELETE FROM visit_history;',
  );
  clearAllKvSync();
  await clearLegacyStorage();
}
