import { useState, useEffect } from 'react';
import { requireOptionalNativeModule } from 'expo';

/**
 * tieba-system — iOS 系统能力桥接：低功耗模式 + 内存警告。
 * 原生侧见 modules/tieba-system/ios/TiebaSystemModule.swift。
 * 模块缺失（如 Expo Go / 未重新构建 dev client）时全部 API 优雅降级：
 * getLowPowerMode() 返回 false，事件订阅返回 null，不会抛错。
 */

export interface TiebaSystemNativeModule {
  getLowPowerMode(): Promise<boolean>;
  addListener(eventName: string, listener: (payload: unknown) => void): {
    remove: () => void;
  };
}

type ListenerRemover = { remove(): void } | null;

let cached: TiebaSystemNativeModule | null | undefined;

function getNative(): TiebaSystemNativeModule | null {
  if (cached === undefined) {
    cached = requireOptionalNativeModule<TiebaSystemNativeModule>('TiebaSystem') ?? null;
  }
  return cached;
}

/** 读取当前低功耗模式状态（iOS Low Power Mode）。 */
export async function getLowPowerMode(): Promise<boolean> {
  const native = getNative();
  if (!native) return false;
  try {
    return (await native.getLowPowerMode()) === true;
  } catch {
    return false;
  }
}

/**
 * 订阅低功耗模式变化，回调携带最新开关状态。
 * 返回 { remove() } 用于清理；原生模块缺失时返回 null。
 */
export function addLowPowerModeListener(
  listener: (enabled: boolean) => void,
): ListenerRemover {
  const native = getNative();
  if (!native) return null;
  const sub = native.addListener('onLowPowerModeChange', (payload: unknown) => {
    listener((payload as { enabled?: boolean } | null)?.enabled === true);
  });
  return { remove: () => sub.remove() };
}

/**
 * 订阅 iOS 内存警告。回调里应做全局内存清理（如 expo-image 内存缓存）。
 * 返回 { remove() } 用于清理；原生模块缺失时返回 null。
 */
export function onMemoryWarning(listener: () => void): ListenerRemover {
  const native = getNative();
  if (!native) return null;
  const sub = native.addListener('onMemoryWarning', () => listener());
  return { remove: () => sub.remove() };
}

/**
 * React Hook：读取并跟踪低功耗模式。
 * 初始值来自原生快照，随后由事件推送保持同步。
 */
export function useLowPowerMode(): boolean {
  const [enabled, setEnabled] = useState<boolean>(false);

  useEffect(() => {
    let mounted = true;
    void getLowPowerMode().then((value) => {
      if (mounted) setEnabled(value);
    });
    const sub = addLowPowerModeListener((value) => {
      if (mounted) setEnabled(value);
    });
    return () => {
      mounted = false;
      sub?.remove();
    };
  }, []);

  return enabled;
}

// ── 诊断日志（闪退/信号崩溃/主线程卡死/JS 错误）──
// 原生采集仅 Release 安装（AppDelegate 运行时查找 TiebaSystemCrashReporter）；
// 本组是查询/管理面。旧二进制没有这些函数 → 特性检测后优雅降级，绝不抛错。

export interface DiagnosticLogEntry {
  /** 文件名，如 crash-2026-08-26_14-03-22.log */
  name: string;
  size: number;
  mtimeMs: number;
}

/** 模块上可能存在（新二进制）的诊断函数；旧二进制缺省 → typeof 检测兜底 */
type DiagnosticsExtras = {
  listDiagnosticLogs?: () => string;
  readDiagnosticLog?: (name: string) => string;
  deleteDiagnosticLogs?: (names: string[]) => boolean;
  clearDiagnosticLogs?: () => boolean;
  appendJsError?: (summary: string) => boolean;
};

function diagnostics(): DiagnosticsExtras | null {
  const native = getNative();
  if (!native) return null;
  return native as unknown as DiagnosticsExtras;
}

/** 列出诊断日志（新→旧）。原生缺失/函数不存在时返回 []。 */
export async function listDiagnosticLogs(): Promise<DiagnosticLogEntry[]> {
  const d = diagnostics();
  if (typeof d?.listDiagnosticLogs !== 'function') return [];
  try {
    const parsed = JSON.parse(d.listDiagnosticLogs()) as DiagnosticLogEntry[];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

/** 读取单条日志全文。失败/缺失返回空串。 */
export async function readDiagnosticLog(name: string): Promise<string> {
  const d = diagnostics();
  if (typeof d?.readDiagnosticLog !== 'function') return '';
  try {
    return d.readDiagnosticLog(name);
  } catch {
    return '';
  }
}

/** 删除指定日志。 */
export async function deleteDiagnosticLogs(names: string[]): Promise<void> {
  const d = diagnostics();
  if (typeof d?.deleteDiagnosticLogs === 'function') {
    try { d.deleteDiagnosticLogs(names); } catch {}
  }
}

/** 清空全部诊断日志。 */
export async function clearDiagnosticLogs(): Promise<void> {
  const d = diagnostics();
  if (typeof d?.clearDiagnosticLogs === 'function') {
    try { d.clearDiagnosticLogs(); } catch {}
  }
}

/**
 * JS 全局错误落盘（Release 原生才真正写入）。fire-and-forget，永不抛错。
 * 调用方自行限频（见 _layout 全局错误钩子：会话级最多 20 条）。
 */
export function appendJsError(summary: string): void {
  const d = diagnostics();
  if (typeof d?.appendJsError === 'function') {
    try { d.appendJsError(summary.slice(0, 500)); } catch {}
  }
}
