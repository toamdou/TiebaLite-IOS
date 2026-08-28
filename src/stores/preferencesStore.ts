/**
 * Zustand-powered preferences store.
 *
 * This is the single persistence layer for AppPreferences.
 */

import { create } from 'zustand';
import { persist, type PersistStorage } from 'zustand/middleware';

import type { AppPreferences } from '@/types';
import { DEFAULT_PREFERENCES } from '@/constants/preferences';
import { THEME_OPTIONS } from '@/constants/app';
import {
  kvGet,
  kvMultiGet,
  kvMultiRemove,
  kvMultiSet,
  kvRemove,
} from '@/services/storage/unifiedDb';

// ── 内部常量（无外部消费者，收窄为模块私有）──
const PREFERENCES_STORAGE_KEY = 'tiebalite_preferences';

type AppPreferenceKey = keyof AppPreferences;

/** 字面量联合类型的偏好键白名单：命中才放行，否则回滚默认（历史坏值防护）。 */
const STRING_UNION_OPTIONS: Partial<Record<AppPreferenceKey, readonly string[]>> = {
  lightTheme: THEME_OPTIONS.map((t) => t.key),
  darkTheme: THEME_OPTIONS.map((t) => t.key),
  imageLoadType: ['smart_origin', 'all_origin', 'all_no'],
  imageWatermark: ['none', 'username', 'forum_name'],
  signDisplayMode: ['liveActivity', 'notification'],
  forumSortMode: ['level', 'name'],
  dataSaverMode: ['origin', 'high', 'lite'],
  timestampStyle: ['relative', 'absolute'],
  startTab: ['index', 'explore', 'notifications', 'profile'],
};

/**
 * 按 AppPreferences[key] 的静态类型做运行时校验（存储内容不可信：
 * 旧版本可能写入过 string 版数字、越界枚举等坏值）。
 * 非法值丢弃并回滚到默认值。
 */
function sanitizePreferenceValue(
  key: AppPreferenceKey,
  value: unknown,
): AppPreferences[AppPreferenceKey] {
  const fallback = DEFAULT_PREFERENCES[key];
  switch (typeof fallback) {
    case 'boolean':
      return typeof value === 'boolean' ? value : fallback;
    case 'number':
      return typeof value === 'number' && Number.isFinite(value) ? value : fallback;
    default: {
      // string 键：自由字符串直接收（autoSignTime/customPrimaryColor/
      // defaultSortType/forumFabFunction），字面量联合需命中白名单。
      if (typeof value === 'string') {
        const allowed = STRING_UNION_OPTIONS[key];
        if (!allowed || allowed.includes(value)) {
          return value as AppPreferences[AppPreferenceKey];
        }
      }
      return fallback;
    }
  }
}

const PREFERENCE_KEYS = Object.keys(DEFAULT_PREFERENCES) as AppPreferenceKey[];
const PREFERENCE_KEY_PREFIX = `${PREFERENCES_STORAGE_KEY}:`;

type PersistedPreferencesState = { preferences: AppPreferences };

let lastPersistedPreferences: AppPreferences | null = null;
let storageWriteQueue: Promise<void> = Promise.resolve();

function preferenceStorageKey(key: AppPreferenceKey): string {
  return `${PREFERENCE_KEY_PREFIX}${key}`;
}

function preferenceStorageKeys(): string[] {
  return PREFERENCE_KEYS.map(preferenceStorageKey);
}

function parseStoredPreferenceValue(raw: string): unknown {
  try {
    return JSON.parse(raw) as unknown;
  } catch {
    return raw;
  }
}

function enqueueStorageWrite(operation: () => Promise<void>): Promise<void> {
  const run = storageWriteQueue.then(operation, operation);
  // 队列承接失败以避免连锁失败，但至少记一条可观测日志；
  // 返回原始 promise，让 resetPreferences 等调用方的失败路径向上抛错。
  storageWriteQueue = run.catch((error) => {
    console.warn('[preferencesStore] 偏好持久化写入失败:', error);
  });
  return run;
}

async function removePreferencesStorage(): Promise<void> {
  await enqueueStorageWrite(async () => {
    await kvMultiRemove([PREFERENCES_STORAGE_KEY, ...preferenceStorageKeys()]);
    lastPersistedPreferences = null;
  });
}

const preferencesPersistStorage: PersistStorage<PersistedPreferencesState, Promise<void>> = {
  async getItem() {
    const [legacyValue, entries] = await Promise.all([
      kvGet(PREFERENCES_STORAGE_KEY),
      kvMultiGet(preferenceStorageKeys()),
    ]);

    const merged: Partial<AppPreferences> = {};
    let hasPerKeyValues = false;
    for (const [key, value] of entries) {
      if (value == null) continue;
      hasPerKeyValues = true;
      const preferenceKey = key.slice(PREFERENCE_KEY_PREFIX.length) as AppPreferenceKey;
      if (PREFERENCE_KEYS.includes(preferenceKey)) {
        // 存储值不可信：按类型校验，非法值回滚默认
        (merged as Record<string, unknown>)[preferenceKey] = sanitizePreferenceValue(
          preferenceKey,
          parseStoredPreferenceValue(value),
        );
      }
    }

    if (legacyValue) {
      try {
        const parsed = JSON.parse(legacyValue) as
          | { preferences?: Partial<AppPreferences> }
          | Partial<AppPreferences>
          | null;
        const stored =
          parsed && typeof parsed === 'object' && 'preferences' in parsed
            ? parsed.preferences
            : parsed ?? {};
        for (const key of PREFERENCE_KEYS) {
          const value = (stored as Record<string, unknown>)[key];
          if (value !== undefined && (merged as Record<string, unknown>)[key] === undefined) {
            // 旧版整体 JSON 同样是不可信输入：按类型校验，非法值回滚默认
            (merged as Record<string, unknown>)[key] = sanitizePreferenceValue(key, value);
          }
        }
      } catch {}

      const legacyKeysToWrite = PREFERENCE_KEYS.filter(
        (key) => (merged as Record<string, unknown>)[key] !== undefined,
      );
      await enqueueStorageWrite(async () => {
        if (legacyKeysToWrite.length > 0) {
          await kvMultiSet(
            legacyKeysToWrite.map(
              (key) => [preferenceStorageKey(key), JSON.stringify(merged[key])] as [string, string],
            ),
          );
        }
        await kvRemove(PREFERENCES_STORAGE_KEY);
      });
      lastPersistedPreferences = { ...DEFAULT_PREFERENCES, ...merged };
      return { state: { preferences: lastPersistedPreferences } };
    }

    if (hasPerKeyValues) {
      lastPersistedPreferences = { ...DEFAULT_PREFERENCES, ...merged };
      return { state: { preferences: lastPersistedPreferences } };
    }

    lastPersistedPreferences = null;
    return null;
  },

  async setItem(_name, value) {
    const incoming = value.state?.preferences;
    if (!incoming) return;
    const next: AppPreferences = { ...DEFAULT_PREFERENCES, ...incoming };
    await enqueueStorageWrite(async () => {
      const previous = lastPersistedPreferences ?? { ...DEFAULT_PREFERENCES };
      const changed: [string, string][] = [];
      for (const key of PREFERENCE_KEYS) {
        if (next[key] !== previous[key]) {
          changed.push([preferenceStorageKey(key), JSON.stringify(next[key])]);
        }
      }
      if (changed.length > 0) {
        await kvMultiSet(changed);
      }
      lastPersistedPreferences = next;
    });
  },

  async removeItem() {
    await removePreferencesStorage();
  },
};

interface PreferencesState {
  preferences: AppPreferences;
  hasHydrated: boolean;
  setPreference: <K extends AppPreferenceKey>(key: K, value: AppPreferences[K]) => void;
  setPreferences: (prefs: Partial<AppPreferences>) => void;
  setHasHydrated: () => void;
  resetPreferences: () => Promise<void>;
}

export const usePreferencesStore = create<PreferencesState>()(
  persist(
    (set) => ({
      preferences: { ...DEFAULT_PREFERENCES },
      hasHydrated: false,
      setPreference: (key, value) =>
        set((state) => ({
          preferences: { ...state.preferences, [key]: value },
        })),
      setPreferences: (prefs) =>
        set((state) => ({
          preferences: { ...state.preferences, ...prefs },
        })),
      setHasHydrated: () => set({ hasHydrated: true }),
      resetPreferences: async () => {
        await removePreferencesStorage();
        set({ preferences: { ...DEFAULT_PREFERENCES } });
      },
    }),
    {
      name: PREFERENCES_STORAGE_KEY,
      storage: preferencesPersistStorage,
      partialize: (state) => ({ preferences: state.preferences }),
      onRehydrateStorage: () => (state) => {
        state?.setHasHydrated();
      },
    },
  ),
);
