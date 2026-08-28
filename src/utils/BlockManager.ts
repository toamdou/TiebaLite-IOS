import type { BlockedWord, BlockedUser } from '@/types';
import { emitBlockEvents } from './blockEvents';
import {
  getAllKeys,
  kvGet,
  kvMultiGet,
  kvMultiRemove,
  kvMultiSet,
  kvRemove,
  kvSet,
} from '@/services/storage/unifiedDb';

const BLOCKED_WORDS_KEY = '@tiebalite:blocked_words';
const BLOCKED_USERS_KEY = '@tiebalite:blocked_users';
const BLOCKED_WORD_PREFIX = '@tiebalite:blocked_word:';
const BLOCKED_USER_PREFIX = '@tiebalite:blocked_user:';

const compiledRegexCache = new Map<string, RegExp>();
const invalidRegexCache = new Set<string>();
let compiledBlockSnapshots = new WeakMap<BlockedWord[], CompiledBlockSnapshot>();

interface CompiledBlockWord {
  keyword: string;
  isRegex: boolean;
  regex: RegExp | null;
}

interface CompiledBlockSnapshot {
  whitelist: CompiledBlockWord[];
  blacklist: CompiledBlockWord[];
}

let blockStorageWriteQueue: Promise<void> = Promise.resolve();

function enqueueBlockStorageWrite(operation: () => Promise<void>): Promise<void> {
  const run = blockStorageWriteQueue.then(operation, operation);
  // 磁盘写失败不再无声：内存缓存此时已更新（add/remove 先改内存再排队写），
  // 磁盘漂移可被下次读/写/全清自愈，但若吞掉，排查屏蔽词丢失问题时无从下手。
  const onWriteFailure = (error: unknown) => {
    console.warn('[BlockManager] storage write failed:', error);
  };
  blockStorageWriteQueue = run.catch(onWriteFailure);
  return run.catch(onWriteFailure);
}

function blockedWordStorageKey(id: string): string {
  return `${BLOCKED_WORD_PREFIX}${id}`;
}

function blockedUserStorageKey(uid: string): string {
  return `${BLOCKED_USER_PREFIX}${uid}`;
}

function getCompiledRegex(pattern: string): RegExp | null {
  const cached = compiledRegexCache.get(pattern);
  if (cached) return cached;
  if (invalidRegexCache.has(pattern)) return null;
  try {
    const regex = new RegExp(pattern);
    compiledRegexCache.set(pattern, regex);
    return regex;
  } catch {
    invalidRegexCache.add(pattern);
    return null;
  }
}

function clearRegexCaches(): void {
  compiledRegexCache.clear();
  invalidRegexCache.clear();
  compiledBlockSnapshots = new WeakMap();
}

function compileBlockedWords(blockedWords: BlockedWord[]): CompiledBlockSnapshot {
  const whitelist: CompiledBlockWord[] = [];
  const blacklist: CompiledBlockWord[] = [];
  for (const word of blockedWords) {
    const compiled: CompiledBlockWord = word.isRegex
      ? { keyword: word.keyword, isRegex: true, regex: getCompiledRegex(word.keyword) }
      : { keyword: word.keyword, isRegex: false, regex: null };
    if (word.category === 'whitelist') {
      whitelist.push(compiled);
    } else {
      blacklist.push(compiled);
    }
  }
  return { whitelist, blacklist };
}

function getCompiledBlockSnapshot(blockedWords: BlockedWord[]): CompiledBlockSnapshot {
  const cached = compiledBlockSnapshots.get(blockedWords);
  if (cached) return cached;
  const compiled = compileBlockedWords(blockedWords);
  compiledBlockSnapshots.set(blockedWords, compiled);
  return compiled;
}

function matchCompiledBlockWord(content: string, word: CompiledBlockWord): boolean {
  if (word.isRegex) {
    return word.regex !== null && word.regex.test(content);
  }
  return content.includes(word.keyword);
}

function isValidBlockedWord(value: unknown): value is BlockedWord {
  const word = value as BlockedWord | null;
  return (
    word !== null &&
    typeof word === 'object' &&
    typeof word.id === 'string' &&
    typeof word.keyword === 'string'
  );
}

function isValidBlockedUser(value: unknown): value is BlockedUser {
  const user = value as BlockedUser | null;
  return (
    user !== null &&
    typeof user === 'object' &&
    typeof user.id === 'string' &&
    typeof user.uid === 'string'
  );
}

// ── 词/用户双轨的参数化读取（thermo 2026-08-26 Z9-A）──
// 两类屏蔽项的「逐项键读取 + legacy 数组键一次性迁移」逻辑完全同构，
// 收敛为配置驱动的单一实现；写路径（enqueue 迁移回填）语义保持不变。
interface BlockedListConfig<T> {
  prefix: string;
  legacyKey: string;
  validate: (value: unknown) => value is T;
  /** 去重主键（词=id，用户=uid） */
  primaryOf: (item: T) => string;
  storageKeyOf: (primary: string) => string;
}

const WORD_LIST_CONFIG: BlockedListConfig<BlockedWord> = {
  prefix: BLOCKED_WORD_PREFIX,
  legacyKey: BLOCKED_WORDS_KEY,
  validate: isValidBlockedWord,
  primaryOf: (w) => w.id,
  storageKeyOf: blockedWordStorageKey,
};

const USER_LIST_CONFIG: BlockedListConfig<BlockedUser> = {
  prefix: BLOCKED_USER_PREFIX,
  legacyKey: BLOCKED_USERS_KEY,
  validate: isValidBlockedUser,
  primaryOf: (u) => u.uid,
  storageKeyOf: blockedUserStorageKey,
};

async function readBlockedItems<T>(cfg: BlockedListConfig<T>): Promise<T[]> {
  const [legacyJson, allKeys] = await Promise.all([
    kvGet(cfg.legacyKey),
    getAllKeys(),
  ]);
  const perItemKeys = allKeys.filter((key) => key.startsWith(cfg.prefix));
  const entries = perItemKeys.length > 0 ? await kvMultiGet(perItemKeys) : [];

  const items: T[] = [];
  const seenPrimaries = new Set<string>();
  for (const [, raw] of entries) {
    if (raw == null) continue;
    try {
      const item = JSON.parse(raw) as unknown;
      if (cfg.validate(item) && !seenPrimaries.has(cfg.primaryOf(item))) {
        seenPrimaries.add(cfg.primaryOf(item));
        items.push(item);
      }
    } catch {}
  }

  if (legacyJson) {
    try {
      const legacy = JSON.parse(legacyJson) as unknown;
      if (Array.isArray(legacy)) {
        for (const raw of legacy) {
          if (cfg.validate(raw) && !seenPrimaries.has(cfg.primaryOf(raw))) {
            seenPrimaries.add(cfg.primaryOf(raw));
            items.push(raw);
          }
        }
      }
    } catch {}

    await enqueueBlockStorageWrite(async () => {
      if (items.length > 0) {
        await kvMultiSet(
          items.map(
            (item) => [cfg.storageKeyOf(cfg.primaryOf(item)), JSON.stringify(item)] as [string, string],
          ),
        );
      }
      await kvRemove(cfg.legacyKey);
    });
  }

  return items;
}

let cachedBlockedWords: BlockedWord[] | null = null;
let cachedBlockedUsers: BlockedUser[] | null = null;
let blockedWordsLoadPromise: Promise<BlockedWord[]> | null = null;
let blockedUsersLoadPromise: Promise<BlockedUser[]> | null = null;

async function readBlockedWordsFromStorage(): Promise<BlockedWord[]> {
  return readBlockedItems(WORD_LIST_CONFIG);
}

function loadBlockedWords(): Promise<BlockedWord[]> {
  if (cachedBlockedWords) return Promise.resolve(cachedBlockedWords);
  if (!blockedWordsLoadPromise) {
    blockedWordsLoadPromise = (async () => {
      try {
        const words = await readBlockedWordsFromStorage();
        cachedBlockedWords = words;
        compiledBlockSnapshots.set(words, compileBlockedWords(words));
        return words;
      } catch (error) {
        // 读存储失败：打 warn 并保持缓存为 null——不写空数组兜底。
        // 吞成空列表会制造「屏蔽词已生效」假象，且后续 add/remove 会基于
        // 空列表覆盖磁盘数据；保持 null 让下次调用自动重试。
        console.warn('[BlockManager] 读取屏蔽词失败（缓存保持 null，下次重试）:', error);
        return [];
      }
    })().finally(() => {
      blockedWordsLoadPromise = null;
    });
  }
  return blockedWordsLoadPromise;
}

async function readBlockedUsersFromStorage(): Promise<BlockedUser[]> {
  return readBlockedItems(USER_LIST_CONFIG);
}

function loadBlockedUsers(): Promise<BlockedUser[]> {
  if (cachedBlockedUsers) return Promise.resolve(cachedBlockedUsers);
  if (!blockedUsersLoadPromise) {
    blockedUsersLoadPromise = (async () => {
      try {
        const users = await readBlockedUsersFromStorage();
        cachedBlockedUsers = users;
        return users;
      } catch (error) {
        // 同 loadBlockedWords：保持缓存为 null，下次调用重试，不吞成空列表。
        console.warn('[BlockManager] 读取屏蔽用户失败（缓存保持 null，下次重试）:', error);
        return [];
      }
    })().finally(() => {
      blockedUsersLoadPromise = null;
    });
  }
  return blockedUsersLoadPromise;
}

async function persistBlockedWord(word: BlockedWord): Promise<void> {
  await enqueueBlockStorageWrite(() =>
    kvSet(blockedWordStorageKey(word.id), JSON.stringify(word)),
  );
}

async function removePersistedBlockedWord(id: string): Promise<void> {
  await enqueueBlockStorageWrite(() => kvRemove(blockedWordStorageKey(id)));
}

async function persistBlockedUser(user: BlockedUser): Promise<void> {
  await enqueueBlockStorageWrite(() =>
    kvSet(blockedUserStorageKey(user.uid), JSON.stringify(user)),
  );
}

async function removePersistedBlockedUser(uid: string): Promise<void> {
  await enqueueBlockStorageWrite(() => kvRemove(blockedUserStorageKey(uid)));
}

export const BlockManager = {
  async getBlockedWords(): Promise<BlockedWord[]> {
    return [...(await loadBlockedWords())];
  },

  /** Internal cached snapshot used by blockFilterSync so compiled lists stay reusable. */
  async getBlockedWordsSnapshot(): Promise<BlockedWord[]> {
    return loadBlockedWords();
  },

  /** Internal cached snapshot used by blockFilterSync（引用稳定，供 dirty 循环比较）。 */
  async getBlockedUsersSnapshot(): Promise<BlockedUser[]> {
    return loadBlockedUsers();
  },

  async addBlockedWord(word: BlockedWord): Promise<void> {
    const next = [...(await loadBlockedWords()), word];
    cachedBlockedWords = next;
    await persistBlockedWord(word);
    clearRegexCaches();
    compiledBlockSnapshots.set(next, compileBlockedWords(next));
    emitBlockEvents();
  },

  async removeBlockedWord(id: string): Promise<void> {
    const words = await loadBlockedWords();
    const next = words.filter((w) => w.id !== id);
    if (next.length === words.length) return;
    cachedBlockedWords = next;
    await removePersistedBlockedWord(id);
    clearRegexCaches();
    compiledBlockSnapshots.set(next, compileBlockedWords(next));
    emitBlockEvents();
  },

  async getBlockedUsers(): Promise<BlockedUser[]> {
    return [...(await loadBlockedUsers())];
  },

  async addBlockedUser(user: BlockedUser): Promise<void> {
    const users = await loadBlockedUsers();
    if (users.some((u) => u.uid === user.uid)) return;
    const next = [...users, user];
    cachedBlockedUsers = next;
    await persistBlockedUser(user);
    emitBlockEvents();
  },

  async removeBlockedUser(uid: string): Promise<void> {
    const users = await loadBlockedUsers();
    const next = users.filter((u) => u.uid !== uid);
    if (next.length === users.length) return;
    cachedBlockedUsers = next;
    await removePersistedBlockedUser(uid);
    emitBlockEvents();
  },

  async clearAllBlocked(): Promise<void> {
    await Promise.all([loadBlockedWords(), loadBlockedUsers()]);
    cachedBlockedWords = null;
    cachedBlockedUsers = null;
    clearRegexCaches();
    await enqueueBlockStorageWrite(async () => {
      const allKeys = await getAllKeys();
      const keys = allKeys.filter(
        (key) =>
          key === BLOCKED_WORDS_KEY ||
          key === BLOCKED_USERS_KEY ||
          key.startsWith(BLOCKED_WORD_PREFIX) ||
          key.startsWith(BLOCKED_USER_PREFIX),
      );
      if (keys.length > 0) {
        await kvMultiRemove(keys);
      }
    });
    emitBlockEvents();
  },

  shouldBlockContent(content: string, blockedWords: BlockedWord[]): boolean {
    const snapshot = getCompiledBlockSnapshot(blockedWords);
    if (snapshot.whitelist.some((word) => matchCompiledBlockWord(content, word))) {
      return false;
    }
    return snapshot.blacklist.some((word) => matchCompiledBlockWord(content, word));
  },

  shouldBlockUser(userId: string, userName: string | null, blockedUsers: BlockedUser[]): boolean {
    return blockedUsers.some(
      (u) => u.uid === userId || (userName && u.username === userName),
    );
  },
};
