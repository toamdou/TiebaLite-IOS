/**
 * Unified search history repository backed by the shared SQLite database
 * (`tiebalite.db`, same home as preferences/account metadata/history).
 */
import { ensureUnifiedStorageReady, getDbAsync } from '@/services/storage/unifiedDb';

export interface SearchHistoryItem {
  keyword: string;
  timestamp: number;
  /** Present only for forum-scoped history. */
  forumId?: string;
}

const DEFAULT_LIMIT = 20;

interface SearchHistoryRow {
  forum_id: string;
  keyword: string;
  timestamp: number;
}

function dedupeCaseInsensitive(items: SearchHistoryItem[]): SearchHistoryItem[] {
  const seen = new Set<string>();
  const result: SearchHistoryItem[] = [];
  for (const item of items) {
    const key = `${(item.forumId ?? '')}:${item.keyword.toLowerCase()}`;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(item);
  }
  return result;
}

function sortByTime(items: SearchHistoryItem[]): SearchHistoryItem[] {
  return [...items].sort((a, b) => b.timestamp - a.timestamp);
}

function scoped(items: SearchHistoryItem[], forumId?: string): SearchHistoryItem[] {
  return items.filter((item) => (item.forumId ?? '') === (forumId ?? ''));
}

function rowToItem(row: SearchHistoryRow): SearchHistoryItem {
  return {
    keyword: row.keyword,
    timestamp: row.timestamp,
    forumId: row.forum_id || undefined,
  };
}

async function readAllEntries(): Promise<SearchHistoryItem[]> {
  await ensureUnifiedStorageReady();
  const db = await getDbAsync();
  const rows = await db.getAllAsync<SearchHistoryRow>(
    'SELECT forum_id, keyword, timestamp FROM search_history ORDER BY timestamp DESC, id DESC',
  );
  return dedupeCaseInsensitive(rows.map(rowToItem));
}

async function ensureMigrated(): Promise<void> {
  // 遗留存储迁移已随 AsyncStorage 依赖移除一并删除；
  // 保留启动收敛语义（库打开 + 各类一次性迁移完成）。
  await ensureUnifiedStorageReady();
}

export async function loadSearchHistory(
  forumId?: string,
  limit: number = DEFAULT_LIMIT,
): Promise<SearchHistoryItem[]> {
  await ensureMigrated();
  return scoped(await readAllEntries(), forumId).slice(0, limit);
}

export async function appendSearchHistory(
  keyword: string,
  forumId?: string,
  limit: number = DEFAULT_LIMIT,
): Promise<SearchHistoryItem[]> {
  await ensureMigrated();
  const trimmed = keyword.trim();
  if (!trimmed) return scoped(await readAllEntries(), forumId).slice(0, limit);

  const scope = forumId ?? '';
  const db = await getDbAsync();
  await db.withTransactionAsync(async () => {
    await db.runAsync(
      'DELETE FROM search_history WHERE forum_id = ? AND lower(keyword) = lower(?)',
      scope,
      trimmed,
    );
    await db.runAsync(
      'INSERT INTO search_history (forum_id, keyword, timestamp) VALUES (?, ?, ?)',
      scope,
      trimmed,
      Date.now(),
    );
    await db.runAsync(
      `DELETE FROM search_history WHERE forum_id = ? AND id NOT IN (
        SELECT id FROM search_history WHERE forum_id = ? ORDER BY timestamp DESC, id DESC LIMIT ?
      )`,
      scope,
      scope,
      limit,
    );
  });
  return scoped(await readAllEntries(), forumId).slice(0, limit);
}

export async function removeSearchHistory(
  keyword: string,
  forumId?: string,
): Promise<SearchHistoryItem[]> {
  await ensureMigrated();
  const db = await getDbAsync();
  await db.runAsync(
    'DELETE FROM search_history WHERE forum_id = ? AND lower(keyword) = lower(?)',
    forumId ?? '',
    keyword.trim(),
  );
  return sortByTime(scoped(await readAllEntries(), forumId));
}

export async function clearSearchHistory(forumId?: string): Promise<void> {
  await ensureMigrated();
  await (await getDbAsync()).runAsync(
    'DELETE FROM search_history WHERE forum_id = ?',
    forumId ?? '',
  );
}
