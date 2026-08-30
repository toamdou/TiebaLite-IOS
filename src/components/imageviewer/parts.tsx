/**
 * ImageViewer 可拆部件（从 components/ImageViewer.tsx 拆出）：
 * - buildPageWindow：窗口化分页计算
 * - ZoomableImage：单页大图（捏合/双击/平移手势 + active 解码策略）
 * - ThumbnailCell：底部缩略图格（enabled 闸控原生缩略图拉取）
 *
 * 时序敏感块（TEARDOWN_GRACE_MS / 状态栏隐藏恢复）仍在
 * ImageViewer.tsx 主组件内，勿迁。
 */

import { memo, useCallback, useEffect, useMemo, useState } from 'react';
import { View, Pressable, StyleSheet, Dimensions, type StyleProp, type ViewStyle } from 'react-native';
import Animated, {
  useAnimatedStyle,
  useAnimatedReaction,
  runOnJS,
} from 'react-native-reanimated';
import { Gesture, GestureDetector, type GestureType } from 'react-native-gesture-handler';
import type { SharedValue } from 'react-native-reanimated';
import { useZoomGesture, type ScrollableRef } from 'react-native-zoom-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Image } from 'expo-image';

import { hapticForScene } from '@/theme/hapticsMap';
import { useNativeThumbnail } from '@/hooks/useNativeThumbnail';
import { thumbnailUrl, THUMB_LIST } from '@/utils/thumbnail';
import { isImageWarm, markImageWarm } from '@/utils/imageWarm';

// 与主组件同款固定窗口尺寸（竖屏取一次；旋转后页面 flex 撑开，钳制按
// 竖屏数值计算——见主文件 teardown 注释，不做 useWindowDimensions）。
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

export const ZoomableImage = memo(function ZoomableImage({
  uri,
  onSingleTap,
  onZoomChange,
  active,
  onLoadStart,
  onLoadEnd,
  gallerySwipe,
  galleryScrollRef,
  galleryIndex,
  galleryItemWidth,
}: {
  uri: string;
  onSingleTap: () => void;
  onZoomChange?: (zoomed: boolean) => void;
  active: boolean;
  /** 大图 uri 开始加载（原图切换时外层显示圆形 loading） */
  onLoadStart?: () => void;
  onLoadEnd?: () => void;
  /** 照片级图库滑动：放大态拖到边缘溢出时切页（react-native-zoom-reanimated） */
  gallerySwipe: boolean;
  galleryScrollRef: React.RefObject<ScrollableRef>;
  galleryIndex: number;
  galleryItemWidth: number;
}) {
  // ── 缩放核心 = react-native-zoom-reanimated（2026-08-30 替换手写实现）──
  // focal 捏合（rubber band + 动态焦点）、双击缩放、pan（带边界回弹/动量）、
  // 照片级图库滑动（放大态溢出边缘切页）全部由库内部维护；我们保留：
  // - 单击 chrome 开关（与 noop 双击 Exclusive 互斥，双击不误触）
  // - zoomed 镜像（scale>1.01 → onZoomChange，父级 dismiss/pager 门控不变）
  // - 换图/换页重置（zoomOut）
  // 未放大态库的 pan 直接 fail → 父级拖拽关闭/长图阅读 pan 完全不变。
  const {
    zoomGesture,
    contentContainerAnimatedStyle,
    onLayout,
    onLayoutContent,
    scale,
    zoomOut,
  } = useZoomGesture({
    minScale: 1,
    maxScale: 5,
    enableGallerySwipe: gallerySwipe,
    parentScrollRef: galleryScrollRef,
    currentIndex: galleryIndex,
    itemWidth: galleryItemWidth,
    doubleTapConfig: { defaultScale: 3, minZoomScale: 1, maxZoomScale: 5 },
  });

  // Notify the parent only when the zoomed threshold changes, not per frame.
  // 阈值 1.01（与旧实现一致）：轻微捏合（如 1.03）保持放大不弹回。
  useAnimatedReaction(
    () => scale.value > 1.01,
    (zoomed, previous) => {
      if (zoomed !== previous) {
        runOnJS(onZoomChange ?? (() => {}))(zoomed);
      }
    },
  );

  // 换图/换页重置（库的 zoomOut：弹簧回到初始）。active 切换即重置，
  // 与旧 resetTransform 语义一致。
  useEffect(() => {
    zoomOut();
  }, [uri, active, zoomOut]);

  // 单击 chrome 开关 + 双击触感：与库双击（负责缩放）并存。noop 双击只
  // 参与 Exclusive 协调（保证双击时单击不误触）并在成功时补触感——
  // 库的双击不带动效触感，这里补回旧实现的手感。
  const tapCombo = useMemo(
    () =>
      Gesture.Exclusive(
        Gesture.Tap()
          .numberOfTaps(2)
          .onEnd((_e, success) => {
            'worklet';
            if (success) runOnJS(hapticForScene)('toggle');
          }),
        Gesture.Tap()
          .numberOfTaps(1)
          .onEnd((_e, success) => {
            'worklet';
            if (success) runOnJS(onSingleTap)();
          }),
      ),
    [onSingleTap],
  );

  const composedGesture = useMemo(
    () => Gesture.Simultaneous(zoomGesture, tapCombo),
    [zoomGesture, tapCombo],
  );

  // 内存策略：仅当前页（active）解码原图（高优先级、带磁盘缓存上限），
  // 非激活页只放一张 360px 服务端缩略图，滑到跟前再换原图——避免整条
  // 图片横向滑动把全部原图塞进内存。
  const thumbUri = thumbnailUrl(uri, THUMB_LIST);

  return (
    <GestureDetector gesture={composedGesture}>
      <View style={partStyles.zoomContainer} onLayout={onLayout} collapsable={false}>
        <Animated.View
          style={contentContainerAnimatedStyle as unknown as StyleProp<ViewStyle>}
          onLayout={onLayoutContent}
          collapsable={false}
        >
          {active ? (
            <Image
              source={{ uri }}
              style={partStyles.fullImage}
              contentFit="contain"
              preferHighDynamicRange
              transition={isImageWarm(uri) ? 0 : 200}
              cachePolicy="memory-disk"
              priority="high"
              recyclingKey={uri}
              onLoad={() => markImageWarm(uri)}
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
      </View>
    </GestureDetector>
  );
});

// ---------- LongImageView（长图阅读模式，2026-08-29）----------

/**
 * 长图页（fit-width 阅读模式，用户规格 2026-08-29）：
 * 1. 进入即显示小档（srcPic，秒出、完整长图）+ 同步加载动画；
 * 2. 原图（originSrc）后台加载，onLoadEnd 后淡入替换——此时才显示原图；
 * 3. 原图自动匹配屏宽（宽=屏宽、高按比例），单指下滑即可读完；
 * 4. 捏合/双击缩放，放大后 pan 移动（与普通页同一手势模型）。
 *
 * 修复的冻结根因：此前长图默认直接解码 originSrc 巨图（可达数百 MB、
 * 高度超 GPU 纹理上限），主线程上屏即整机卡死。
 */
export const LongImageView = memo(function LongImageView({
  baseUri,
  originUri,
  imageWidth,
  imageHeight,
  onSingleTap,
  onZoomChange,
  onLoadStart,
  onLoadEnd,
  readPan,
  scrollY,
  scrollMax,
  gallerySwipe,
  galleryScrollRef,
  galleryIndex,
  galleryItemWidth,
}: {
  baseUri: string;
  originUri?: string;
  /** 原图自然尺寸（px）：fit 高度 = 屏宽 × (h/w) */
  imageWidth?: number;
  imageHeight?: number;
  onSingleTap: () => void;
  onZoomChange?: (zoomed: boolean) => void;
  onLoadStart?: () => void;
  onLoadEnd?: () => void;
  /** 阅读滚动 pan（父级创建：与退出手势同流，未缩放时驱动长图上下阅读） */
  readPan: GestureType;
  /** 滚动偏移 / 最大可滚量（UI 线程共享值；offset 由 readPan 写入） */
  scrollY: SharedValue<number>;
  scrollMax: SharedValue<number>;
  /** 照片级图库滑动（同 ZoomableImage 契约） */
  gallerySwipe: boolean;
  galleryScrollRef: React.RefObject<ScrollableRef>;
  galleryIndex: number;
  galleryItemWidth: number;
}) {
  // 原图按屏宽适配的显示高度（pt）；无尺寸信息回退屏高（退化为普通页行为）
  const fitHeight =
    imageWidth && imageWidth > 0 && imageHeight && imageHeight > 0
      ? Math.round((PART_SCREEN_WIDTH * imageHeight) / imageWidth)
      : PART_SCREEN_HEIGHT;
  // ── 缩放核心 = react-native-zoom-reanimated（与 ZoomableImage 同一套）──
  // 长图场景：未放大时库 pan 判 fail → 阅读由父级 readPan 驱动（本组件
  // 不参与）；放大后库 pan 按"内容高 × scale − 屏高"自动边界（含回弹/
  // 动量），既有长图阅读/退出手势契约不变。
  const {
    zoomGesture,
    contentContainerAnimatedStyle,
    onLayout,
    onLayoutContent,
    scale,
    zoomOut,
  } = useZoomGesture({
    minScale: 1,
    maxScale: 5,
    enableGallerySwipe: gallerySwipe,
    parentScrollRef: galleryScrollRef,
    currentIndex: galleryIndex,
    itemWidth: galleryItemWidth,
    doubleTapConfig: { defaultScale: 3, minZoomScale: 1, maxZoomScale: 5 },
  });
  // 原图（originUri）解码完成 → 淡入替换缩略图
  const [originReady, setOriginReady] = useState(false);
  const [originFailed, setOriginFailed] = useState(false);

  useEffect(() => {
    // 行复用/换图重置
    setOriginReady(false);
    setOriginFailed(false);
  }, [baseUri, originUri]);

  // 换图/换页重置缩放（同 ZoomableImage）
  useEffect(() => {
    zoomOut();
  }, [baseUri, originUri, zoomOut]);

  // zoomed 镜像 → 父级 dismiss/pager 门控（阈值 1.01，与旧实现一致）
  useAnimatedReaction(
    () => scale.value > 1.01,
    (z, previous) => {
      if (z !== previous) {
        runOnJS(onZoomChange ?? (() => {}))(z);
      }
    },
  );

  // 单击 chrome 开关 + 双击触感（同 ZoomableImage；库双击负责缩放）
  const tapCombo = useMemo(
    () =>
      Gesture.Exclusive(
        Gesture.Tap()
          .numberOfTaps(2)
          .onEnd((_e, success) => {
            'worklet';
            if (success) runOnJS(hapticForScene)('toggle');
          }),
        Gesture.Tap()
          .numberOfTaps(1)
          .onEnd((_e, success) => {
            'worklet';
            if (success) runOnJS(onSingleTap)();
          }),
      ),
    [onSingleTap],
  );

  const composedGesture = useMemo(
    () => Gesture.Simultaneous(zoomGesture, tapCombo),
    [zoomGesture, tapCombo],
  );

  const handleOriginLoadEnd = useCallback(() => {
    setOriginReady(true);
    onLoadEnd?.();
  }, [onLoadEnd]);
  const insets = useSafeAreaInsets();

  // 阅读滚动偏移 → 共享值（UI 线程：readPan 直接写入，父级退出手势同帧读取）。
  // 内容顶部让出灵动岛/状态栏安全区（2026-08-29 用户要求：大图不被岛遮挡），
  // 最大可滚量 = 内容高（含顶部安全区）− 屏高。
  const scrollerStyle = useAnimatedStyle(() => ({
    transform: [{ translateY: scrollY.value }],
  }));

  useEffect(() => {
    scrollMax.value = Math.max(fitHeight + insets.top - PART_SCREEN_HEIGHT, 0);
  }, [fitHeight, insets.top, scrollMax]);

  return (
    <View
      style={{ width: PART_SCREEN_WIDTH, height: PART_SCREEN_HEIGHT }}
      onLayout={onLayout}
      collapsable={false}
    >
      <GestureDetector gesture={composedGesture}>
        {/* 库的缩放容器（transform 全在 contentContainerAnimatedStyle）：
            内容 = 阅读层（readPan + scroller）整体参与缩放/pan */}
        <Animated.View
          style={[
            { width: PART_SCREEN_WIDTH, height: Math.max(fitHeight + insets.top, PART_SCREEN_HEIGHT) },
            contentContainerAnimatedStyle as unknown as StyleProp<ViewStyle>,
          ]}
          onLayout={onLayoutContent}
          collapsable={false}
        >
          {/* 阅读滚动由父级 readPan 驱动（RNGH-RNGH 同流，与退出手势按边界仲裁；
              不再套原生 ScrollView——UIKit 滚动会抢先吃掉触摸导致边界退出失效） */}
          <GestureDetector gesture={readPan}>
            <Animated.View style={[scrollerStyle, { width: PART_SCREEN_WIDTH, height: Math.max(fitHeight + insets.top, 1) }]}>
              {/* 内容整体下移安全区顶（首屏不顶到灵动岛/状态栏） */}
              <View style={{ marginTop: insets.top, width: PART_SCREEN_WIDTH, height: Math.max(fitHeight, 1) }}>
{/* 缩略层：小档秒出，完整长图（低清）即可读 */}
            <Image
              source={{ uri: baseUri }}
              style={partStyles.absoluteFillImage}
              contentFit="cover"
              cachePolicy="memory-disk"
              transition={0}
              onLoad={() => markImageWarm(baseUri)}
              recyclingKey={`long-base-${baseUri}`}
            />
            {/* 原图层：后台解码完成后淡入替换；加载期间缩略层照常显示 */}
            {originUri && !originFailed ? (
              <Image
                source={{ uri: originUri }}
                style={[partStyles.absoluteFillImage, { opacity: originReady ? 1 : 0 }]}
                contentFit="cover"
                cachePolicy="memory-disk"
                transition={isImageWarm(originUri) ? 0 : 150}
                priority="high"
                recyclingKey={`long-origin-${originUri}`}
                onLoadStart={onLoadStart}
                onLoad={() => {
                  markImageWarm(originUri);
                  handleOriginLoadEnd();
                }}
                onError={() => setOriginFailed(true)}
              />
            ) : null}
            </View>
          </Animated.View>
        </GestureDetector>
      </Animated.View>
    </GestureDetector>
    </View>
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
  absoluteFillImage: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    width: '100%',
    height: '100%',
  },
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
