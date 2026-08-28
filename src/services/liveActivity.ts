// ============================================================
// TiebaLite Live Activity bridge (iOS only)
//
// Wraps the native TiebaLiveActivity ActivityKit module with a narrow,
// sign-specific API and throttles updates so the widget never over-uses
// the ActivityKit budget. All methods are safe no-ops off-iOS.
//
// state 构建统一收敛在 services/sign/signSnapshot.ts（buildSignSnapshot），
// 与设置页 LiveActivityPreview 共享同一文案/进度样板，杜绝双实现漂移。
// ============================================================

import { Platform } from 'react-native';
import { kvRemove, kvSet } from '@/services/storage/unifiedDb';
import { usePreferencesStore } from '@/stores/preferencesStore';
import { TiebaNative } from '../../modules/tieba-native/src/TiebaNative';
import {
  buildSignSnapshot,
  SIGN_LIVE_ACTIVITY_NAME,
  SIGN_LIVE_ACTIVITY_STORAGE_KEY,
  type SignLiveActivitySnapshot,
} from './sign/signSnapshot';

export type {
  SignLiveActivityPhase,
  SignLiveActivitySnapshot,
  SignLiveActivityState,
} from './sign/signSnapshot';

const UPDATE_THROTTLE_MS = 4000;

let lastUpdateAt = 0;

export function isLiveActivityAvailable(): boolean {
  if (Platform.OS !== 'ios') return false;
  try {
    if (!TiebaNative.isLiveActivitySupported()) return false;
    return TiebaNative.areLiveActivitiesEnabled();
  } catch {
    return false;
  }
}

async function clearStoredActivityId(): Promise<void> {
  try {
    await kvRemove(SIGN_LIVE_ACTIVITY_STORAGE_KEY);
  } catch {}
}

export async function startSignLiveActivity(
  snapshot: Omit<SignLiveActivitySnapshot, 'phase'>,
): Promise<string | null> {
  if (!isLiveActivityAvailable()) return null;
  const prefs = usePreferencesStore.getState().preferences;
  // 显示位置设置：选通知栏时不再创建 Live Activity（二选一）。
  if (!prefs.liveActivitySignEnabled || prefs.signDisplayMode === 'notification') return null;
  try {
    const activityId = await TiebaNative.startLiveActivity({
      name: SIGN_LIVE_ACTIVITY_NAME,
      ...buildSignSnapshot({ ...snapshot, phase: 'signing' }),
    });
    if (!activityId) return null;
    try {
      await kvSet(SIGN_LIVE_ACTIVITY_STORAGE_KEY, activityId);
    } catch {}
    // start 成功即把节流时间戳归零：runSignBatch 的首个 update 通常在
    // start 后 <4s 内到达，若沿用 start 时刻则会被 UPDATE_THROTTLE_MS 吞掉，
    // 灵动岛进度会一直停在 0/k 直到下一个 batch 节拍。
    lastUpdateAt = 0;
    return activityId;
  } catch {
    return null;
  }
}

export async function updateSignLiveActivity(
  activityId: string | null,
  snapshot: Omit<SignLiveActivitySnapshot, 'phase'>,
  force = false,
): Promise<void> {
  if (!activityId || !isLiveActivityAvailable()) return;
  const now = Date.now();
  if (!force && now - lastUpdateAt < UPDATE_THROTTLE_MS) return;
  try {
    await TiebaNative.updateLiveActivity(
      activityId,
      buildSignSnapshot({ ...snapshot, phase: 'signing' }),
    );
    lastUpdateAt = now;
  } catch {}
}

export async function finishSignLiveActivity(
  activityId: string | null,
  snapshot: Pick<SignLiveActivitySnapshot, 'success' | 'fail' | 'exp' | 'phase'>,
): Promise<void> {
  if (!activityId) {
    await clearStoredActivityId();
    return;
  }
  try {
    await TiebaNative.endLiveActivity(
      activityId,
      buildSignSnapshot({
        done: snapshot.success + snapshot.fail,
        total: Math.max(snapshot.success + snapshot.fail, 1),
        success: snapshot.success,
        fail: snapshot.fail,
        exp: snapshot.exp,
        phase: snapshot.phase,
      }),
      'default',
    );
  } catch {}
  await clearStoredActivityId();
}

/** End any orphaned sign activity after a killed process or failed launch. */
export async function recoverStaleSignLiveActivities(): Promise<void> {
  if (isLiveActivityAvailable()) {
    try {
      await TiebaNative.endAllLiveActivities(
        buildSignSnapshot({
          done: 0,
          total: 1,
          success: 0,
          fail: 0,
          exp: 0,
          phase: 'cancelled',
        }),
        'immediate',
      );
    } catch {}
  }
  await clearStoredActivityId();
}