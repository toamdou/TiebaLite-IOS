// ============================================================
// NotificationPoller — foreground polling + native BGAppRefreshTask sync
//
// Mirrors Kotlin NotifyJobService:
//   - Foreground timer only runs while the app is active.
//   - TiebaBackgroundSync registers BGAppRefreshTask natively; the system
//     decides the exact time and the task never starts Hermes.
//   - In-flight guard prevents overlapping msg() calls.
//   - Baseline is namespaced by uid so switching accounts cannot
//     produce duplicate notifications.
// ============================================================

import { AppState } from 'react-native';
import * as Notifications from 'expo-notifications';
import { TiebaNative } from '../../modules/tieba-native/src/TiebaNative';
import {
  addLowPowerModeListener,
  getLowPowerMode,
} from '../../modules/tieba-system/src';
import type { NotificationCount } from '@/types';
import { useNotificationStore } from '@/stores/notificationStore';
import { usePreferencesStore } from '@/stores/preferencesStore';
import { hydrateSecureCredentials } from '@/services/storage/AuthSecureStorage';
import { restoreAccountSync } from '@/services/storage/AuthSQLiteStorage';
import { kvGet, kvRemove, kvSet } from '@/services/storage/unifiedDb';

// ----------------------------------------------------------------
// Storage keys (mirrors Kotlin: NotifyJobService; uid-namespaced)
// ----------------------------------------------------------------
const LAST_COUNT_PREFIX = 'tiebalite_last_notif_counts_';
// Kotlin schedules NotifyJobService every 30 minutes; foreground polling uses
// the preference-selected cadence (pollIntervalMs，默认 30 分钟) so message
// checks do not cost more battery than the reference app by default.
// Low Power Mode: double the poll cadence to save battery. Sign-in reminders
// are unaffected — they are scheduled natively by TiebaBackgroundSync.
const FOREGROUND_MIN_INTERVAL_MS = 60 * 1000; // avoid burst polling on rapid foreground transitions
// Kotlin NotifyJobService runs every 30 minutes; the background task uses the
// same cadence so iOS/Android both stay at the reference app's battery cost.
const BACKGROUND_MIN_INTERVAL_MS = 30; // minutes, system minimum is 15
const SAVE_RETRY_DELAYS_MS = [250, 600];

const NOTIF_ID_REPLY = 'msg_reply';
const NOTIF_ID_AT = 'msg_at';
const NOTIF_ID_AGREE = 'msg_agree';

function sanitizeError(error: unknown): string {
  if (error instanceof Error) return `${error.name}: ${error.message}`;
  return String(error);
}

function lastCountKey(uid: string): string {
  return `${LAST_COUNT_PREFIX}${uid || 'anonymous'}`;
}

function currentUid(): string {
  // 惰性 require：authStore 静态引入本模块（轮询启停），这里再静态引回会
  // 成 require 环，dev 冷启动每次触发 Metro 环警告横幅（LogBox 拦不住，
  // 它在包求值期比 ignore 注册更早触发）。函数内取用不参与静态依赖图。
  const { useAuthStore } = require('@/stores/authStore');
  return (
    useAuthStore.getState().account?.uid ||
    restoreAccountSync()?.uid ||
    ''
  );
}

function isNotificationCount(value: unknown): value is NotificationCount {
  if (!value || typeof value !== 'object') return false;
  const v = value as Record<string, unknown>;
  return (
    typeof v.reply === 'number' &&
    Number.isFinite(v.reply) &&
    v.reply >= 0 &&
    typeof v.at === 'number' &&
    Number.isFinite(v.at) &&
    v.at >= 0 &&
    typeof v.agree === 'number' &&
    Number.isFinite(v.agree) &&
    v.agree >= 0 &&
    typeof v.total === 'number' &&
    Number.isFinite(v.total) &&
    v.total >= 0
  );
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

// ----------------------------------------------------------------
// Poller state
// ----------------------------------------------------------------

let pollTimer: ReturnType<typeof setInterval> | null = null;
let isRunning = false;
let inFlight = false;
let lastPollAt = 0;
// Low Power Mode state — mirrored from the native event so the active timer
// can be recreated at the reduced cadence without touching AppState gating.
let lowPowerMode = false;
let lowPowerSub: { remove(): void } | null = null;
// Preferences subscription for the foreground poll cadence（start 时挂载）。
let pollPrefUnsub: (() => void) | null = null;
// AppState listener used by start/stop; kept module-scoped so stop can remove
// it without reaching into the function object (mirrors lowPowerSub handling).
let appStateSub: { remove(): void } | null = null;

/** Active poll cadence: doubles while iOS Low Power Mode is on.
 *  Base cadence comes from the notificationPollMinutes preference
 *  (30/60/120，settings/more 通知分区；坏值回落 30 对齐 Kotlin 节奏). */
function pollIntervalMs(): number {
  const raw = usePreferencesStore.getState().preferences.notificationPollMinutes;
  const baseMinutes = raw === 60 || raw === 120 ? raw : 30;
  return lowPowerMode ? baseMinutes * 2 * 60 * 1000 : baseMinutes * 60 * 1000;
}

// ----------------------------------------------------------------
// Internal helpers
// ----------------------------------------------------------------

function allowsNotifications(permissions: Notifications.NotificationPermissionsStatus): boolean {
  if (permissions.granted) return true;
  const iosStatus = permissions.ios?.status;
  return (
    iosStatus === Notifications.IosAuthorizationStatus.PROVISIONAL ||
    iosStatus === Notifications.IosAuthorizationStatus.EPHEMERAL
  );
}

export async function ensureNotificationPermissionAsync(requestIfNeeded = true): Promise<boolean> {
  try {
    const current = await Notifications.getPermissionsAsync();
    if (allowsNotifications(current)) return true;
    if (
      requestIfNeeded &&
      current.ios?.status === Notifications.IosAuthorizationStatus.NOT_DETERMINED
    ) {
      const result = await Notifications.requestPermissionsAsync({
        ios: { allowAlert: true, allowBadge: true, allowSound: true },
      });
      return allowsNotifications(result);
    }
    return false;
  } catch {
    return false;
  }
}

async function getLastCounts(uid: string): Promise<NotificationCount | null> {
  const nativeCounts = TiebaNative.getNotificationCounts(uid);
  if (nativeCounts && isNotificationCount(nativeCounts)) {
    return nativeCounts;
  }
  let raw: string | null;
  try {
    raw = await kvGet(lastCountKey(uid));
  } catch (error) {
    throw new Error(`read last counts failed: ${sanitizeError(error)}`);
  }
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!isNotificationCount(parsed)) {
      console.warn(`[NotificationPoller] Invalid last counts payload for uid ${uid}; ignoring baseline`);
      return null;
    }
    return parsed;
  } catch {
    console.warn(`[NotificationPoller] Corrupt last counts payload for uid ${uid}; ignoring baseline`);
    return null;
  }
}

async function saveLastCounts(
  counts: NotificationCount,
  uid: string,
  attempt = 0,
): Promise<void> {
  try {
    await kvSet(lastCountKey(uid), JSON.stringify(counts));
    TiebaNative.setNotificationCounts(uid, counts.reply, counts.at, counts.agree, counts.total);
  } catch (error) {
    const retryDelay = SAVE_RETRY_DELAYS_MS[attempt];
    if (retryDelay !== undefined) {
      await delay(retryDelay);
      return saveLastCounts(counts, uid, attempt + 1);
    }
    console.warn(`[NotificationPoller] Failed to save last counts for uid ${uid}:`, sanitizeError(error));
    throw error;
  }
}

async function showMessageNotification(
  identifier: string,
  title: string,
  body: string,
  deepLink: string,
  badgeCount: number,
): Promise<void> {
  if (!(await ensureNotificationPermissionAsync(false))) return;

  await Notifications.scheduleNotificationAsync({
    identifier,
    content: {
      title,
      body,
      sound: 'default',
      badge: badgeCount,
      data: { type: 'message', url: deepLink },
    },
    trigger: null, // iOS: schedule immediately; no channel concept
  });
}

// ----------------------------------------------------------------
// Poll logic
// ----------------------------------------------------------------

/**
 * Show a message notification for a category whose count increased since the
 * last baseline. `delta` is the per-category increase; it is only called when
 * delta > 0.
 */
async function notifyDelta(
  identifier: string,
  title: (count: number) => string,
  body: (delta: number) => string,
  deepLink: string,
  delta: number,
  total: number,
): Promise<void> {
  if (delta <= 0) return;
  await showMessageNotification(identifier, title(total), body(delta), deepLink, total);
}

async function syncMessages(): Promise<void> {
  if (inFlight) return;
  if (AppState.currentState !== 'active') return;
  if (Date.now() - lastPollAt < FOREGROUND_MIN_INTERVAL_MS) return;

  // 轮询代次捕获：stop()/重启后迟到的异步回调不得再产生任何副作用
  // （setState/badge/notify/saveLastCounts 全部以 runId 校验为前置）。
  const runId = pollerRunId;

  // Background tasks can run before the app root has checked auth; hydrate
  // credentials and restore the active account before deciding login state.
  await hydrateSecureCredentials();
  // 惰性 require，见 currentUid() 注释（避免与 authStore 的静态环）
  const { useAuthStore } = require('@/stores/authStore');
  const restored = restoreAccountSync();
  if (restored && !useAuthStore.getState().isLoggedIn) {
    useAuthStore.setState({ account: restored, isLoggedIn: true });
  }
  if (!useAuthStore.getState().isLoggedIn) return;

  inFlight = true;
  lastPollAt = Date.now();
  try {
    // uid 在首个数据 await 之前捕获：副作用前以同一身份校验，防止
    // 登出/切号窗口里用新账号 uid 把旧账号基线覆盖掉。
    const uid = currentUid();
    // 调用点惰性加载：authStore/signViewModel 静态引用本模块，barrel
    // （axios+protobufjs 端点图）不得借道进首帧模块图。
    // eslint-disable-next-line @typescript-eslint/no-require-imports -- 启动热路径裁剪
    const { msg } = require('@/services/api') as typeof import('@/services/api');
    const current = await msg();
    const last = await getLastCounts(uid);

    // 副作用前统一竞态校验：轮询已 stop/重启，或账号已切换 → 丢弃本轮。
    const stale = () => runId !== pollerRunId || uid !== currentUid();
    if (stale()) return;

    // Keep the UI and iOS badge in sync with the latest server counts.
    useNotificationStore.setState({ counts: current });
    await Notifications.setBadgeCountAsync(current.total).catch(() => {});

    if (!last) {
      if (stale()) return;
      await saveLastCounts(current, uid);
      return;
    }

    const changed =
      current.reply !== last.reply ||
      current.at !== last.at ||
      current.agree !== last.agree ||
      current.total !== last.total;
    if (!changed) return;

    // Counts went down (user read messages elsewhere); treat as a new baseline
    // so the next increase still notifies without replaying old deltas.
    if (current.total < last.total) {
      if (stale()) return;
      await saveLastCounts(current, uid);
      return;
    }

    if (stale()) return;
    await notifyDelta(
      NOTIF_ID_REPLY,
      (count) => `回复我的 (${count})`,
      (delta) => (delta === 1 ? '你有 1 条新回复' : `你有 ${delta} 条新回复`),
      'tiebalite://notifications/0',
      current.reply - (last.reply || 0),
      current.total,
    );

    if (stale()) return;
    await notifyDelta(
      NOTIF_ID_AT,
      (count) => `提到我的 (${count})`,
      (delta) => (delta === 1 ? '有 1 人@了你' : `有 ${delta} 人@了你`),
      'tiebalite://notifications/1',
      current.at - (last.at || 0),
      current.total,
    );

    if (stale()) return;
    await notifyDelta(
      NOTIF_ID_AGREE,
      (count) => `赞我的 (${count})`,
      (delta) => (delta === 1 ? '有 1 人赞了你' : `有 ${delta} 人赞了你`),
      'tiebalite://notifications/2',
      current.agree - (last.agree || 0),
      current.total,
    );

    // Persist only after notifications have been delivered so a failed
    // notification is retried on the next poll instead of being skipped.
    if (stale()) return;
    await saveLastCounts(current, uid);
  } finally {
    inFlight = false;
  }
}

async function pollMessages(): Promise<void> {
  try {
    await syncMessages();
  } catch (error) {
    // Foreground polling is best-effort; the background task still reports
    // failures to iOS so the system can schedule a retry.
    console.warn('[NotificationPoller] Foreground poll failed:', sanitizeError(error));
  }
}

/** Reset the per-uid baseline after the user opens the messages page. */
export async function resetNotificationBaseline(): Promise<void> {
  const uid = currentUid();
  if (!uid) return;
  const counts = useNotificationStore.getState().counts;
  await saveLastCounts(counts, uid);
  await Notifications.setBadgeCountAsync(counts.total).catch(() => {});
}

/** Remove the baseline for a uid (e.g. after logout). */
export async function clearNotificationBaseline(uid?: string): Promise<void> {
  const targetUid = uid || currentUid();
  if (!targetUid) return;
  try {
    await kvRemove(lastCountKey(targetUid));
  } catch (error) {
    console.warn('[NotificationPoller] Failed to clear baseline:', sanitizeError(error));
  }
  try {
    TiebaNative.clearNotificationCounts(targetUid);
  } catch (error) {
    console.warn('[NotificationPoller] Failed to clear baseline:', sanitizeError(error));
  }
}

// ----------------------------------------------------------------
// Public API
// ----------------------------------------------------------------

export async function setupNotifications(): Promise<void> {
  const allowed = await ensureNotificationPermissionAsync(true);
  if (allowed) {
    startNotificationPoller();
    TiebaNative.registerNotificationSync(BACKGROUND_MIN_INTERVAL_MS);
  } else {
    cancelNativeBackgroundSync();
  }
}

/**
 * 幂等注册原生 BGAppRefreshTask 通知同步 + 自动签到。
 * 登出/过期/清数据会 cancelNativeBackgroundSync，登录/换号时必须重新注册，
 * 否则同会话内后台同步永久失效（直到冷启动）。
 */
export function ensureBackgroundSync(): void {
  TiebaNative.registerNotificationSync(BACKGROUND_MIN_INTERVAL_MS);
}

/** Cancel only the native BGAppRefreshTask; foreground poller is unchanged. */
export function cancelNativeBackgroundSync(): void {
  TiebaNative.cancelNotificationSync();
}

// 轮询实例代次：stop 后迟到的异步回调（如 getLowPowerMode）不得再污染标记
let pollerRunId = 0;

export function startNotificationPoller(): void {
  // 先守卫再提升代次：重复调用 start 不应让已在运行的实例代次 ++，
  // 否则会作废其挂起的异步回调（getLowPowerMode.then 等）的 runId 校验。
  if (isRunning) return;
  const runId = ++pollerRunId;
  isRunning = true;

  const ensureTimer = () => {
    if (pollTimer) return;
    pollTimer = setInterval(() => {
      pollMessages();
    }, pollIntervalMs());
  };

  const stopTimer = () => {
    if (pollTimer) {
      clearInterval(pollTimer);
      pollTimer = null;
    }
  };

  // Rebuild the active timer at the new cadence when the poll-interval
  // preference changes. Only touches the foreground timer — the native
  // BGAppRefreshTask cadence is owned by iOS, and sign-in scheduling lives
  // in TiebaBackgroundSync.
  const onLowPowerChange = (enabled: boolean) => {
    if (lowPowerMode === enabled) return;
    lowPowerMode = enabled;
    if (pollTimer) {
      stopTimer();
      ensureTimer();
    }
  };

  lowPowerSub = addLowPowerModeListener(onLowPowerChange);
  void getLowPowerMode().then((enabled) => {
    if (runId !== pollerRunId) return;
    onLowPowerChange(enabled);
  });

  // 偏好变更（设置→更多设置→消息检查频率）即时重建前台定时器
  let lastPollMinutes = usePreferencesStore.getState().preferences.notificationPollMinutes;
  pollPrefUnsub = usePreferencesStore.subscribe((state) => {
    const next = state.preferences.notificationPollMinutes;
    if (next === lastPollMinutes) return;
    lastPollMinutes = next;
    if (pollTimer) {
      stopTimer();
      ensureTimer();
    }
  });

  ensureTimer();
  if (AppState.currentState === 'active') pollMessages();

  const appStateListener = AppState.addEventListener('change', (state) => {
    if (state === 'active') {
      ensureTimer();
      pollMessages();
    } else {
      stopTimer();
    }
  });
  appStateSub = appStateListener;
}

export function stopNotificationPoller(): void {
  pollerRunId += 1;
  isRunning = false;
  lastPollAt = 0;
  if (pollTimer) {
    clearInterval(pollTimer);
    pollTimer = null;
  }
  if (lowPowerSub) {
    lowPowerSub.remove();
    lowPowerSub = null;
  }
  if (pollPrefUnsub) {
    pollPrefUnsub();
    pollPrefUnsub = null;
  }
  lowPowerMode = false;
  if (appStateSub) {
    appStateSub.remove();
    appStateSub = null;
  }
}
