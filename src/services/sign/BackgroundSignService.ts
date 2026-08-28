/**
 * BackgroundSignService - native BGProcessingTask registration plus daily
 * auto-sign scheduling for the sign domain.
 */

import * as Notifications from 'expo-notifications';
import { ensureNotificationPermissionAsync } from '@/services/NotificationPoller';
import { getPreferences, savePreferences } from '@/services/storage/PreferencesStorage';
import { TiebaNative } from '../../../modules/tieba-native/src/TiebaNative';

export async function sendSignCompleteNotification(
  successCount: number,
  failCount: number,
  totalExp: number,
  fromBackground = false,
): Promise<void> {
  const allowed = await ensureNotificationPermissionAsync(!fromBackground);
  if (!allowed) return;

  const body =
    failCount > 0
      ? `成功签到 ${successCount} 个吧，失败 ${failCount} 个，获得 ${totalExp} 经验`
      : `成功签到 ${successCount} 个吧，获得 ${totalExp} 经验`;

  // 静默模式：完成通知不发声（iOS 横幅照常显示，仅静音）。
  const silent = (await getPreferences()).signSilent ?? false;

  await Notifications.scheduleNotificationAsync({
    content: {
      title: '一键签到完成',
      body,
      sound: silent ? undefined : 'default',
      badge: 0,
      interruptionLevel: silent ? 'passive' : 'active',
      data: { type: 'sign_complete' },
    },
    trigger: null,
  });
}

export async function scheduleAutoSign(time: string): Promise<void> {
  const [hours, minutes] = time.split(':').map(Number);
  if (!Number.isInteger(hours) || !Number.isInteger(minutes)) {
    throw new Error('无效的签到时间');
  }

  TiebaNative.cancelAutoSign();
  TiebaNative.registerAutoSign(hours, minutes);
  TiebaNative.scheduleSignReminder(hours, minutes);
  await savePreferences({ autoSign: true, autoSignTime: time });
}

export async function cancelAutoSign(): Promise<void> {
  TiebaNative.cancelAutoSign();
  TiebaNative.cancelSignReminder();
  await savePreferences({ autoSign: false });
}

export async function checkAutoSignScheduled(): Promise<boolean> {
  return TiebaNative.isAutoSignRegistered();
}

/** Re-register the native auto-sign request after a cold start. */
export async function ensureAutoSignScheduled(): Promise<void> {
  const prefs = await getPreferences();
  if (!prefs.autoSign || !prefs.autoSignTime) return;
  const [hours, minutes] = prefs.autoSignTime.split(':').map(Number);
  if (!Number.isInteger(hours) || !Number.isInteger(minutes)) return;
  TiebaNative.registerAutoSign(hours, minutes);
  TiebaNative.scheduleSignReminder(hours, minutes);
}
