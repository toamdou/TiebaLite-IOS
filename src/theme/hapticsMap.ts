// ============================================================
// TiebaLite - Haptic Scene Map (震动风格映射表)
//
// 设计规范（2026-08-26 AHAP 化）：场景 → tickle/Core Haptics 自定义模式。
// 现有 221 处调用点风格不统一，全部收敛到本映射表，一处修改全局生效。
// 每个场景都是瞬态/连续事件组合（时间单位=毫秒）；强度档位覆盖
// （轻/中/强）按比例缩放全部事件的 intensity。
// ============================================================

import {
  hapticEvents,
  hapticImpact,
  hapticNotify,
  hapticSelection,
  ImpactFeedbackStyle,
  NotificationFeedbackType,
  type HapticEvent,
} from '@/utils/haptics';
import { usePreferencesStore } from '@/stores/preferencesStore';

// ---------- 场景类型 ----------

export type HapticsScene =
  | 'press' // 轻按、卡片按压
  | 'toggle' // 开关、分段切换
  | 'segment' // tab/segment 页切换（横滑落定或点切）
  | 'like' // 点赞
  | 'favorite' // 收藏
  | 'sheet-present' // 浮层展开
  | 'long-press' // 长按菜单开启
  | 'destructive' // 破坏性操作确认（删除/清除/移除）
  | 'action-success' // 任务成功
  | 'action-fail' // 任务失败
  | 'action-warning'; // 任务警示（非致命异常）

// ---------- AHAP 组合子（毫秒） ----------

/** 瞬态：即时的单点触觉 */
const t = (relativeTime: number, intensity: number, sharpness: number): HapticEvent => ({
  type: 'transient',
  relativeTime,
  parameters: [
    { type: 'intensity', value: intensity },
    { type: 'sharpness', value: sharpness },
  ],
});

/** 连续段：有持续时间的纹理 */
const c = (
  relativeTime: number,
  duration: number,
  intensity: number,
  sharpness: number,
): HapticEvent => ({
  type: 'continuous',
  relativeTime,
  duration,
  parameters: [
    { type: 'intensity', value: intensity },
    { type: 'sharpness', value: sharpness },
  ],
});

// ---------- 映射表 ----------
//
// 全部为瞬态组合（仅 like/sheet-present/long-press 带无曲线连续段）：
// 刻意不用 parameter curve——它是 pattern 级乘子，会同时调制 pattern 内
// 全部事件的强度（包文档 Limitations 节），纯瞬态组合没有这个坑。

type HapticEntry =
  | { kind: 'impact'; style: ImpactFeedbackStyle }
  | { kind: 'selection' }
  | { kind: 'notification'; type: NotificationFeedbackType }
  | { kind: 'pattern'; events: HapticEvent[] };

export const HAPTICS_MAP: Record<HapticsScene, HapticEntry> = {
  // 清脆轻点（对应旧 Light 手感）
  press: { kind: 'pattern', events: [t(0, 0.7, 0.6)] },
  // 锋利小 click（selection 质感）
  toggle: { kind: 'pattern', events: [t(0, 0.5, 1.0)] },
  segment: { kind: 'pattern', events: [t(0, 0.55, 0.85)] },
  // 点赞 pop：重击 + 70ms 短嗡尾（情绪峰值，明显重于按压）
  like: { kind: 'pattern', events: [t(0, 1.0, 0.8), c(0, 70, 0.4, 0.35)] },
  // 收藏：双击确认节奏
  favorite: { kind: 'pattern', events: [t(0, 0.7, 0.45), t(90, 1.0, 0.35)] },
  // 浮层展开：柔和短纹理
  'sheet-present': { kind: 'pattern', events: [c(0, 90, 0.3, 0.25)] },
  // 长按菜单开启：低锋利度软提示
  'long-press': { kind: 'pattern', events: [c(0, 60, 0.3, 0.2)] },
  // 破坏性确认：沉闷重击两拍（警示节奏）
  destructive: { kind: 'pattern', events: [t(0, 1.0, 0.25), t(130, 1.0, 0.2)] },
  // 成功：上行三连（渐强渐锐，积极收尾）
  'action-success': {
    kind: 'pattern',
    events: [t(0, 0.55, 0.5), t(80, 0.75, 0.75), t(160, 1.0, 1.0)],
  },
  // 警示：先锐后钝的双拍
  'action-warning': { kind: 'pattern', events: [t(0, 0.9, 0.9), t(120, 0.9, 0.3)] },
  // 失败：下行（重击落空感）
  'action-fail': { kind: 'pattern', events: [t(0, 1.0, 0.9), t(110, 0.7, 0.35)] },
};

// ---------- 每场景自定义（设置-震动设置） ----------

/** 用户可选的风格值：'default'=跟随内置映射表；'off'=该场景静音；其余=整体浓淡缩放 */
export type HapticStyleChoice = 'default' | 'off' | 'light' | 'medium' | 'heavy';

/** 强度档位 → 全事件 intensity 缩放系数（上限钳在 1） */
const SCALE_BY_CHOICE: Partial<Record<Exclude<HapticStyleChoice, 'default' | 'off'>, number>> = {
  light: 0.6,
  medium: 0.8,
  heavy: 1,
};

/** 旧档位（rigid/soft）对 AHAP 模式无意义：视为未覆盖回落内置映射 */
const LEGACY_IGNORED_CHOICES = new Set(['rigid', 'soft']);

// ---------- 波形覆盖（设置-震动设置：节奏而非力度） ----------

/** 用户可选的波形值：'default'=跟随场景内置波形；其余=预设节奏替换 events */
export type HapticWaveformChoice = 'default' | 'single' | 'double' | 'rising' | 'soft';

/** 波形预设（纯瞬态组合；与内置波形同用 t/c 组合子，可被力度缩放叠加） */
export const WAVEFORM_PRESETS: Record<
  Exclude<HapticWaveformChoice, 'default'>,
  HapticEvent[]
> = {
  // 只振一下：单次清脆轻点（用户诉求「选择只震动一次」的通用解）
  single: [t(0, 0.7, 0.6)],
  // 双脉冲：两下快而轻（确认节奏，比内置多拍模式收敛）
  double: [t(0, 0.7, 0.6), t(90, 0.55, 0.45)],
  // 渐强三连：上行渐锐（积极收尾，但比 action-success 内置轻）
  rising: [t(0, 0.45, 0.4), t(80, 0.7, 0.7), t(160, 1.0, 1.0)],
  // 轻柔：单次低强度柔冲击（不想被打扰的场合）
  soft: [t(0, 0.3, 0.25)],
};

/** 震动设置页波形可选档 */
export const WAVEFORM_CHOICES: { value: HapticWaveformChoice; label: string }[] = [
  { value: 'default', label: '内置波形' },
  { value: 'single', label: '单次' },
  { value: 'double', label: '双脉冲' },
  { value: 'rising', label: '渐强三连' },
  { value: 'soft', label: '轻柔' },
];

function scaleIntensity(events: HapticEvent[], factor: number): HapticEvent[] {
  return events.map((event) => ({
    ...event,
    parameters: event.parameters.map((p) =>
      p.type === 'intensity'
        ? { type: 'intensity' as const, value: Math.max(0.05, Math.min(1, p.value * factor)) }
        : p,
    ),
  }));
}

/** 场景元数据（震动设置页渲染用）：分组 + 中文名 */
export const HAPTIC_SCENE_META: {
  scene: HapticsScene;
  label: string;
  group: 'action' | 'signal';
}[] = [
  { scene: 'press', label: '轻按', group: 'action' },
  { scene: 'like', label: '点赞', group: 'action' },
  { scene: 'favorite', label: '收藏', group: 'action' },
  { scene: 'destructive', label: '破坏性确认', group: 'action' },
  { scene: 'sheet-present', label: '浮层展开', group: 'action' },
  { scene: 'long-press', label: '长按菜单', group: 'action' },
  { scene: 'toggle', label: '开关切换', group: 'signal' },
  { scene: 'segment', label: '页面切换', group: 'signal' },
  { scene: 'action-success', label: '操作成功', group: 'signal' },
  { scene: 'action-warning', label: '操作警示', group: 'signal' },
  { scene: 'action-fail', label: '操作失败', group: 'signal' },
];

/** 读取用户覆盖表：存储不可信，坏 JSON/未知键值一律忽略回落内置映射 */
function getSceneOverrides(): Partial<Record<HapticsScene, string>> {
  try {
    const raw = usePreferencesStore.getState().preferences.hapticsSceneStyles;
    const parsed: unknown = JSON.parse(raw || '{}');
    if (parsed && typeof parsed === 'object') {
      return parsed as Partial<Record<HapticsScene, string>>;
    }
  } catch {}
  return {};
}

/** 读取用户波形覆盖表：存储不可信，坏 JSON/未知键值一律忽略回落内置波形 */
function getWaveformOverrides(): Partial<Record<HapticsScene, string>> {
  try {
    const raw = usePreferencesStore.getState().preferences.hapticsWaveforms;
    const parsed: unknown = JSON.parse(raw || '{}');
    if (parsed && typeof parsed === 'object') {
      return parsed as Partial<Record<HapticsScene, string>>;
    }
  } catch {}
  return {};
}

/** 解析某场景的最终触觉条目；null=用户将该场景设为静音 */
export function resolveHapticEntry(scene: HapticsScene): HapticEntry | null {
  const override = getSceneOverrides()[scene];
  const base = HAPTICS_MAP[scene];
  if (!base) return null;
  // 波形覆盖：用预设 events 替换内置波形（仅 pattern 场景；impact 类忽略）。
  // 与力度档位正交：波形先行，力度缩放仍叠加在其上。
  let waveEvents: HapticEvent[] | null = null;
  if (base.kind === 'pattern') {
    const waveform = getWaveformOverrides()[scene];
    if (waveform && waveform !== 'default') {
      const preset = WAVEFORM_PRESETS[waveform as Exclude<HapticWaveformChoice, 'default'>];
      if (preset) waveEvents = preset;
    }
  }
  if (!override || override === 'default' || LEGACY_IGNORED_CHOICES.has(override)) {
    if (waveEvents) return { kind: 'pattern', events: waveEvents };
    return base;
  }
  if (override === 'off') return null;
  if (base.kind === 'pattern') {
    const events = waveEvents ?? base.events;
    const factor =
      SCALE_BY_CHOICE[override as Exclude<HapticStyleChoice, 'default' | 'off'>];
    if (factor !== undefined) {
      return { kind: 'pattern', events: scaleIntensity(events, factor) };
    }
    return { kind: 'pattern', events };
  }
  return base;
}

export function hapticForScene(scene: HapticsScene): Promise<void> {
  const entry = resolveHapticEntry(scene);
  if (!entry) return Promise.resolve();
  switch (entry.kind) {
    case 'impact':
      return hapticImpact(entry.style);
    case 'selection':
      return hapticSelection();
    case 'notification':
      return hapticNotify(entry.type);
    case 'pattern':
      hapticEvents(entry.events);
      return Promise.resolve();
  }
}
