/**
 * ImageViewer 可拆部件（从 components/ImageViewer.tsx 拆出）：
 * - ZoomableImage：单页大图（捏合/双击/平移手势 + active 解码策略）
 * - ThumbnailCell：底部缩略图格（原生缩略图全量拉取）
 *
 * 时序敏感块（TEARDOWN_GRACE_MS / 状态栏隐藏恢复）仍在
 * ImageViewer.tsx 主组件内，勿迁。
 * 2026-08-31：窗口化（buildPageWindow）已整体移除——PagerView 全量挂载，
 * 视觉外页零解码（active 门控），不再有窗口重建与原生滑动的竞争。
 */

import { memo, useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { View, Pressable, StyleSheet, Dimensions, type StyleProp, type ViewStyle } from 'react-native';
import Animated, {
  useSharedValue,
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
import { isImageWarm, markImageWarm } from '@/utils/imageWarm';

// 与主组件同款固定窗口尺寸（竖屏取一次；旋转后页面 flex 撑开，钳制按
// 竖屏数值计算——见主文件 teardown 注释，不做 useWindowDimensions）。
const { width: PART_SCREEN_WIDTH, height: PART_SCREEN_HEIGHT } = Dimensions.get('window');

// ---------- ZoomableImage ----------

export const ZoomableImage = memo(function ZoomableImage({
  uri,
  previewUri,
  onSingleTap,
  onZoomChange,
  active,
  onLoadStart,
  onLoadEnd,
  gallerySwipe,
  galleryScrollRef,
  galleryIndex,
  galleryItemWidth,
  zoomMirror,
  gesturePulse,
}: {
  uri: string;
  /** 小档预览 URL（列表同款 srcPic）：大图下载/解码期间垫底秒显，避免翻页黑屏。
      与 uri 相同（省流档/无小档回落）时不渲染重复层。 */
  previewUri?: string;
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
  /** 缩放态镜像（父级持值，UI 线程直读）：本页 active 时把 isZoomedIn 写入 */
  zoomMirror: SharedValue<boolean>;
  /** 手势脉冲（父级持值）：本页 active 时 gesture 触发 +1 → 父级排 UI 自动收起 */
  gesturePulse: SharedValue<number>;
}) {
  // ── 缩放核心 = react-native-zoom-reanimated（2026-08-30 替换手写实现）──
  // focal 捏合（rubber band + 动态焦点）、双击缩放、pan（带边界回弹/动量）、
  // 放大态边缘滑图（enableGallerySwipe：放大后左右滑动不恢复缩放直接切图，
  // 用户指定保留）全部由库内部维护。我们保留：
  // - 单击 chrome 开关（与 noop 双击 Exclusive 互斥，双击不误触）
  // - zoomed 镜像：scale>1.01 → onZoomChange（JS：pager 门控/UI 态），
  //   以及 isZoomedIn → zoomMirror（UI 线程：退出手势门控，零往返）
  // - 换图重置（zoomOut，仅 uri 变化触发）
  // 未放大态库的 pan 直接 fail → 父级拖拽关闭/长图阅读 pan 完全不变。
  const {
    zoomGesture,
    contentContainerAnimatedStyle,
    onLayout,
    onLayoutContent,
    isZoomedIn,
    zoomGestureLastTime,
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

  // 镜像门控：仅本页 active 时写入父级共享值（防翻页后残留页再次写回）。
  // 换页瞬间值对齐靠 active effect（JS 侧快照），手势期间全程 UI 线程。
  const activeSV = useSharedValue(active);
  useEffect(() => {
    activeSV.value = active;
    if (active) {
      // 翻页返回曾缩放的页：复位缩放（iOS Photos——缩放不跨页保持）。
      // isZoomedIn 门控保证只有真放大过的页触发，未缩放页零成本
      // （不会重演 fc315b8 修掉的「active 翻转→整窗三页并发 zoomOut」）。
      if (isZoomedIn.value) zoomOut();
      zoomMirror.value = isZoomedIn.value;
    }
  }, [active, activeSV, zoomMirror, isZoomedIn, zoomOut]);
  useAnimatedReaction(
    () => isZoomedIn.value,
    (z) => {
      if (activeSV.value) zoomMirror.value = z;
    },
  );
  useAnimatedReaction(
    () => zoomGestureLastTime.value,
    (t, prev) => {
      if (activeSV.value && t !== prev) {
        gesturePulse.value = gesturePulse.value + 1;
      }
    },
  );

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
  // ⚠️ 取证（2026-08-30）：scale 从放大态突降到 1（「滑到边缘自动恢复原大小」
  // 的复位瞬间）——记录突变轨迹与时间，定位库内部触发者
  useAnimatedReaction(
    () => scale.value,
    (s, prev) => {
      if ((prev ?? 1) > 1.05 && s <= 1.02) {
        runOnJS(console.warn)(
          '[viewer-dbg]',
          new Date().toISOString().slice(11, 23),
          'scale-drop',
          { s: Math.round(s * 100) / 100, prev: Math.round((prev ?? 1) * 100) / 100 },
        );
      }
    },
  );

  // 换图重置（库的 zoomOut：弹簧回到初始）。**只依赖 uri**——曾依赖
  // active/zoomOut：缩放状态翻转 → 父级重渲染 → 引用抖动 → 整窗三页并发
  // zoomOut() → 放大态 scale 被不断打回 1（用户实测「滑到边缘图片回归
  // 正常大小」，2026-08-30 日志 zoom-reset 三连发实证）。翻页换图 uri
  // 必变，active 语义由 uri 覆盖。
  useEffect(() => {
    if (__DEV__) {
      console.warn(
        '[viewer-dbg]',
        new Date().toISOString().slice(11, 23),
        'zoom-reset',
        { uri: uri?.slice(-24) },
      );
    }
    zoomOut();
  }, [uri]);

  // 加载失败自动重试（2026-08-31 连续滑动黑屏保底）：视图层请求可能随
  // PagerView 页卸载被取消/静默失败，重试走 prefetch 独立通道 + 换
  // recyclingKey 强制视图重新发起。最多 2 次，避免死循环。
  const [loadRetry, setLoadRetry] = useState(0);
  const loadRetryRef = useRef(0);
  const handleLoadError = useCallback(() => {
    if (loadRetryRef.current >= 2) return;
    loadRetryRef.current += 1;
    void Image.prefetch(uri);
    setTimeout(() => setLoadRetry((n) => n + 1), 600);
  }, [uri]);

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

  // 内存策略（2026-08-30 改真·按需）：仅当前页（active）解码图片。贴吧
  // CDN 尺寸注入已停用（thumbnailUrl 只做 ATS 协议升级），旧「非激活页放
  // 360px 缩略图」实际渲染的是同一原 URL = 窗口内三页全部预解码，与
  // 「每次只加载一个」冲突。现在非激活页空占位零解码；翻页激活时同 URL
  // 内存缓存命中即时出图（同会话看过即秒显），首次看图按需解码一次。

  return (
    <GestureDetector gesture={composedGesture}>
      <View style={partStyles.zoomContainer} onLayout={onLayout} collapsable={false}>
        <Animated.View
          style={contentContainerAnimatedStyle as unknown as StyleProp<ViewStyle>}
          onLayout={onLayoutContent}
          collapsable={false}
        >
          {active ? (
            <View style={partStyles.fullImage} collapsable={false}>
              {/* 小档垫底：列表缓存必命中秒显（大图 URL 与列表不同档，缓存在
                  查看器首次打开时 miss——这是「翻页黑屏」根因）。大图 onLoad
                  后盖住垫底，淡入由上层 transition 承担。GIF 原档/省流档
                  （uri===previewUri）不重复解码。 */}
              {previewUri && previewUri !== uri ? (
                <Image
                  source={{ uri: previewUri }}
                  style={partStyles.absoluteFillImage}
                  contentFit="contain"
                  transition={0}
                  cachePolicy="memory-disk"
                  priority="high"
                  recyclingKey={`viewer-preview-${previewUri}`}
                />
              ) : null}
              <Image
                source={{ uri }}
                style={partStyles.fullImage}
                contentFit="contain"
                preferHighDynamicRange
                transition={
                  isImageWarm(uri)
                    ? 0
                    : { duration: 200, timing: 'ease-out' } // iOS 系淡入是 ease-out（2026-08-31 审查）
                }
                cachePolicy="memory-disk"
                priority="high"
                recyclingKey={`${loadRetry}-${uri}`}
                onLoadStart={() => {
                  if (__DEV__) {
                    console.warn(
                      '[viewer-dbg]',
                      new Date().toISOString().slice(11, 23),
                      'img-start',
                      uri.slice(-24),
                    );
                  }
                  onLoadStart?.();
                }}
                onLoad={() => {
                  if (__DEV__) {
                    console.warn(
                      '[viewer-dbg]',
                      new Date().toISOString().slice(11, 23),
                      'img-ok',
                      uri.slice(-24),
                    );
                  }
                  markImageWarm(uri);
                  onLoadEnd?.();
                }}
                onError={() => {
                  if (__DEV__) {
                    console.warn(
                      '[viewer-dbg]',
                      new Date().toISOString().slice(11, 23),
                      'img-err',
                      uri.slice(-24),
                      { retry: loadRetryRef.current },
                    );
                  }
                  handleLoadError();
                }}
              />
            </View>
          ) : (
            <View style={partStyles.fullImage} />
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
 * 2. 原图（originSrc）后台加载，解码完成经 transition 在底图上淡入；
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
  active,
  onLoadStart,
  onLoadEnd,
  readPan,
  scrollIndex,
  onScrollAttach,
  onScrollDetach,
  gallerySwipe,
  galleryScrollRef,
  galleryIndex,
  galleryItemWidth,
  zoomMirror,
  gesturePulse,
}: {
  baseUri: string;
  originUri?: string;
  /** 原图自然尺寸（px）：fit 高度 = 屏宽 × (h/w) */
  imageWidth?: number;
  imageHeight?: number;
  onSingleTap: () => void;
  onZoomChange?: (zoomed: boolean) => void;
  /** 视觉当前页（全量挂载后仅 active 页解码，非激活页零解码空占位） */
  active: boolean;
  onLoadStart?: () => void;
  onLoadEnd?: () => void;
  /** 阅读滚动 pan（父级创建：与退出手势同流，未缩放时驱动长图上下阅读） */
  readPan: GestureType;
  /** 页下标：滚动状态按页注册到父级查表（全量挂载后多长图页不能共享单对
      SharedValue——2026-08-31 审查发现的 P0：旧实现所有长图页写同一
      scrollMax，边界判定互踩） */
  scrollIndex: number;
  onScrollAttach: (
    index: number,
    y: SharedValue<number>,
    max: SharedValue<number>,
  ) => void;
  onScrollDetach: (index: number) => void;
  /** 照片级图库滑动（同 ZoomableImage 契约） */
  gallerySwipe: boolean;
  galleryScrollRef: React.RefObject<ScrollableRef>;
  galleryIndex: number;
  galleryItemWidth: number;
  /** 缩放态镜像 / 手势脉冲（同 ZoomableImage 契约） */
  zoomMirror: SharedValue<boolean>;
  gesturePulse: SharedValue<number>;
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
    isZoomedIn,
    zoomGestureLastTime,
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
  // 镜像（长图页无 active 概念：未触达的页不会产生手势，常开即可）：
  // 换图/重挂时 JS 侧对齐一次（baseUri 变 = 新页实例复用 → 重对齐防残留），
  // 手势期间全程 UI 线程写入。
  useEffect(() => {
    zoomMirror.value = isZoomedIn.value;
  }, [zoomMirror, isZoomedIn, baseUri]);
  useAnimatedReaction(
    () => isZoomedIn.value,
    (z) => {
      zoomMirror.value = z;
    },
  );
  useAnimatedReaction(
    () => zoomGestureLastTime.value,
    (t, prev) => {
      if (t !== prev) {
        gesturePulse.value = gesturePulse.value + 1;
      }
    },
  );
  // 原图（originUri）解码失败标记：失败后不挂原图层（保持小档可读）
  const [originFailed, setOriginFailed] = useState(false);
  // 小档层失败自动重试（同 ZoomableImage 策略：prefetch 独立通道 + 换
  // recyclingKey 强制重载，最多 2 次）
  const [baseRetry, setBaseRetry] = useState(0);
  const baseRetryRef = useRef(0);
  const handleBaseError = useCallback(() => {
    if (baseRetryRef.current >= 2) return;
    baseRetryRef.current += 1;
    void Image.prefetch(baseUri);
    setTimeout(() => setBaseRetry((n) => n + 1), 600);
  }, [baseUri]);

  useEffect(() => {
    // 行复用/换图重置
    setOriginFailed(false);
  }, [baseUri, originUri]);

  // 换图重置缩放（同 ZoomableImage）：只依赖图源 URI——曾依赖
  // originUri/zoomOut 引用（首帧 originUri 可能异步到达 → 重置链抖动）。
  useEffect(() => {
    if (__DEV__) {
      console.warn(
        '[viewer-dbg]',
        new Date().toISOString().slice(11, 23),
        'zoom-reset',
        { uri: baseUri?.slice(-24) },
      );
    }
    zoomOut();
  }, [baseUri]);

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

  const insets = useSafeAreaInsets();

  // 页私有滚动状态（2026-08-31 P0 修复）：全量挂载后每张长图页各自持有
  // y/max，挂载时注册到父级查表；父级 readPan/退出手势按当前页读对应组，
  // 不再共享单对值互踩。卸载时注销。
  const scrollY = useSharedValue(0);
  const scrollMax = useSharedValue(0);
  useEffect(() => {
    onScrollAttach(scrollIndex, scrollY, scrollMax);
    return () => onScrollDetach(scrollIndex);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- 父子引用均稳定，仅挂载/卸载执行
  }, []);

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
            内容 = 阅读层（readPan + scroller）整体参与缩放/pan。
            非激活页（全量挂载的视觉外页）不渲染内容：零解码、零手势
            ——与 ZoomableImage 的 active 语义一致（2026-08-31）。 */}
        {!active ? (
          <View style={{ width: PART_SCREEN_WIDTH, height: PART_SCREEN_HEIGHT }} />
        ) : (
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
              onLoadStart={() => {
                if (__DEV__) {
                  console.warn(
                    '[viewer-dbg]',
                    new Date().toISOString().slice(11, 23),
                    'long-start',
                    baseUri.slice(-24),
                  );
                }
              }}
              onLoad={() => {
                if (__DEV__) {
                  console.warn(
                    '[viewer-dbg]',
                    new Date().toISOString().slice(11, 23),
                    'long-ok',
                    baseUri.slice(-24),
                  );
                }
                markImageWarm(baseUri);
              }}
              onError={() => {
                if (__DEV__) {
                  console.warn(
                    '[viewer-dbg]',
                    new Date().toISOString().slice(11, 23),
                    'long-err',
                    baseUri.slice(-24),
                    { retry: baseRetryRef.current },
                  );
                }
                handleBaseError();
              }}
              recyclingKey={`long-base-${baseRetry}-${baseUri}`}
            />
            {/* 原图层：后台解码完成后淡入替换；加载期间缩略层照常显示 */}
            {originUri && !originFailed ? (
              <Image
                source={{ uri: originUri }}
                style={partStyles.absoluteFillImage}
                contentFit="cover"
                cachePolicy="memory-disk"
                // 不再用 style opacity 门控：opacity 0 容器会把 expo-image 的
                // transition 淡入压到不可见、onLoad 后硬切（视觉硬跳变）。
                // 原图层常显，靠自带 transition 在底图（小档）上自然淡入。
                transition={
                  isImageWarm(originUri)
                    ? 0
                    : { duration: 150, timing: 'ease-out' } // iOS 系淡入是 ease-out（2026-08-31 审查）
                }
                priority="high"
                recyclingKey={`long-origin-${originUri}`}
                onLoadStart={onLoadStart}
                onLoad={() => {
                  markImageWarm(originUri);
                  onLoadEnd?.();
                }}
                onError={() => setOriginFailed(true)}
              />
            ) : null}
            </View>
          </Animated.View>
        </GestureDetector>
      </Animated.View>
        )}
    </GestureDetector>
    </View>
  );
});

// ---------- Native Thumbnail Cell ----------

export const ThumbnailCell = memo(function ThumbnailCell({
  uri,
  index,
  currentIndex,
  onPress,
}: {
  uri: string;
  index: number;
  currentIndex: number;
  onPress: (index: number) => void;
}) {
  // 全量拉取缩略图（2026-08-31 用户要求：9 张图必须全部显示）：原生
  // ImageIO 降采样到 56px + TiebaImageIO 磁盘缓存，非全量原图下载——
  // 8-25 修的「缩略条全量拉原图」问题不在此列（当时拉的是原尺寸）。
  const thumbnailUri = useNativeThumbnail(uri, 56, 56);
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
      {thumbnailUri ? (
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
