/**
 * Compatibility adapter over the Zustand preferences store.
 *
 * New code should read/write `usePreferencesStore` directly; these async
 * helpers remain for non-UI services that need a one-shot snapshot.
 */

import type { AppPreferences } from '@/types';
import { usePreferencesStore } from '@/stores/preferencesStore';

export { DEFAULT_PREFERENCES } from '@/constants/preferences';

export async function getPreferences(): Promise<AppPreferences> {
  const store = usePreferencesStore;
  if (!store.persist.hasHydrated()) {
    await store.persist.rehydrate();
  }
  return store.getState().preferences;
}

export async function savePreferences(
  prefs: Partial<AppPreferences>,
): Promise<void> {
  usePreferencesStore.getState().setPreferences(prefs);
}

export async function resetPreferences(): Promise<void> {
  await usePreferencesStore.getState().resetPreferences();
}

export async function refreshPreferences(): Promise<AppPreferences> {
  await usePreferencesStore.persist.rehydrate();
  return usePreferencesStore.getState().preferences;
}

// ----------------------------------------------------------------
// Individual getter/setter helpers for commonly accessed preferences
// ----------------------------------------------------------------

/**
 * Get the current font scale preference.
 */
export async function getFontScale(): Promise<number> {
  const prefs = await getPreferences();
  return prefs.fontScale;
}

/**
 * Set the font scale preference.
 *
 * @param scale - The font scale multiplier
 */
export async function setFontScale(scale: number): Promise<void> {
  await savePreferences({ fontScale: scale });
}
