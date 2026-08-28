// ============================================================
// haptics - Global haptic feedback utility (震动反馈)
//
// Every haptic call in the app should go through these wrappers
// so the "震动反馈" toggle in Settings (AppPreferences.hapticFeedback,
// default: true) can globally enable/disable ALL haptic feedback.
//
// Backend（2026-08-26 替换）: expo-haptics → @renegades/react-native-tickle
// （Nitro + Core Haptics，iOS）。在系统预设之外新增 AHAP 自定义模式
// （hapticEvents：瞬态/连续事件自由组合；时间单位=毫秒，Swift 侧自动
// /1000 转秒）供场景映射表使用。
//
// Design:
// - Sync wrappers read the preference once per call via
//   usePreferencesStore.getState()（zustand 内存态，无 AsyncStorage 读；
//   未完成 hydration 时回退为启用态）。
// - tickle 模块惰性 require + try/catch 守卫：旧二进制未链接 Tickle 原生
//   模块时全部触觉静默降级，绝不崩 UI（本项目「旧包跑新 JS」红线）。
// - 引擎生命周期（active 初始化 / background 销毁，包内 resetHandler 自恢复）
//   由 installHapticEngineLifecycle 在根布局安装一次；总开关变化经
//   syncHapticEnginePower 即时加减引擎。不使用包自带的持久化开关——
//   全局唯一真相源是 AppPreferences.hapticFeedback。
// - All native calls are best-effort (try/catch) — unsupported
//   devices/emulators may reject.
// ============================================================

import { AppState } from 'react-native';
import { usePreferencesStore } from '@/stores/preferencesStore';

type TickleModule = typeof import('@renegades/react-native-tickle');

let tickleModule: TickleModule | null | undefined;

/** 惰性取 tickle 模块；不可用（旧二进制未链接/非 iOS）返回 null 永久静默。 */
function getTickle(): TickleModule | null {
  if (tickleModule === undefined) {
    try {
      tickleModule = require('@renegades/react-native-tickle') as TickleModule;
    } catch {
      tickleModule = null;
    }
  }
  return tickleModule;
}

// ── 枚举壳（与旧 expo-haptics 同形：同名值成员 + 同名类型），调用点零改动 ──

export const ImpactFeedbackStyle = {
  Light: 'light',
  Medium: 'medium',
  Heavy: 'heavy',
  Rigid: 'rigid',
  Soft: 'soft',
} as const;
export type ImpactFeedbackStyle =
  (typeof ImpactFeedbackStyle)[keyof typeof ImpactFeedbackStyle];

export const NotificationFeedbackType = {
  Success: 'success',
  Warning: 'warning',
  Error: 'error',
} as const;
export type NotificationFeedbackType =
  (typeof NotificationFeedbackType)[keyof typeof NotificationFeedbackType];

// ── AHAP 类型透传（场景映射表用）──

export type HapticEvent = import('@renegades/react-native-tickle').HapticEvent;
export type HapticCurve = import('@renegades/react-native-tickle').HapticCurve;

export function isHapticEnabledSync(): boolean {
  const state = usePreferencesStore.getState();
  return state.hasHydrated ? state.preferences.hapticFeedback : true;
}

function safe(run: () => void): void {
  if (!isHapticEnabledSync()) return;
  try {
    run();
  } catch {
    // Best-effort: haptics are optional, never crash the UI.
  }
}

/**
 * Impact feedback（Light / Medium / Heavy / Rigid / Soft）。
 * No-ops when the global haptic toggle is disabled.
 */
export async function hapticImpact(
  style: ImpactFeedbackStyle = ImpactFeedbackStyle.Light,
): Promise<void> {
  safe(() => getTickle()?.triggerImpact(style));
}

/**
 * Notification feedback (Success / Warning / Error) for task outcomes.
 * No-ops when the global haptic toggle is disabled.
 */
export async function hapticNotify(
  type: NotificationFeedbackType,
): Promise<void> {
  safe(() => getTickle()?.triggerNotification(type));
}

/**
 * Selection-change feedback for pickers, segmented controls and other
 * "selection changed" moments. No-ops when the global haptic toggle is
 * disabled.
 */
export async function hapticSelection(): Promise<void> {
  safe(() => getTickle()?.triggerSelection());
}

/**
 * 播放自定义 AHAP 模式（瞬态/连续事件组合）。曲线慎用：Core Haptics 的
 * parameter curve 是 pattern 级乘子，会同时调制该 pattern 内全部事件的
 * 强度/锋利度（含瞬态）——需要瞬态与带曲线的连续段并存时分两次调用。
 */
export function hapticEvents(events: HapticEvent[], curves: HapticCurve[] = []): void {
  safe(() => getTickle()?.startHaptic(events, curves));
}

/** 停掉所有在播触觉（页面卸载/路由移除时兜底，防止跨页余震）。 */
export function stopAllHapticsSafe(): void {
  try {
    getTickle()?.stopAllHaptics();
  } catch {}
}

// ── 连续播放器（实时手势跟随触觉；上层封装见 theme/hapticsRealtime.ts）──
// 纪律：start/update 走总开关门控（禁用即无声）；stop 一律不门控——
// 禁用瞬间不能把正在震的手势留在半空。

export function rtCreatePlayer(
  playerId: string,
  initialIntensity: number,
  initialSharpness: number,
): void {
  try {
    getTickle()?.createContinuousPlayer(playerId, initialIntensity, initialSharpness);
  } catch {}
}

export function rtStartPlayer(playerId: string): void {
  safe(() => getTickle()?.startContinuousPlayer(playerId));
}

export function rtUpdatePlayer(
  playerId: string,
  intensityControl: number,
  sharpnessControl: number,
): void {
  safe(() =>
    getTickle()?.updateContinuousPlayer(playerId, intensityControl, sharpnessControl),
  );
}

export function rtStopPlayer(playerId: string): void {
  try {
    getTickle()?.stopContinuousPlayer(playerId);
  } catch {}
}

// ── 引擎生命周期 ──

let engineLifecycleInstalled = false;

/**
 * 安装引擎生命周期管理（根布局调用一次）：active 时按总开关预热引擎，
 * background 销毁省电；安装当下立即预热一次。引擎中断由包内 resetHandler
 * 自行重启。
 */
export function installHapticEngineLifecycle(): void {
  if (engineLifecycleInstalled) return;
  engineLifecycleInstalled = true;
  if (!getTickle()) return;
  AppState.addEventListener('change', (state) => {
    if (state === 'active') {
      syncHapticEnginePower(isHapticEnabledSync());
    } else if (state === 'background') {
      try {
        getTickle()?.destroyEngine();
      } catch {}
    }
  });
  syncHapticEnginePower(isHapticEnabledSync());
}

/**
 * 总开关变化 / 回前台时调用：enabled=true 预热引擎（消除首触发迟滞），
 * false 直接销毁。开关关闭期间各触发函数本就被 isHapticEnabledSync 短路，
 * 这里额外把引擎也停掉以省电。
 */
export function syncHapticEnginePower(enabled: boolean): void {
  try {
    if (enabled) getTickle()?.initializeEngine();
    else getTickle()?.destroyEngine();
  } catch {}
}
