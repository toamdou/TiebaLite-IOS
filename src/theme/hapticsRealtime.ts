// ============================================================
// TiebaLite - Realtime Haptics (实时触觉：非离散场景的专属效果)
//
// 与场景映射表（hapticsMap，离散事件）互补的一层。设计纪律（用户拍板，
// 2026-08-26）：只挂低频、意图明确的手势瞬间；信息流滚动等高频场景
// 刻意不做——高频震动只会招人烦。
//
// 当前效果：
// - imageLiftPop「长按弹出大图」：长按激活、大图预览升起动画开始的
//   一瞬间的单次柔和瞬态。触发源=原生 TiebaPhotoContextMenuView 的
//   onMenuPresent 事件（仅 previewEnabled=true 时发），经 PostImageContextMenu
//   调 playImageLiftHaptic()。
// - likeCharge「点赞蓄力」：按住点赞期间低强度连续底噪，松手即停
//   （TweetCard LikeButton）。
//
// 每个效果可在 设置-震动设置「实时触觉」独立开关与调强度
// （偏好键 hapticsRealtimeStyles，JSON：{effectId: level}，缺省=适中开）。
// 总开关「震动反馈」在 utils/haptics 包装层统一门控。
// ============================================================

import { usePreferencesStore } from '@/stores/preferencesStore';
import {
  hapticEvents,
  rtCreatePlayer,
  rtStartPlayer,
  rtUpdatePlayer,
  rtStopPlayer,
} from '@/utils/haptics';

export type RealtimeEffectId = 'imageLiftPop' | 'likeCharge';
export type RealtimeLevel = 'off' | 'light' | 'medium' | 'strong';

export const REALTIME_EFFECT_META: { id: RealtimeEffectId; label: string }[] = [
  { id: 'imageLiftPop', label: '长按弹出大图' },
  { id: 'likeCharge', label: '点赞蓄力' },
];

/** 档位→强度缩放；未设置=medium（默认开、适中强度） */
const LEVEL_SCALE: Record<Exclude<RealtimeLevel, 'off'>, number> = {
  light: 0.55,
  medium: 0.8,
  strong: 1,
};

/** 解析某效果的当前强度缩放；null=该效果已被关闭 */
function resolveScale(effect: RealtimeEffectId): number | null {
  try {
    const raw = usePreferencesStore.getState().preferences.hapticsRealtimeStyles;
    const parsed: unknown = JSON.parse(raw || '{}');
    if (parsed && typeof parsed === 'object') {
      const level = (parsed as Record<string, unknown>)[effect];
      if (level === 'off') return null;
      if (level === 'light') return LEVEL_SCALE.light;
      if (level === 'strong') return LEVEL_SCALE.strong;
    }
    return LEVEL_SCALE.medium;
  } catch {
    return LEVEL_SCALE.medium;
  }
}

/**
 * 「长按弹出大图」一瞬间：单次柔和瞬态（强度随档位缩放）。
 * 触发时机=原生菜单/预览升起动画开始（onMenuPresent），与视觉升起同步。
 */
export function playImageLiftHaptic(): void {
  const scale = resolveScale('imageLiftPop');
  if (scale == null) return;
  hapticEvents([
    {
      type: 'transient',
      relativeTime: 0,
      parameters: [
        { type: 'intensity', value: Math.max(0.05, Math.min(1, 0.55 * scale)) },
        { type: 'sharpness', value: 0.45 },
      ],
    },
  ]);
}

// ── likeCharge 点赞蓄力（连续播放器；单一实例 + 所有权仲裁）──

const PLAYER_ID = 'tieba.likeCharge';
const CHARGE_INTENSITY = 0.3;
const CHARGE_SHARPNESS = 0.25;

let playerCreated = false;
let playerStarted = false;

function ensurePlayer(): void {
  if (playerCreated) return;
  rtCreatePlayer(PLAYER_ID, CHARGE_INTENSITY, CHARGE_SHARPNESS);
  playerCreated = true;
}

/** 按下开始蓄力：拉起连续底噪。重复调用幂等；效果关闭时静默。 */
export function rtBeginLikeCharge(): void {
  const scale = resolveScale('likeCharge');
  if (scale == null) return;
  ensurePlayer();
  if (!playerStarted) {
    rtUpdatePlayer(
      PLAYER_ID,
      Math.max(0.08, CHARGE_INTENSITY * scale),
      CHARGE_SHARPNESS,
    );
    rtStartPlayer(PLAYER_ID);
    playerStarted = true;
  }
}

/** 松手/移出结束蓄力。幂等；不受总开关门控（禁用瞬间也要能停）。 */
export function rtEndLikeCharge(): void {
  if (!playerStarted) return;
  playerStarted = false;
  rtStopPlayer(PLAYER_ID);
}
