/**
 * ImageViewer 可拆部件（从 components/ImageViewer.tsx 拆出）：
 * - buildPageWindow：窗口化分页计算
 * - ZoomableImage：单页大图（捏合/双击/平移手势 + active 解码策略）
 * - ThumbnailCell：底部缩略图格（enabled 闸控原生缩略图拉取）
 *
 * 时序敏感块（staticMode / TEARDOWN_GRACE_MS / 状态栏隐藏恢复）仍在
 * ImageViewer.tsx 主组件内，勿迁。
 */

import { memo, useCallback, useEffect, useMemo } from 'react';
import { View, Pressable, StyleSheet, Dimensions } from 'react-native';
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  useAnimatedReaction,
  withSpring,
  runOnJS,
} from 'react-native-reanimated';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import { Image } from 'expo-image';

import { hapticForScene } from '@/theme/hapticsMap';
import { useNativeThumbnail } from '@/hooks/useNativeThumbnail';
import { thumbnailUrl, THUMB_LIST } from '@/utils/thumbnail';
import { MOMENTUM } from '@/theme/springs';

// 与主组件同款固定窗口尺寸（竖屏取一次；旋转后页面 flex 撑开，钳制按
// 竖屏数值计算——见主文件 staticMode/teardown 注释，不做 useWindowDimensions）。
const { width: PART_SCREEN_WIDTH, height: PART_SCREEN_HEIGHT } = Dimensions.get('window');

/**
 * 窗口化：默认最多挂载 3 页（当前 ±1），仅"当前页"解码原图（active），
 * 邻近页只放 360px 服务端缩略图，滑到跟前再换原图——避免整条横滑
 * 把全部原图塞进内存。低功耗模式下 windowSize 降到 2（仅当前 ±1 的
 * 一侧），进一步节省电量与内存；不能降到 1，否则无法左右翻页。
 */
export function buildPageWindow(images: string[], current: number, windowSize = 3) {
  const count = images.length;
  const radius = Math.max(0, Math.floor((windowSize - 1) / 2));
  const start = Math.max(0, Math.min(current - radius, count - windowSize));
  const end = Math.min(count, start + windowSize);
  const pages = images.slice(start, end).map((uri, i) => ({
    uri,
    index: start + i,
    active: start + i === current,
  }));
  return {
    pages,
    start,
    anchor: Math.min(Math.max(current - start, 0), Math.max(pages.length - 1, 0)),
  };
}

// ---------- ZoomableImage ----------

/** 捏合手势取证（DEV only，worklet 经 runOnJS 回调）：
    用户反馈「缩放手势用不了/松开恢复原大小」时，此日志可区分
    手势未触发（无 start 行）vs 触发但逻辑复位（end scale 值）。 */
function __pinchLog(phase: 'start' | 'end', scale: number): void {
  if (__DEV__) console.warn(`[viewer] pinch ${phase} scale=${scale.toFixed(3)}`);
}

export const ZoomableImage = memo(function ZoomableImage({
  uri,
  onSingleTap,
  onZoomChange,
  active,
  zoomed,
  onLoadStart,
  onLoadEnd,
}: {
  uri: string;
  onSingleTap: () => void;
  onZoomChange?: (zoomed: boolean) => void;
  active: boolean;
  /** 父级缩放态（Pinch/双击后为 true）。作为 prop 传入而非内部闭包：
      ZoomableImage 是 memo 的，父组件 setState 不会让子重渲染，
      若 pan.enabled 读取内部缓存值会永远停在 false——放大后无法拖动。 */
  zoomed: boolean;
  /** 大图 uri 开始加载（原图切换时外层显示圆形 loading） */
  onLoadStart?: () => void;
  onLoadEnd?: () => void;
}) {
  const scale = useSharedValue(1);
  const baseScale = useSharedValue(1);
  const translateX = useSharedValue(0);
  const translateY = useSharedValue(0);
  const startTranslateX = useSharedValue(0);
  const startTranslateY = useSharedValue(0);

  const resetTransform = useCallback(() => {
    scale.value = 1;
    baseScale.value = 1;
    translateX.value = 0;
    translateY.value = 0;
  }, [scale, baseScale, translateX, translateY]);

  useEffect(() => {
    resetTransform();
  }, [uri, active, resetTransform]);

  // Notify the parent only when the zoomed threshold changes, not per frame.
  // 阈值 1.01：旧值 1.05 导致轻微捏合（如 1.03）松手即弹回原尺寸——用户
  // 要求"稍微拉伸也应保持放大"（2026-08-27 真机反馈）。
  useAnimatedReaction(
    () => scale.value > 1.01,
    (zoomed, previous) => {
      if (zoomed !== previous) {
        runOnJS(onZoomChange ?? (() => {}))(zoomed);
      }
    },
  );

  const toggleZoom = useCallback(() => {
    const target = scale.value > 1.01 ? 1 : 3;
    scale.value = withSpring(target, MOMENTUM);
    baseScale.value = target;
    translateX.value = withSpring(0, MOMENTUM);
    translateY.value = withSpring(0, MOMENTUM);
    hapticForScene('toggle');
  }, [scale, baseScale, translateX, translateY]);

  const animatedStyle = useAnimatedStyle(() => ({
    transform: [
      { translateX: translateX.value },
      { translateY: translateY.value },
      { scale: scale.value },
    ],
  }));

  // 手势用 useMemo 包裹（Expo 动画食谱 G1）：避免每次渲染重建入口导致识别器
  // 重挂、丢掉进行中的捏合/拖拽。依赖只含 props 与共享值引用（均为稳定 ref）。
  const pinch = useMemo(
    () =>
      Gesture.Pinch()
        .onStart(() => {
          'worklet';
          if (__DEV__) runOnJS(__pinchLog)('start', 0);
        })
        .onUpdate((e) => {
          scale.value = Math.min(5, Math.max(1, baseScale.value * e.scale));
        })
        .onEnd(() => {
          if (__DEV__) runOnJS(__pinchLog)('end', scale.value);
          baseScale.value = scale.value;
          // 只有完全归位（≈1）才弹簧复位；任何 >1 的捏合结果松手即保持
          // （2026-08-28：旧阈值 1.01 本意是给 1.03 之类轻微捏合留保持余量，
          // 但 onUpdate 已被 clamp 到 ≥1，松手读到的值只可能 ≥1）
          if (scale.value <= 1.001) {
            scale.value = withSpring(1, MOMENTUM);
            baseScale.value = 1;
            translateX.value = withSpring(0, MOMENTUM);
            translateY.value = withSpring(0, MOMENTUM);
          }
        }),
    [scale, baseScale, translateX, translateY],
  );

  const pan = useMemo(
    () =>
      Gesture.Pan()
        .enabled(zoomed)
        .onStart(() => {
          startTranslateX.value = translateX.value;
          startTranslateY.value = translateY.value;
        })
        .onUpdate((e) => {
          const maxX = Math.max(0, (PART_SCREEN_WIDTH * scale.value - PART_SCREEN_WIDTH) / 2);
          const maxY = Math.max(0, (PART_SCREEN_HEIGHT * scale.value - PART_SCREEN_HEIGHT) / 2);
          translateX.value = Math.min(
            maxX,
            Math.max(-maxX, startTranslateX.value + e.translationX),
          );
          translateY.value = Math.min(
            maxY,
            Math.max(-maxY, startTranslateY.value + e.translationY),
          );
        })
        .onEnd(() => {
          startTranslateX.value = translateX.value;
          startTranslateY.value = translateY.value;
        }),
    [zoomed, scale, startTranslateX, startTranslateY, translateX, translateY],
  );

  const doubleTap = useMemo(
    () =>
      Gesture.Tap()
        .numberOfTaps(2)
        .onEnd((_e, success) => {
          if (success) {
            runOnJS(toggleZoom)();
          }
        }),
    [toggleZoom],
  );

  const singleTap = useMemo(
    () =>
      Gesture.Tap()
        .numberOfTaps(1)
        .onEnd((_e, success) => {
          if (success) {
            runOnJS(onSingleTap)();
          }
        }),
    [onSingleTap],
  );

  const composedGesture = useMemo(
    () => Gesture.Simultaneous(pinch, pan, Gesture.Exclusive(doubleTap, singleTap)),
    [pinch, pan, doubleTap, singleTap],
  );

  // 内存策略：仅当前页（active）解码原图（高优先级、带磁盘缓存上限），
  // 非激活页只放一张 360px 服务端缩略图，滑到跟前再换原图——避免整条
  // 图片横向滑动把全部原图塞进内存。
  const thumbUri = thumbnailUrl(uri, THUMB_LIST);

  return (
    <GestureDetector gesture={composedGesture}>
      <Animated.View style={[partStyles.zoomContainer, animatedStyle]}>
        {active ? (
          <Image
            source={{ uri }}
            style={partStyles.fullImage}
            contentFit="contain"
            preferHighDynamicRange
            transition={200}
            cachePolicy="memory-disk"
            priority="high"
            recyclingKey={uri}
            onLoadStart={onLoadStart}
            onLoadEnd={onLoadEnd}
          />
        ) : (
          <Image
            source={{ uri: thumbUri }}
            style={partStyles.fullImage}
            contentFit="contain"
            transition={120}
            cachePolicy="memory-disk"
            recyclingKey={thumbUri}
          />
        )}
      </Animated.View>
    </GestureDetector>
  );
});

// ---------- Native Thumbnail Cell ----------

export const ThumbnailCell = memo(function ThumbnailCell({
  uri,
  index,
  currentIndex,
  active,
  onPress,
}: {
  uri: string;
  index: number;
  currentIndex: number;
  active: boolean;
  onPress: (index: number) => void;
}) {
  // enabled=active：仅当前±1 格才发起原生缩略图下载/解码（窗口化与主
  // PagerView 同策略）；非激活格显示占位 View，翻页激活后 hook 补拉。
  const thumbnailUri = useNativeThumbnail(uri, 56, 56, active);
  return (
    <Pressable
      onPress={() => onPress(index)}
      style={[
        partStyles.thumbnailWrapper,
        { borderColor: index === currentIndex ? '#FFFFFF' : 'transparent' },
      ]}
      accessibilityRole="button"
      accessibilityLabel={`第${index + 1}张图片`}
    >
      {active && thumbnailUri ? (
        <Image
          source={{ uri: thumbnailUri }}
          style={partStyles.thumbnail}
          contentFit="cover"
          cachePolicy="memory-disk"
        />
      ) : (
        <View style={[partStyles.thumbnail, partStyles.thumbnailPlaceholder]} />
      )}
    </Pressable>
  );
});

const partStyles = StyleSheet.create({
  zoomContainer: {
    width: PART_SCREEN_WIDTH,
    height: PART_SCREEN_HEIGHT,
  },
  fullImage: {
    width: PART_SCREEN_WIDTH,
    height: PART_SCREEN_HEIGHT,
  },
  thumbnailWrapper: {
    width: 56,
    height: 56,
    borderRadius: 6,
    borderCurve: 'continuous',
    borderWidth: 2,
    overflow: 'hidden',
  },
  thumbnail: {
    width: '100%',
    height: '100%',
  },
  thumbnailPlaceholder: {
    backgroundColor: 'rgba(255,255,255,0.08)',
  },
});
