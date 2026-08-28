/**
 * Non-sensitive account profile cache for cold start.
 *
 * Credentials are intentionally stripped before storage; this cache only
 * lets the first screen render the last known user immediately while
 * SecureStore/SQLite credentials hydrate in the background.
 */

import type { Account } from '@/types';
import { kvGet, kvRemove, kvSet } from '@/services/storage/unifiedDb';
import { keys, parseJson, redact } from '@/services/storage/AuthSecureStorage';

const CACHE_KEY = keys.ACCOUNT_PROFILE_CACHE;

export async function getCachedAccountProfile(): Promise<Account | null> {
  try {
    const raw = await kvGet(CACHE_KEY);
    if (!raw) return null;
    const parsed = parseJson<Partial<Account>>(raw);
    return parsed?.uid ? (parsed as Account) : null;
  } catch {
    return null;
  }
}

export async function saveAccountProfile(account: Account): Promise<void> {
  if (!account?.uid) return;
  try {
    await kvSet(CACHE_KEY, JSON.stringify(redact(account)));
  } catch {
    // Cache is best-effort; auth persistence is authoritative.
  }
}

export async function clearAccountProfile(): Promise<void> {
  try {
    await kvRemove(CACHE_KEY);
  } catch {
    // Best-effort cleanup.
  }
}