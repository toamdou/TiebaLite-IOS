/**
 * 查看器"打开时"自动揭示被遮挡的源图（2026-08-31 用户要求）：
 * 用户在信息流滑动时点击了一张被屏幕边缘/顶栏部分遮挡的图片 → 进入大图；
 * **查看器打开后立即**让原列表平滑滚动，使卡片图片边缘对齐屏幕边缘
 * （顶栏下方 / 屏底）——用户在查看器内拖动退出时背景已就位（此前在
 * teardown 后瞬间滚动，观感生硬，用户要求改时机或删除）。
 *
 * 架构（挂载点零改动）：
 * - 卡片组件（TweetCard / 帖子正文）在点击图处 armSourceReveal(key, frame)，
 *   随后异步 measure 所在卡片行再 armSourceRevealRow(key, rowTop, rowHeight)
 *   ——行内偏移由此精确已知，移位修正 = 行新位置 + 行内偏移（与滚动量无关）；
 * - 列表组件用 useSourceRevealConsumer(listRef, items, keyOf) 订阅；
 * - 查看器打开后（visible 稳定）调用 revealOnOpen()：滚动列表（平滑），
 *   并返回「移位后的源矩形」（顶部被遮 → y=guardTop；底部被遮 →
 *   y=guardBottom−h）——调用方把它作为飞回源，拖动退出时目标即可见位置。
 * 多列表页（吧页/搜索 3 tab）按 key 匹配天然过滤。
 */

import { useEffect, type RefObject } from 'react';
import type { LegendListRef } from '@legendapp/list/react-native';
import { Dimensions } from 'react-native';
import type { ImageSourceFrame } from '@/hooks/useImageViewer';
import { NAV_BAR_H } from '@/constants/layout';

const { height: SCREEN_H } = Dimensions.get('window');

export interface RevealTarget {
  key: string | number;
  /** 顶部被遮（顶栏下方不可见）→ 滚到卡片顶对齐 guardTop */
  clipTop: boolean;
  /** 移位后的 viewOffset（含行内偏移修正，revealOnOpen 计算） */
  viewOffset: number;
  /** 按压时的原始点击帧（revealOnOpen 填充）：header/非行数据（主楼）的
      消费者用它直接 scrollToOffset 推算滚动量，无需行几何 */
  rawFrame: ImageSourceFrame | null;
}

interface Guards {
  /** 顶栏下缘：图片/行不得高于此（clipTop 场景的最终对齐线） */
  top: number;
  /** 屏底安全区上缘：图片不得低于此（clipBottom 场景的最终对齐线） */
  bottom: number;
  /** SCREEN_H - bottom（= max(insets.bottom,16)）——scrollToItem viewOffset 用 */
  bottomOffset: number;
}

let armedTarget: RevealTarget | null = null;
/** arm 时保存的源矩形副本（移位后修正为可见位置，供飞回使用） */
let armedFrame: ImageSourceFrame | null = null;
let armedGuards: Guards | null = null;
/** 行内偏移（按压时 measure 的卡片行顶/行高 → 图片相对行的偏移） */
let armedRowTop: number | null = null;
let armedRowHeight: number | null = null;
/**
 * 横滑带整组帧（按压时 MediaPager 几何推算：所有图同 y 同高，x 由带内
 * 偏移推出）——翻页后退出按 currentIdx 取对应帧（飞回横滑带里原图位置，
 * 而非查看器底部条格；2026-08-31 用户要求）。armedOpenIndex = 点击图序号，
 * 修正时点击帧用精确 frame 覆盖。
 */
let armedFrames: ImageSourceFrame[] | null = null;
let armedFramesKey: string | number | null = null;
let armedOpenIndex = 0;
/**
 * 横向滑带移位（2026-08-31 用户要求）：多图横滑带里被卡片边缘部分遮挡的
 * 图点开后，**查看器打开后**（后台被 Modal 盖住，不可见）横滑带瞬间移到图
 * 完整可见——用户拖动退出时已就位；移动过程不显示，所以瞬间移动
 * （animated:false，用户："同步移动造成视觉错乱，进入大图之后才后台移动，
 * 因为移动过程完全不显示，所以瞬间移动就行"）。
 * 坐标修正：applyHShiftX 计算滚动量 dx 并**直接并入 armedFrames**（按压时帧
 * 组已建立，与 arm 时序无关）——飞回目标=移位后位置。
 */
let lastHShift: { key: string | number; scroll: () => void } | null = null;
const listeners = new Set<(target: RevealTarget) => void>();

/** 横滑带移位的滚动量（负=左移）：只动 x，几何与滚动偏移差（O−targetX） */
export function applyHShiftX(key: string | number, dx: number): void {
  if (!armedFrames || armedFramesKey !== key) {
    if (__DEV__) {
      console.warn('[hshift] dx skipped', {
        key,
        dx: Math.round(dx),
        hasFrames: !!armedFrames,
        framesKey: armedFramesKey,
      });
    }
    return;
  }
  if (__DEV__) {
    console.warn('[hshift] dx applied', {
      key,
      dx: Math.round(dx),
      n: armedFrames.length,
      f0x: Math.round(armedFrames[0].x),
    });
  }
  armedFrames = armedFrames.map((f) => ({ ...f, x: f.x + dx }));
}

/**
 * 注册"查看器打开后"的横滑带移位（按压时调用，覆盖最近一次）：查看器
 * visible 时 flushHShiftOnOpen 触发，animated:false 瞬间滚动（后台不可见）。
 */
export function armHShiftOnOpen(key: string | number, scroll: () => void): void {
  lastHShift = { key, scroll };
}

/** 查看器打开（visible effect）后调用：触发最近一次按压的横滑带移位 */
export function flushHShiftOnOpen(): void {
  lastHShift?.scroll();
  lastHShift = null;
}

/**
 * 卡片组件在图片点击处调用：记录"该图被屏幕边缘遮挡"的事实（带行 key）。
 * 未越界 / 无 frame → 静默清除。
 */
export function armSourceReveal(
  key: string | number | undefined,
  frame: ImageSourceFrame | null | undefined,
  insets: { top: number; bottom: number },
  opts?: { bottomCovered?: number },
): void {
  if (!frame || frame.width <= 0 || frame.height <= 0 || key === undefined) {
    armedTarget = null;
    armedFrame = null;
    armedGuards = null;
    armedRowTop = null;
    armedRowHeight = null;
    return;
  }
  // bottomCovered：页面底部恒定覆盖物（如帖内浮动条）——图片被它挡住
  // 也算遮挡，移位时让图底对齐覆盖物上缘（2026-08-31 用户：帖子文字多、
  // 图片在下面被遮挡时不会移位）
  const covered = opts?.bottomCovered ?? 0;
  const guardTop = insets.top + NAV_BAR_H;
  const guardBottom = SCREEN_H - Math.max(insets.bottom, 16) - covered;
  const clipTop = frame.y < guardTop;
  const clipBottom = frame.y + frame.height > guardBottom;
  if (!clipTop && !clipBottom) {
    armedTarget = null;
    armedFrame = null;
    armedGuards = null;
    armedRowTop = null;
    armedRowHeight = null;
    return;
  }
  armedTarget = {
    key,
    clipTop,
    // viewPosition 0（顶部对齐）→ 卡片顶落在 guardTop；
    // viewPosition 1（底部对齐）→ 卡片底落在 guardBottom
    viewOffset: 0, // revealOnOpen 修正后下发
    rawFrame: { ...frame },
  };
  armedGuards = { top: guardTop, bottom: guardBottom, bottomOffset: Math.max(insets.bottom, 16) + covered };
  armedFrame = { ...frame };
}

/**
 * 横滑带整组帧（MediaPager 按压时调用）：同卡片内所有图的窗口矩形——
 * 所有图同 y 同高，x = 点击帧.x + (L_j − L_i)（带内偏移差，与滚动偏移无关）。
 * openIndex = 点击图序号，修正时点击帧用精确 frame 覆盖。
 */
export function armSourceRevealFrames(
  key: string | number | undefined,
  frames: ImageSourceFrame[] | null | undefined,
  openIndex: number,
): void {
  if (key === undefined || !frames || frames.length === 0) {
    armedFrames = null;
    armedFramesKey = null;
    return;
  }
  armedFrames = frames;
  armedFramesKey = key;
  armedOpenIndex = openIndex;
}

/**
 * 二段测量（调用点异步 measureInWindow 后调用）：记录"图片所在卡片行"的
 * 几何——reveal 修正用图片相对行的偏移（列表滚动后新位置 = 行新位置 +
 * 行内偏移，与滚动量无关，精确对齐；否则修正帧只对齐行顶/行底，会偏离
 * 图片在行内的真实位置——用户实测动画终点在真实位置之上）。
 */
export function armSourceRevealRow(
  key: string | number | undefined,
  rowTop: number,
  rowHeight: number,
): void {
  if (!armedTarget || armedTarget.key !== key) return;
  armedRowTop = rowTop;
  armedRowHeight = rowHeight;
}

/**
 * 查看器打开后调用：滚动最近一次被遮挡的源图（平滑），返回移位后的
 * 源矩形与**整组横滑带帧**（飞回目标用，翻页后按 currentIdx 取对应帧——
 * 2026-08-31 用户要求"翻页后退回横滑带里对应序号的原图位置"）；
 * 无目标返回 null（打开时不移位、飞回用原 frame）。
 */
export function revealOnOpen(): { frame: ImageSourceFrame; frames: ImageSourceFrame[] } | null {
  const target = armedTarget;
  const guards = armedGuards;
  if (!target || !guards) return null;
  // 基准帧：横滑带帧组存在 → 点击帧（含 applyHShiftX 已并入的 dx）；
  // 否则用单图点击帧
  const baseFrames = armedFrames ?? null;
  const frame = baseFrames ? baseFrames[armedOpenIndex] ?? armedFrame : armedFrame;
  if (!frame) return null;
  const innerTop =
    armedRowTop != null && frame.y > armedRowTop ? frame.y - armedRowTop : 0;
  const rowBottom =
    armedRowTop != null && armedRowHeight != null
      ? armedRowTop + armedRowHeight
      : null;
  const innerBottom =
    rowBottom != null && rowBottom > frame.y + frame.height
      ? rowBottom - (frame.y + frame.height)
      : 0;
  // 点击帧的 y 修正量——横滑带内所有图同 y 同移动量（列表滚动只平移 y）
  const dy =
    (target.clipTop ? guards.top : guards.bottom - frame.height) - frame.y;
  armedTarget = null;
  armedFrame = null;
  armedGuards = null;
  armedRowTop = null;
  armedRowHeight = null;
  armedFrames = null;
  armedFramesKey = null;
  if (target.clipTop) {
    target.viewOffset = guards.top - innerTop;
    frame.y = guards.top; // 图片顶对齐 guardTop
  } else {
    target.viewOffset = -guards.bottomOffset - innerBottom;
    frame.y = guards.bottom - frame.height - innerBottom; // 图片底对齐 guardBottom
  }
  // 整组横滑带帧：同 dy 平移；点击帧（index=armedOpenIndex）直接用修正后的
  // frame（含横滑移位 dx）。单图场景 baseFrames=null → 只有点击帧。
  const frames = baseFrames
    ? baseFrames.map((f, i) => (i === armedOpenIndex ? frame : { ...f, y: f.y + dy }))
    : [frame];
  listeners.forEach((l) => l(target));
  return { frame, frames };
}

/**
 * 打开时（未遮挡也调用）：取按压时记录的整组横滑带帧（未修正原始几何）。
 * 查看器 visible effect 用它初始化 flyback 帧组——翻页退出按 currentIdx 取帧，
 * 无需等待 reveal（reveal 仅在遮挡场景修正 y/x）。
 * 一致性校验：帧组只在「本次按压有同 key 遮挡记录」或「无遮挡记录」时
 * 有效（单图/非横滑场景 armSourceReveal 不建帧组、也不该误用残留帧组——
 * 若残留帧组 key 与本次遮挡记录不一致 → 忽略）。
 */
export function getArmedFramesSnapshot(): ImageSourceFrame[] | null {
  if (!armedFrames) return null;
  if (armedTarget && armedTarget.key !== armedFramesKey) return null;
  return armedFrames.map((f) => ({ ...f }));
}

/**
 * 列表组件订阅：收到目标后若自己的数据含该 key → scrollToItem 对齐屏缘。
 * 找不到该行（如主楼渲染在 ListHeaderComponent、不在列表 data 内）→
 * onMiss(target)（调用方自备滚动方案：scrollToOffset 推算）。
 */
export function useSourceRevealConsumer(
  listRef: RefObject<LegendListRef | null>,
  items: readonly unknown[],
  keyOf: (item: unknown) => string | number | undefined,
  onMiss?: (target: RevealTarget) => void,
): void {
  useEffect(() => {
    const listener = (target: RevealTarget) => {
      const ref = listRef.current;
      if (!ref?.scrollToItem) {
        onMiss?.(target);
        return;
      }
      const hit = items.find((it) => keyOf(it) === target.key);
      if (!hit) {
        onMiss?.(target);
        return;
      }
      void ref.scrollToItem({
        item: hit,
        animated: true,
        viewPosition: target.clipTop ? 0 : 1,
        viewOffset: target.viewOffset,
      });
    };
    listeners.add(listener);
    return () => {
      listeners.delete(listener);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- onMiss 由调用方 useCallback 稳定化
  }, [listRef, items, keyOf]);
}