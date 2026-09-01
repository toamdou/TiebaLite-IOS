/**
 * ImageViewer 缩放核心（2026-08-30 换库落地 → 2026-09-01 RNGH v3 hooks 重建）。
 *
 * 行为契约（消费方 parts.tsx / ImageViewer.tsx 只依赖返回形状，内部可换）：
 * - useZoomGesture(props) 返回 { zoomGesture, contentContainerAnimatedStyle,
 *   onLayout, onLayoutContent, isZoomedIn, zoomGestureLastTime, scale, zoomOut }
 * - 单指未缩放（scale ≤ 1.01）时 pan 直接 fail，交父级拖拽关闭/长图阅读；
 * - 捏合（focal + rubber band + 30% focal 混合）、双击缩放（围绕点击点）、
 *   缩放态 pan（边界回弹 + 动量）、放大态边缘溢出翻页（enableGallerySwipe）；
 * - 松手 clamp（scale 回 1 或位置回界），isZoomedIn 镜像、zoomGestureLastTime
 *   脉冲（父级用 gesturePulse 收起 UI）。
 */
import { useCallback, type RefObject } from 'react';
import type { LayoutChangeEvent } from 'react-native';
import {
  GestureStateManager,
  usePanGesture,
  usePinchGesture,
  useSimultaneousGestures,
  useTapGesture,
} from 'react-native-gesture-handler';
import {
  runOnJS,
  useAnimatedReaction,
  useAnimatedStyle,
  useSharedValue,
  withDecay,
  withSpring,
  withTiming,
} from 'react-native-reanimated';

// ── 常量（对齐 react-native-zoom-reanimated 1.5.6 行为档位）──
/** 捏合缩放上限（含 rubber band 外扩） */
export const MAX_SCALE = 4;
/** 默认双击目标倍率（doubleTapConfig.defaultScale 传入时优先） */
export const DOUBLE_TAP_SCALE = 2;
/** 缩放动画时长（ms） */
export const ANIMATION_DURATION = 350;
/** 双击判定点击距离容差（pt）——parts.tsx 的 noop 双击共用同一档 */
export const TAP_MAX_DELTA = 25;
/** 超界捏合橡皮筋阻尼系数 */
const RUBBER_BAND = 0.55;
/** 捏合最小可缩目标：不允许缩到 <1（默认态缩小会出现四周黑边，
 *  2026-09-01 用户实测不满意；复位交给 JS 线程动画保证回弹） */
const MIN_PINCH_SCALE = 1;
/** 松手保持放大阈值（>1.01 保持，≤1.01 复位） */
const ZOOMED_THRESHOLD = 1.01;
/** 边界回弹弹簧 */
const SPRING_CONFIG = { damping: 20, stiffness: 250, mass: 0.5 };
/** 缩放态 pan 松手动量衰减 */
const MOMENTUM_DECELERATION = 0.997;
/** 边缘溢出触发翻页的位移阈值（pt） */
const GALLERY_BOUNDARY = 64;
/** 边缘溢出触发翻页的速度阈值（pt/s，同向） */
const GALLERY_VELOCITY = 1200;
/** 翻页后缩放复位延迟（ms）：给原生 PagerView 滑动的视觉时间 */
const RESET_DELAY = 300;

/** 父容器翻页协议（与 react-native-zoom-reanimated 的 ScrollableRef 同形） */
export interface ScrollableRef {
  scrollToOffset?: (opts: { offset: number; animated?: boolean }) => void;
  scrollTo?: (x: number, y: number, animated?: boolean) => void;
}

export interface ZoomGestureOptions {
  minScale: number;
  maxScale: number;
  /** 放大态拖到边缘溢出时切页（照片级图库滑动） */
  enableGallerySwipe: boolean;
  /** 翻页目标容器（PagerView adapter，见 ImageViewer.tsx galleryScrollRef） */
  parentScrollRef: RefObject<ScrollableRef>;
  /** 当前页绝对下标（翻页目标 = (当前 ± 1) × itemWidth） */
  currentIndex: number;
  /** 总页数：边界页（首/末）溢出不翻页、也不复位缩放（见 pan onDeactivate） */
  pageCount: number;
  /** 单页宽度（pt） */
  itemWidth: number;
  doubleTapConfig?: { defaultScale: number; minZoomScale: number; maxZoomScale: number };
}

/** worklet 纯函数：内容在容器内的边界半幅（scale 1 时为 0，内容不露白）
 *  显式 'worklet'：被 worklet 回调直接调用，曾实测无指令的模块函数会抛
 *  non-worklet function 异常（同场景见 ImageViewer.tsx prepareFlyOut） */
const clampHalf = (
  contentSize: number,
  layoutSize: number,
  scale: number,
): number => {
  'worklet';
  return Math.max(0, (contentSize * scale - layoutSize) / 2);
};

export function useZoomGesture({
  minScale,
  maxScale,
  enableGallerySwipe,
  parentScrollRef,
  currentIndex,
  pageCount,
  itemWidth,
  doubleTapConfig,
}: ZoomGestureOptions) {
  const scale = useSharedValue(1);
  const translateX = useSharedValue(0);
  const translateY = useSharedValue(0);
  /** 放大态镜像（UI 线程直读，父级 dismiss 门控） */
  const isZoomedIn = useSharedValue(false);
  /** 手势脉冲：每次手势动一下 +1（父级用变化驱动 Chrome 自动收起） */
  const zoomGestureLastTime = useSharedValue(0);
  /** 容器/内容实测尺寸（onLayout/onLayoutContent 写入） */
  const layoutW = useSharedValue(0);
  const layoutH = useSharedValue(0);
  const contentW = useSharedValue(0);
  const contentH = useSharedValue(0);
  /** 手势基线（激活瞬间快照，防中途重建跳变） */
  const savedScale = useSharedValue(1);
  const savedTranslateX = useSharedValue(0);
  const savedTranslateY = useSharedValue(0);
  const savedFocalX = useSharedValue(0);
  const savedFocalY = useSharedValue(0);
  /** 放大态贴边后继续拖的溢出量（gallery swipe 判定用） */
  const galleryOverX = useSharedValue(0);

  useAnimatedReaction(
    () => scale.value,
    (s) => {
      isZoomedIn.value = s > ZOOMED_THRESHOLD;
    },
  );

  /** 收边界：位置钳回内容内（弹簧）；未放大（≤1.01）→ 瞬间归位。
 *  2026-09-01 用户要求：不允许缩小至 1 以下 + 无回弹动画——捏合过程已
 *  clamp ≥1，这里兜底直接赋值归位（不启动 withTiming：worklet 动画在
 *  历史实证中偶发不推进，僵硬停在缩小态就是此坑，直接赋值最稳）。 */
  const applyBoundaryConstraints = () => {
    'worklet';
    if (scale.value <= ZOOMED_THRESHOLD || scale.value < minScale) {
      scale.value = 1;
      translateX.value = 0;
      translateY.value = 0;
      return;
    }
    const maxX = clampHalf(contentW.value, layoutW.value, scale.value);
    const maxY = clampHalf(contentH.value, layoutH.value, scale.value);
    const tx = Math.max(-maxX, Math.min(maxX, translateX.value));
    const ty = Math.max(-maxY, Math.min(maxY, translateY.value));
    if (tx !== translateX.value) translateX.value = withSpring(tx, SPRING_CONFIG);
    if (ty !== translateY.value) translateY.value = withSpring(ty, SPRING_CONFIG);
  };

  // ── 捏合：双指 focal 缩放（rubber band + 30% focal 混合）──
  const pinchGesture = usePinchGesture({
    onTouchesDown: (e) => {
      'worklet';
      if (e.numberOfTouches >= 2) GestureStateManager.activate(e.handlerTag);
    },
    onActivate: (e) => {
      'worklet';
      savedScale.value = scale.value;
      savedFocalX.value = e.focalX;
      savedFocalY.value = e.focalY;
      zoomGestureLastTime.value = Date.now();
    },
    onUpdate: (e) => {
      'worklet';
      let target = savedScale.value * e.scale;
      if (target > maxScale) {
        target = maxScale + (target - maxScale) * RUBBER_BAND;
      } else if (target < MIN_PINCH_SCALE) {
        target = MIN_PINCH_SCALE;
      }
      // focal 30% 混合：抑制放手/换指瞬间的焦点跳变，同时保留跟随
      const fx = savedFocalX.value + (e.focalX - savedFocalX.value) * 0.3;
      const fy = savedFocalY.value + (e.focalY - savedFocalY.value) * 0.3;
      const old = scale.value;
      if (old === target) return;
      scale.value = target;
      // 保持 focal 点下内容不漂移：translate 差 = (f - center) × (1 - new/old)
      const cx = layoutW.value / 2;
      const cy = layoutH.value / 2;
      translateX.value += (fx - cx) * (1 - target / old);
      translateY.value += (fy - cy) * (1 - target / old);
    },
    onDeactivate: () => {
      'worklet';
      applyBoundaryConstraints();
      zoomGestureLastTime.value = Date.now();
    },
  });

  // ── 边缘溢出翻页（worklet 侧判定，JS 侧执行翻页 + 延迟复位缩放）──
  const jumpToPage = useCallback(
    (dir: 1 | -1) => {
      const ref = parentScrollRef.current;
      if (!ref?.scrollToOffset) return;
      const base = (currentIndex + dir) * itemWidth;
      if (base < 0) return;
      ref.scrollToOffset({ offset: base, animated: true });
    },
    [parentScrollRef, currentIndex, itemWidth],
  );
  const resetZoomDelayed = useCallback((ms: number) => {
    setTimeout(() => {
      scale.value = withTiming(1, { duration: ANIMATION_DURATION });
      translateX.value = withTiming(0, { duration: ANIMATION_DURATION });
      translateY.value = withTiming(0, { duration: ANIMATION_DURATION });
    }, ms);
  }, [scale, translateX, translateY]);

  // ── 缩放态 pan：拖动 + 贴边溢出（gallery swipe）+ 松手回弹/动量 ──
  const panGesture = usePanGesture({
    // 未放大时手动 fail（交父级 dismiss/阅读），放大后单指才激活
    manualActivation: true,
    minDistance: 0,
    minPointers: 1,
    maxPointers: 1,
    onTouchesMove: (e) => {
      'worklet';
      // 仅缩放态且单指时激活拖动；捏合（双指）期间保持 UNDETERMINED 交给
      // pinch——此前无条件 activate 会让 pan 与 pinch 双写 translate（乱飞，
      // 2026-09-01 用户实测「放大后捏合缩小图片乱飞」）。
      if (scale.value > ZOOMED_THRESHOLD && e.numberOfTouches === 1) {
        GestureStateManager.activate(e.handlerTag);
      } else if (scale.value <= ZOOMED_THRESHOLD) {
        GestureStateManager.fail(e.handlerTag);
      }
    },
    onActivate: (_e) => {
      'worklet';
      savedTranslateX.value = translateX.value;
      savedTranslateY.value = translateY.value;
      zoomGestureLastTime.value = Date.now();
    },
    onUpdate: (e) => {
      'worklet';
      const s = scale.value;
      const maxX = clampHalf(contentW.value, layoutW.value, s);
      const maxY = clampHalf(contentH.value, layoutH.value, s);
      const tx = savedTranslateX.value + e.translationX;
      const ty = savedTranslateY.value + e.translationY;
      // 边界内正常跟手；越界量累计为溢出（仅 enableGallerySwipe 时留存）
      let overX = 0;
      let cx = tx;
      if (maxX > 0) {
        if (tx > maxX) {
          cx = maxX;
          if (enableGallerySwipe) overX = tx - maxX;
        } else if (tx < -maxX) {
          cx = -maxX;
          if (enableGallerySwipe) overX = tx + maxX;
        }
      } else {
        cx = 0;
        if (enableGallerySwipe) overX = tx;
      }
      galleryOverX.value = overX;
      translateX.value = cx;
      const cy = Math.max(-maxY, Math.min(maxY, ty));
      translateY.value = cy;
    },
    onDeactivate: (e) => {
      'worklet';
      const s = scale.value;
      // 未放大态（理论不会激活）兜底：瞬间归位（无动画）
      if (s <= ZOOMED_THRESHOLD) {
        scale.value = 1;
        translateX.value = 0;
        translateY.value = 0;
        return;
      }
      const maxX = clampHalf(contentW.value, layoutW.value, s);
      const maxY = clampHalf(contentH.value, layoutH.value, s);
      // 动量 + 边界 clamp（方向速度与外溢同向时翻页，否则回弹归位）
      const over = galleryOverX.value;
      const overDir = over > GALLERY_BOUNDARY ? 1 : over < -GALLERY_BOUNDARY ? -1 : 0;
      const velDir = Math.abs(e.velocityX) > GALLERY_VELOCITY
        ? e.velocityX > 0 ? 1 : -1
        : 0;
      const swipeDir = overDir !== 0 ? overDir : velDir;
      if (enableGallerySwipe && swipeDir !== 0) {
        const next = currentIndex + swipeDir;
        if (next < 0 || next >= pageCount) {
          // 边界页（首/末）：无页可翻 → 走普通回弹并**保持放大**
          //（2026-09-01 修复：此前无条件复位，拖到边缘图片缩回 1）
        } else {
          // 速度单条件判定（位移或速度任一成立即翻页）；仅真翻页才延迟复位
          runOnJS(jumpToPage)(swipeDir);
          runOnJS(resetZoomDelayed)(RESET_DELAY);
          return;
        }
      }
      // 普通松手：水平动量（边界内衰减），垂直直接回弹
      if (maxX > 0 && Math.abs(e.velocityX) > 300) {
        translateX.value = withDecay({
          velocity: e.velocityX,
          clamp: [-maxX, maxX],
          deceleration: MOMENTUM_DECELERATION,
        });
      } else {
        translateX.value = withSpring(
          Math.max(-maxX, Math.min(maxX, translateX.value)),
          SPRING_CONFIG,
        );
      }
      translateY.value = withSpring(
        Math.max(-maxY, Math.min(maxY, translateY.value)),
        SPRING_CONFIG,
      );
      zoomGestureLastTime.value = Date.now();
    },
  });

  // worklet 内直接以 runOnJS(fn)(args) 官方形态调用（2026-09-01 修复：
// 此前把 runOnJS(fn) 结果存 const 再在 worklet 里间接调用，worklet 序列化
// 会丢失该包装（变成 undefined），手势回调一执行即抛 TypeError）。

  // ── 双击缩放：围绕点击点，两段同步动画（scale + translate）──
  const doubleTapGesture = useTapGesture({
    numberOfTaps: 2,
    maxDeltaX: TAP_MAX_DELTA,
    maxDeltaY: TAP_MAX_DELTA,
    onDeactivate: (e) => {
      'worklet';
      if (e.canceled) return;
      const s1 = scale.value;
      const target =
        s1 > ZOOMED_THRESHOLD
          ? doubleTapConfig?.minZoomScale ?? 1
          : doubleTapConfig?.defaultScale ?? DOUBLE_TAP_SCALE;
      if (target === s1) return;
      const cx = layoutW.value / 2;
      const cy = layoutH.value / 2;
      // 保持点击点不动：t2 = t1 + (tap − center) × (s1 − s2)
      let t2x = translateX.value + (e.x - cx) * (s1 - target);
      let t2y = translateY.value + (e.y - cy) * (s1 - target);
      // 目标态边界预钳（缩放动画结束时内容不露白）
      const maxX = clampHalf(contentW.value, layoutW.value, target);
      const maxY = clampHalf(contentH.value, layoutH.value, target);
      t2x = Math.max(-maxX, Math.min(maxX, t2x));
      t2y = Math.max(-maxY, Math.min(maxY, t2y));
      scale.value = withTiming(target, { duration: ANIMATION_DURATION });
      translateX.value = withTiming(t2x, { duration: ANIMATION_DURATION });
      translateY.value = withTiming(t2y, { duration: ANIMATION_DURATION });
      zoomGestureLastTime.value = Date.now();
    },
  });

  const zoomGesture = useSimultaneousGestures(doubleTapGesture, panGesture, pinchGesture);

  const contentContainerAnimatedStyle = useAnimatedStyle(() => ({
    transform: [
      { translateX: translateX.value },
      { translateY: translateY.value },
      { scale: scale.value },
    ],
  }));

  /** JS 侧回调：换图/换页时复位（useEffect 依赖 URI 调用，见 parts.tsx） */
  const zoomOut = useCallback(() => {
    scale.value = withTiming(1, { duration: ANIMATION_DURATION });
    translateX.value = withTiming(0, { duration: ANIMATION_DURATION });
    translateY.value = withTiming(0, { duration: ANIMATION_DURATION });
  }, [scale, translateX, translateY]);

  const onLayout = useCallback((e: LayoutChangeEvent) => {
    layoutW.value = e.nativeEvent.layout.width;
    layoutH.value = e.nativeEvent.layout.height;
  }, [layoutW, layoutH]);

  const onLayoutContent = useCallback((e: LayoutChangeEvent) => {
    contentW.value = e.nativeEvent.layout.width;
    contentH.value = e.nativeEvent.layout.height;
  }, [contentW, contentH]);

  return {
    zoomGesture,
    contentContainerAnimatedStyle,
    onLayout,
    onLayoutContent,
    isZoomedIn,
    zoomGestureLastTime,
    scale,
    zoomOut,
  };
}