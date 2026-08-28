/**
 * Unified visit history (threads + forums), backed by the shared SQLite
 * database.
 */
import { ensureUnifiedStorageReady, getDbAsync } from '@/services/storage/unifiedDb';
import { getPreferences } from '@/services/storage/PreferencesStorage';
import type { HistoryItem } from '@/types';

const MAX_ITEMS = 200;

export interface ForumHistoryItem {
  forumName: string;
  forumId: string;
  avatar?: string;
  visitedAt: number;
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

function dedupe(items: HistoryItem[]): HistoryItem[] {
  const seen = new Set<string>();
  const result: HistoryItem[] = [];
  for (const item of items) {
    const key = `${item.type}-${item.threadId ?? item.forumName ?? item.id}`;
    if (seen.has(key)) continue;
    seen.add(key);
    result.push(item);
  }
  return result;
}

function rowToItem(row: VisitHistoryRow): HistoryItem {
  const id =
    row.type === 'forum'
      ? row.forum_id || row.forum_name || String(row.id)
      : row.thread_id || String(row.id);
  return {
    id,
    type: row.type,
    threadId: row.thread_id || undefined,
    forumId: row.forum_id || undefined,
    forumName: row.forum_name || undefined,
    avatar: row.avatar || undefined,
    title: row.title || undefined,
    authorName: row.author_name || undefined,
    authorPortrait: row.author_portrait || undefined,
    timestamp: row.timestamp,
  };
}

async function readAllEntries(): Promise<HistoryItem[]> {
  await ensureUnifiedStorageReady();
  const db = await getDbAsync();
  const rows = await db.getAllAsync<VisitHistoryRow>(
    `SELECT id, type, thread_id, forum_id, forum_name, avatar, title, author_name, author_portrait, timestamp
     FROM visit_history ORDER BY timestamp DESC, id DESC`,
  );
  return dedupe(rows.map(rowToItem));
}

export async function getVisitHistory(
  type?: 'thread' | 'forum',
): Promise<HistoryItem[]> {
  const all = await readAllEntries();
  return type ? all.filter((item) => item.type === type) : all;
}

async function addVisit(item: HistoryItem): Promise<void> {
  try {
    const prefs = await getPreferences();
    if (prefs.incognitoMode) return;
    await ensureUnifiedStorageReady();

    const db = await getDbAsync();
    const threadId = item.type === 'thread' ? item.threadId ?? item.id : '';
    const forumId = item.forumId ?? '';
    const forumName = item.forumName ?? '';

    await db.withTransactionAsync(async () => {
      if (item.type === 'thread') {
        await db.runAsync(
          'DELETE FROM visit_history WHERE type = ? AND thread_id = ?',
          'thread',
          threadId,
        );
      } else {
        await db.runAsync(
          'DELETE FROM visit_history WHERE type = ? AND forum_name = ?',
          'forum',
          forumName,
        );
      }

      await db.runAsync(
        `INSERT INTO visit_history (
          type, thread_id, forum_id, forum_name, avatar, title, author_name, author_portrait, timestamp
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
        item.type,
        threadId,
        forumId,
        forumName,
        item.avatar ?? '',
        item.title ?? '',
        item.authorName ?? '',
        item.authorPortrait ?? '',
        item.timestamp,
      );

      await db.runAsync(
        `DELETE FROM visit_history WHERE id NOT IN (
          SELECT id FROM visit_history ORDER BY timestamp DESC, id DESC LIMIT ?
        )`,
        MAX_ITEMS,
      );
    });
  } catch {}
}

export async function recordThreadVisit(item: HistoryItem): Promise<void> {
  await addVisit({ ...item, type: 'thread' });
}

/**
 * 历史记录里的头像引用按"缓存内容"对待：随"清除图片缓存"一并擦除。
 * 帖记录清发帖人头像（author_portrait），吧记录清吧头像（avatar）；
 * 记录本身（标题/吧名/时间）保留，头像回落首字占位，下次访问重新入库。
 */
export async function clearHistoryAuthorPortraits(): Promise<void> {
  try {
    await ensureUnifiedStorageReady();
    const db = await getDbAsync();
    await db.runAsync(
      "UPDATE visit_history SET author_portrait = '' WHERE type = 'thread'",
    );
    // 吧记录的头像挂在 avatar 列，同一清除语义下必须一并擦除
    await db.runAsync("UPDATE visit_history SET avatar = '' WHERE type = 'forum'");
  } catch {}
}

/**
 * 回填历史记录缺失的作者信息（老记录当年只存了标题+时间）。
 * 只补空字段，不覆盖已有的吧名/作者名。
 */
export async function updateThreadAuthorInfo(
  threadId: string,
  info: { authorName?: string; authorPortrait?: string; forumName?: string },
): Promise<void> {
  try {
    await ensureUnifiedStorageReady();
    const db = await getDbAsync();
    await db.runAsync(
      `UPDATE visit_history SET
         author_name = CASE WHEN author_name = '' THEN ? ELSE author_name END,
         author_portrait = CASE WHEN author_portrait = '' THEN ? ELSE author_portrait END,
         forum_name = CASE WHEN forum_name = '' THEN ? ELSE forum_name END
       WHERE type = 'thread' AND thread_id = ?`,
      info.authorName ?? '',
      info.authorPortrait ?? '',
      info.forumName ?? '',
      threadId,
    );
  } catch {}
}

export async function recordForumVisit(item: HistoryItem): Promise<void> {
  await addVisit({ ...item, type: 'forum' });
}

export async function removeVisit(
  predicate: (item: HistoryItem) => boolean,
): Promise<HistoryItem[]> {
  await ensureUnifiedStorageReady();
  const db = await getDbAsync();
  const rows = await db.getAllAsync<VisitHistoryRow>(
    `SELECT id, type, thread_id, forum_id, forum_name, avatar, title, author_name, author_portrait, timestamp
     FROM visit_history ORDER BY timestamp DESC, id DESC`,
  );
  const items = rows.map(rowToItem);
  const idsToRemove = rows
    .filter((_row, index) => predicate(items[index]))
    .map((row) => row.id);

  if (idsToRemove.length > 0) {
    // 单条 IN 批量删除（原实现逐行 DELETE 后重读全表）：一次写库，
    // 返回结果走内存 filter 取反，免删后二次读库。
    const placeholders = idsToRemove.map(() => '?').join(', ');
    await db.runAsync(
      `DELETE FROM visit_history WHERE id IN (${placeholders})`,
      ...idsToRemove,
    );
  }

  return dedupe(items.filter((_item, index) => !predicate(items[index])));
}

export async function clearVisitHistory(type?: 'thread' | 'forum'): Promise<void> {
  await ensureUnifiedStorageReady();
  const db = await getDbAsync();
  if (type) {
    await db.runAsync('DELETE FROM visit_history WHERE type = ?', type);
  } else {
    await db.runAsync('DELETE FROM visit_history');
  }
}

export function toForumHistoryItem(item: HistoryItem): ForumHistoryItem | null {
  if (item.type !== 'forum' || !item.forumName) return null;
  return {
    forumName: item.forumName,
    forumId: item.forumId ?? '',
    avatar: item.avatar ?? '',
    visitedAt: item.timestamp,
  };
}
