/**
 * 应用锁（面容 ID）状态存储。
 *
 * 开关标志持久化在 Keychain（expo-secure-store），不进 MMKV 偏好表：
 * - 安全开关不该被「恢复默认设置」等偏好重置链路顺手清掉；
 * - 面容数据本身永远不出 Secure Enclave（系统只回验证成败），应用侧
 *   能存的只有「是否开启」这一个布尔标志，放 Keychain 最合适。
 */

import { create } from 'zustand';
import * as SecureStore from 'expo-secure-store';
import * as LocalAuthentication from 'expo-local-authentication';

const APP_LOCK_ENABLED_KEY = 'tiebalite.appLock.enabled';

/**
 * 同步原生隐私遮罩开关（F1）：应用锁开启时失活即盖原生模糊窗，
 * 保证多任务快照不露出内容。原生模块缺失（Expo Go）时静默降级。
 */
function syncPrivacyShield(enabled: boolean): void {
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports -- 原生模块缺失时静默降级，不拖垮应用锁
    require('../../modules/tieba-native/src/TiebaNative').TiebaNative.setPrivacyShieldEnabled(enabled);
  } catch {}
}

export type BiometricAuthOutcome = { ok: true } | { ok: false; message: string };

/** authenticateAsync 失败码 → 用户可读文案。 */
function authFailureMessage(code: string): string {
  switch (code) {
    case 'user_cancel':
    case 'user_fallback':
    case 'system_cancel':
    case 'app_cancel':
      return '已取消验证';
    case 'authentication_failed':
    case 'unable_to_process':
      return '面容识别失败，请重试';
    case 'not_enrolled':
    case 'not_available':
      return '未录入面容 ID，请先在系统设置中录入';
    case 'lockout':
      return '面容 ID 已锁定，请先用锁屏密码解锁设备';
    case 'passcode_not_set':
      return '设备未设置锁屏密码，无法使用面容 ID';
    default:
      return '验证未通过，请重试';
  }
}

interface AppLockState {
  /** Keychain 标志是否已解析（启动闸等待它，保证 splash 收起即锁面、不闪内容） */
  hydrated: boolean;
  enabled: boolean;
  /** 锁定态：覆盖层可见并拦截全部触摸 */
  locked: boolean;
  hydrate: () => Promise<void>;
  setEnabled: (v: boolean) => Promise<void>;
  lock: () => void;
}

export const useAppLockStore = create<AppLockState>()((set, get) => ({
  hydrated: false,
  enabled: false,
  locked: false,

  hydrate: async () => {
    if (get().hydrated) return;
    let stored: string | null = null;
    try {
      stored = await SecureStore.getItemAsync(APP_LOCK_ENABLED_KEY);
    } catch (e) {
      // Keychain 读失败按未开启放行：安全特性宁可漏锁，不能把人锁在门外
      console.warn('[appLock] 读取应用锁开关失败，按未开启处理:', e);
    }
    const enabled = stored === '1';
    set({ enabled, hydrated: true });
    syncPrivacyShield(enabled);
    // 冷启动默认未解锁：遮罩在首轮面容验证成功前不解除
    if (enabled) syncShieldUnlocked(false);
  },

  setEnabled: async (v) => {
    set({ enabled: v });
    syncPrivacyShield(v);
    if (v) syncShieldUnlocked(false);
    try {
      await SecureStore.setItemAsync(APP_LOCK_ENABLED_KEY, v ? '1' : '0');
    } catch (e) {
      // 持久化失败则回滚内存态，UI 与存储保持一致；异常抛给调用方提示
      set({ enabled: !v });
      syncPrivacyShield(!v);
      throw e;
    }
  },

  lock: () => {
    // 先落解锁态再置锁：进后台瞬间遮罩必须已立（didBecomeActive 前）
    if (get().enabled && get().hydrated) {
      syncShieldUnlocked(false);
      set({ locked: true });
    }
  },
}));

// ── 生物识别验证辅助 ──

/** 应用锁会话解锁态下发（原生遮罩解除/挂起的唯一开关）。 */
function syncShieldUnlocked(unlocked: boolean): void {
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports -- 原生模块缺失时静默降级
    require('../../modules/tieba-native/src/TiebaNative').TiebaNative.setPrivacyShieldUnlocked(unlocked);
  } catch {}
}

/** 设备具备生物识别硬件且已录入时为 true。 */
export async function isBiometricsReady(): Promise<boolean> {
  try {
    const [hasHardware, isEnrolled] = await Promise.all([
      LocalAuthentication.hasHardwareAsync(),
      LocalAuthentication.isEnrolledAsync(),
    ]);
    return hasHardware && isEnrolled;
  } catch {
    return false;
  }
}

let inFlightAuth: Promise<BiometricAuthOutcome> | null = null;

/**
 * 弹出系统生物识别验证。in-flight 去重：冷启动自动弹与 AppState 回前台
 * 触发可能同帧并发，共用同一 promise 防止叠出两个系统弹窗。
 */
export function authenticateForUnlock(promptMessage: string): Promise<BiometricAuthOutcome> {
  if (inFlightAuth) return inFlightAuth;
  inFlightAuth = (async (): Promise<BiometricAuthOutcome> => {
    try {
      const result = await LocalAuthentication.authenticateAsync({
        promptMessage,
        cancelLabel: '取消',
      });
      if (result.success) return { ok: true };
      return { ok: false, message: authFailureMessage(result.error) };
    } catch (e) {
      console.warn('[appLock] authenticateAsync 异常:', e);
      return { ok: false, message: '验证服务异常，请重试' };
    } finally {
      inFlightAuth = null;
    }
  })();
  return inFlightAuth;
}
