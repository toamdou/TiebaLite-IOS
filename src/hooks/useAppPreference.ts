/**
 * useAppPreference — reactive single-key preference hook backed by the
 * Zustand preferences store.
 */

import { usePreferencesStore } from '@/stores/preferencesStore';
import type { AppPreferences } from '@/types';

export function useAppPreference<K extends keyof AppPreferences>(
  key: K,
  defaultValue?: AppPreferences[K],
): AppPreferences[K] | undefined {
  return usePreferencesStore(
    (state) => state.preferences[key] ?? defaultValue,
  );
}
