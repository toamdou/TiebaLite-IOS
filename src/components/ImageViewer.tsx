/* eslint-disable react-hooks/immutability -- Reanimated shared values are mutable refs; React Compiler cannot model them. */
/**
 * ImageViewer - Full-Screen Image Viewer with Zoom, Pan, and Pagination
 * Uses native iOS PagerView for smooth horizontal image browsing.
 * Each page uses ScrollView for pinch-to-zoom.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  Modal,
  View,
  Text,
  StyleSheet,
  Dimensions,
  ScrollView,
  Alert,
  ActivityIndicator,
  Pressable,
} from 'react-native';
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withSpring,
  withTiming,
  cancelAnimation,
  runOnJS,
} from 'react-native-reanimated';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import PagerView, { type PagerViewOnPageSelectedEvent } from 'react-native-pager-view';
import { Image } from 'expo-image';
import { SymbolView } from '@/components/ui/SymbolView';
import { GlassView } from '@/components/ui/GlassView';
import { hapticForScene } from '@/theme/hapticsMap';
import { saveImageToGallery, shareFile } from '@/services/media';

import { SafeAreaProvider, useSafeAreaInsets } from 'react-native-safe-area-context';
import { useAppPreference } from '@/hooks/useAppPreference';
import { useReducedMotion } from '@/hooks/useReducedMotion';
import type { ImageSourceFrame, ViewerImageMeta } from '@/hooks/useImageViewer';
import { buildPageWindow, ZoomableImage, ThumbnailCell } from '@/components/imageviewer/parts';
import { useAuthStore } from '@/stores/authStore';
import { Toast, type ToastRef } from '@/components/ui/Toast';
import { TiebaPhotoContextMenu } from '../../modules/tieba-native/src/TiebaPhotoContextMenu';
import { TiebaNative } from '../../modules/tieba-native/src/TiebaNative';
import { useLowPowerMode } from '../../modules/tieba-system/src';
import { readableError } from '@/utils/errorMessage';
import { resolveWatermarkText } from '@/utils/watermark';
import { Spacing } from '@/theme';
import { MOMENTUM, DURATION, EASE_OUT } from '@/theme/springs';

// ⚠️ 固定窗口尺寸的横向边界限制：SCREEN_WIDTH/HEIGHT 在模块加载时取一次
// （竖屏）。Modal supportedOrientations 含 landscape，旋转后 PagerView 页面
// 尺寸由 flex 撑开、可正常翻页缩放，但缩放钳制/拖拽飞出距离/背景揭示
// 等按竖屏数值计算（视觉可接受）。全组件改 useWindowDimensions 的连锁
// 改动面大且涉及时序敏感区，本轮不做（见 staticMode/teardown 注释）。
const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

/** 大图长按菜单：保存当前图 / 保存原图（服务器最高质量）/ 分享。
    动态追加「查看原图」（服务端 showOriginalBtn=1 且当前未显示原图时）。 */
const VIEWER_IMAGE_ACTIONS = [
  { id: 'save', title: '保存图片', icon: 'square.and.arrow.down' },
  { id: 'save-original', title: '保存原图', icon: 'arrow.down.to.line' },
  { id: 'share', title: '分享图片', icon: 'square.and.arrow.up' },
];

/** 拖拽揭示背景：200pt 内黑色遮罩完全渐隐、模糊背景完全显现 */
const BG_REVEAL_DISTANCE = 200;
/** 拖拽缩小全程：320pt 时图片缩至约 0.72 */
const SHRINK_DISTANCE = 320;
/** 飞回源缩略图动画时长（比普通退场稍缓，Photos 观感） */
const FLY_BACK_MS = 260;
// 关闭后延迟拆除的宽限期：给 PagerView 内部减速/手势收尾的时间，避免
// SwiftUI TabView 在动画途中被整树卸载（真机闪退），随后再真正卸载 Modal。
const TEARDOWN_GRACE_MS = 400;

// 抛错值 → 可读文本统一走 utils/errorMessage.readableError（thermo Z7-A）

// ---------- Props ----------

export interface ImageViewerProps {
  images: string[];
  initialIndex?: number;
  visible: boolean;
  onClose: () => void;
  forumName?: string;
  /** 被点击缩略图的屏幕矩形：交互式关闭时“飞回原位”；缺省则退化为飞出屏幕 */
  sourceFrame?: ImageSourceFrame | null;
  /** 并行原图数组（长按「保存原图」用；缺省该项退化为保存当前图） */
  imageOrigins?: (string | undefined)[];
  /** 顶栏标题：帖子图片=帖子标题；回复/楼中楼图片=回复文字前 30 字 */
  contextTitle?: string | null;
  /** 逐图元数据（服务端长图/查看原图标记 + 真实宽高；与 images 下标一一对应）。
      缺省时：无「查看原图」菜单项、无长图默认原图，保持老行为。 */
  imageMeta?: (ViewerImageMeta | undefined)[];
}

// ---------- Main ImageViewer Component ----------

export default function ImageViewer({
  images,
  initialIndex = 0,
  visible,
  onClose,
  forumName,
  sourceFrame,
  imageOrigins,
  contextTitle,
  imageMeta,
}: ImageViewerProps) {
  const [currentIndex, setCurrentIndex] = useState(initialIndex);
  const [showUI, setShowUI] = useState(true);
  const [downloadProgress, setDownloadProgress] = useState(false);
  // 大图内部 toast：提示渲染在 Modal 内（外层页面 toast 会被 Modal 盖住，
  // 用户实测「保存成功要退出大图才看得到」）
  const saveToastRef = useRef<ToastRef>(null);
  const [isZoomed, setIsZoomed] = useState(false);
  // 手动「查看原图」的页（下标 → 显示原图）；互斥于长图默认原图（后者不进此表）
  const [originMode, setOriginMode] = useState<Record<number, boolean>>({});
  // 原图加载中的页（显示圆形加载动画；onLoadStart/onLoadEnd 驱动）
  const [originLoading, setOriginLoading] = useState<Record<number, boolean>>({});
  // 关闭后延迟拆除：父组件 onClose 把 visible 置 false 时，PagerView（SwiftUI
  // TabView）若在滑动手势/减速动画未结束时被整棵卸载会崩（真机实测「退出大图
  // 即闪退」，模拟器时序宽松不易复现）。visible=false 后保持挂载
  // TEARDOWN_GRACE_MS 再卸载；宽限期内内容已强制透明、不响应触摸。
  const [mounted, setMounted] = useState(false);
  // 静态模式：任何关闭路径（拖拽过阈值 / X 按钮）启动时先卸载 PagerView，
  // 退出动画改用当前页静态大图——SwiftUI TabView 不再参与手势/动画期，
  // 从根上消除真机「退出大图即闪退」（TabView 在动画中卸载的竞态）。
  const [staticMode, setStaticMode] = useState(false);
  const insets = useSafeAreaInsets();
  const pagerRef = useRef<PagerView>(null);
  const thumbnailRef = useRef<ScrollView>(null);
  // 首次挂载时 initialPage prop 已定位到窗口 anchor，无需再同步；
  // 之后的 window 重建（currentIndex 变化）才需要 setPageWithoutAnimation 对齐。
  const pagerInitializedRef = useRef(false);

  // Watermark preference
  const imageWatermarkEnabled = useAppPreference('imageWatermarkEnabled', false);
  const imageWatermark = useAppPreference('imageWatermark', 'none');
  const account = useAuthStore((s) => s.account);
  const { reduceMotion } = useReducedMotion();
  const lowPowerMode = useLowPowerMode();

  // 长图判据：服务端 isLongPic 优先；缺失时退化服务端同款客户端判据
  // （Kotlin ForumBeanCaster: 图片高度 > 屏幕精确高度 → is_long_pic=1）。
  const isLongImageOf = useCallback(
    (index: number): boolean => {
      const meta = imageMeta?.[index];
      if (!meta) return false;
      if (meta.isLongPic === true) return true;
      return meta.height > 0 && meta.height > SCREEN_HEIGHT;
    },
    [imageMeta],
  );
  // 该页当前是否显示原图（长图默认原图 / 手动「查看原图」命中）
  const displayUriOf = useCallback(
    (index: number, fallback: string): string =>
      originMode[index] || isLongImageOf(index)
        ? (imageOrigins?.[index] ?? fallback)
        : fallback,
    [originMode, isLongImageOf, imageOrigins],
  );

  const pageWindow = useMemo(
    // 低功耗只降到 2：windowSize=1 时 PagerView 只有当前页、无法左右滑动翻图。
    () => {
      const win = buildPageWindow(images, currentIndex, lowPowerMode ? 2 : 3);
      return {
        ...win,
        pages: win.pages.map((p) => ({
          ...p,
          uri: displayUriOf(p.index, p.uri),
        })),
      };
    },
    [images, currentIndex, lowPowerMode, displayUriOf],
  );
  const { pages, start: pageWindowStart, anchor: pageWindowAnchor } = pageWindow;
  // 缩略条展示全部图片（仅大图 PagerView 走窗口化），实现长图集可直接跳到远端图。

  // 水印文案解析已收敛到 utils/watermark（thermo Z2-C）
  const getWatermarkText = useCallback(
    (forumName?: string) => resolveWatermarkText(imageWatermark ?? 'none', account?.name, forumName),
    [imageWatermark, account],
  );
  const watermarkText = imageWatermarkEnabled ? getWatermarkText(forumName) : '';

  // Overlay opacity animation
  const overlayOpacity = useSharedValue(1);
  // Drag-to-dismiss translation (Twitter style: translateY + scale-down + background reveal)
  const dragTranslateY = useSharedValue(0);
  // Entrance animation for the image (scale 0.95→1, opacity 0→1)
  const enterScale = useSharedValue(1);
  const enterOpacity = useSharedValue(1);
  // Exit animation (scale→0.8 + opacity→0, 180ms) before unmounting
  const exitScale = useSharedValue(1);
  const exitOpacity = useSharedValue(1);

  // ---------- 飞回源缩略图（iOS Photos 式交互关闭）----------
  // flyTranslateX / flyScale / flyRadiusFactor / flyOpacity：仅退场动画期间
  // 生效，目标值在打开时按 sourceFrame 预算好，手势 onEnd（UI 线程）直接取用。
  const flyTranslateX = useSharedValue(0);
  const flyScale = useSharedValue(1);
  const flyRadiusFactor = useSharedValue(1);
  const flyOpacity = useSharedValue(1);
  // 拖拽中的 320pt 缩小项：飞行开始时关闭，并把当前缩小值折算进 flyScale，
  // 保证整个动画轨迹连续（缩放在中途不跳变）。
  const dragShrinkEnabled = useSharedValue(1);
  // 防抖：退场动画进行中忽略新触摸，避免二次拖拽劫持动画。
  const isDismissing = useSharedValue(false);
  // 飞回目标（JS 预算 → UI 消费）
  const flyTargetX = useSharedValue(0);
  const flyTargetY = useSharedValue(0);
  const flyTargetScale = useSharedValue(1);
  const hasFlyTarget = useSharedValue(false);
  // 减少动态：把 reduceMotion 镜像到 UI 线程（手势 onEnd 里判断）
  const reduceMotionSV = useSharedValue(reduceMotion);

  useEffect(() => {
    reduceMotionSV.value = reduceMotion;
  }, [reduceMotion, reduceMotionSV]);

  useEffect(() => {
    cancelAnimation(overlayOpacity);
    if (reduceMotion) {
      overlayOpacity.value = withTiming(showUI ? 1 : 0, { duration: DURATION.enter });
    } else {
      overlayOpacity.value = withSpring(showUI ? 1 : 0, MOMENTUM);
    }
  }, [showUI, reduceMotion, overlayOpacity]);

  // Reset index when modal opens. 关闭时不再清空 expo-image 全局内存缓存：
  // 该缓存同时承载信息流/头像缩略图，全局 clear 会导致关图后回列表整段
  // 重新解码掉帧；大图内存交给 expo-image 自身 LRU + 全局 onMemoryWarning
  // 兜底（见 _layout.tsx）。
  useEffect(() => {
    if (visible) {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- reset viewer state when the modal opens.
      setCurrentIndex(initialIndex);
      setShowUI(true);
      setIsZoomed(false);
      setStaticMode(false);
      overlayOpacity.value = 1;
      dragTranslateY.value = 0;
      exitScale.value = 1;
      exitOpacity.value = 1;
      // 重置飞回动画状态
      isDismissing.value = false;
      dragShrinkEnabled.value = 1;
      flyTranslateX.value = 0;
      flyScale.value = 1;
      flyRadiusFactor.value = 1;
      flyOpacity.value = 1;
      // Entrance animation (iOS Photos style). Respect reduced motion.
      if (reduceMotion) {
        enterScale.value = 1;
        enterOpacity.value = 1;
      } else {
        enterScale.value = 0.95;
        enterOpacity.value = 0;
        enterScale.value = withTiming(1, { duration: DURATION.enter });
        enterOpacity.value = withTiming(1, { duration: DURATION.enter });
      }
    }
  }, [visible, initialIndex, overlayOpacity, dragTranslateY, enterScale, enterOpacity, exitScale, exitOpacity, reduceMotion, isDismissing, dragShrinkEnabled, flyTranslateX, flyScale, flyRadiusFactor, flyOpacity]);

  // 打开时按 sourceFrame 预算飞回目标。列表缩略图与源图同宽高比 ⇒ 由 frame
  // 宽高比即可推出全屏 contain 显示尺寸（无需等原图解码）。
  // 目标变换按 contentStyle 的 [translate, scale] 顺序（屏幕空间平移）推导：
  //   scale = fw / 显示宽；tx = frame 中心X - scale·W/2；ty = frame 中心Y - scale·H/2
  useEffect(() => {
    if (!visible || !sourceFrame || sourceFrame.width <= 0 || sourceFrame.height <= 0) {
      hasFlyTarget.value = false;
      return;
    }
    const fw = sourceFrame.width;
    const fh = sourceFrame.height;
    const aspect = fw / fh;
    // 当前页图片在全屏内 contain 的显示宽度（与 frame 同宽高比）
    const displayW = Math.min(SCREEN_WIDTH, SCREEN_HEIGHT * aspect);
    if (displayW <= 0) {
      hasFlyTarget.value = false;
      return;
    }
    const targetScale = fw / displayW;
    flyTargetX.value = sourceFrame.x + fw / 2 - (targetScale * SCREEN_WIDTH) / 2;
    flyTargetY.value = sourceFrame.y + fh / 2 - (targetScale * SCREEN_HEIGHT) / 2;
    flyTargetScale.value = targetScale;
    hasFlyTarget.value = true;
  }, [visible, sourceFrame, flyTargetX, flyTargetY, flyTargetScale, hasFlyTarget]);

  // Scroll thumbnail strip to current item
  useEffect(() => {
    const thumbWidth = 56 + 6;
    thumbnailRef.current?.scrollTo({
      x: Math.max(0, currentIndex * thumbWidth - SCREEN_WIDTH / 2 + thumbWidth / 2),
      animated: true,
    });
  }, [currentIndex]);

  // Keep the windowed PagerView centered on the current page so only the
  // current ±1 pages stay mounted.
  useEffect(() => {
    if (!visible || !pagerRef.current) return;
    if (!pagerInitializedRef.current) {
      // 首次挂载：initialPage 已定位 anchor，重复 setPage 可能在挂载期
      // 触发 SwiftUI TabView 同步竞态（真机偶发打开即崩），跳过。
      pagerInitializedRef.current = true;
      return;
    }
    pagerRef.current.setPageWithoutAnimation(pageWindowAnchor);
  }, [currentIndex, visible, pageWindowAnchor]);

  // 关闭延迟拆除：visible=false 后保留 Modal 挂载 TEARDOWN_GRACE_MS，
  // 让 PagerView 内部 scroll view 的减速/手势彻底结束后再整树卸载
  // （真机实测：退出大图查看器立刻卸载会闪退；宽限期内按 mounted 渲染）。
  useEffect(() => {
    if (visible) {
      setMounted(true);
      return;
    }
    // 兜底强制内容透明：非减少动态路径退场动画已完成（opacity 已 0），
    // reduceMotion 路径是瞬间 onClose，这里直接压 0 保证宽限期不可见。
    enterOpacity.value = 0;
    exitOpacity.value = 0;
    flyOpacity.value = 0;
    const t = setTimeout(() => setMounted(false), TEARDOWN_GRACE_MS);
    return () => clearTimeout(t);
  }, [visible, enterOpacity, exitOpacity, flyOpacity]);

  const topBarAnimStyle = useAnimatedStyle(() => {
    // 拖拽启动时顶栏/缩略条随进度淡出（Twitter 行为）；飞回时随飞回透明度彻底隐去
    const dragFade = Math.min(Math.abs(dragTranslateY.value) / 140, 1);
    return { opacity: overlayOpacity.value * (1 - dragFade) * flyOpacity.value };
  });

  /**
   * 背景揭示（Twitter 拖拽关闭）：
   * - 黑色遮罩随拖拽距离渐隐（200pt 完全揭示）
   * - 底层 GlassView 实时模糊后方信息流，透明度随拖拽渐显
   * - 进场（enterOpacity）/ 退场（exitOpacity）阶段同步淡入淡出
   * - 飞回阶段（flyOpacity→0）：遮罩完全淡出、模糊完全显现，露出列表缩略图
   */
  const bgScrimStyle = useAnimatedStyle(() => {
    const reveal = Math.min(Math.abs(dragTranslateY.value) / BG_REVEAL_DISTANCE, 1);
    return { opacity: (1 - reveal) * enterOpacity.value * exitOpacity.value * flyOpacity.value };
  });

  const bgBlurStyle = useAnimatedStyle(() => {
    const reveal = Math.min(Math.abs(dragTranslateY.value) / BG_REVEAL_DISTANCE, 1);
    return {
      opacity:
        enterOpacity.value *
        exitOpacity.value *
        (reveal + (1 - reveal) * (1 - flyOpacity.value)),
    };
  });

  /**
   * 内容统一动效：入场缩放 × 拖拽位移/缩小（1→0.72，320pt 全程）× 退场缩放 × 飞回缩放。
   * 单一 transform 计算避免多 style 数组 transform 相互覆盖。
   * 拖拽时同步增大圆角（Twitter 缩小图片的圆角收束感）；飞回时圆角收束到缩略图级别。
   */
  const contentStyle = useAnimatedStyle(() => {
    // dragShrinkEnabled=0（飞回阶段）时关闭距离缩小，由 flyScale 接管至目标值
    const dragProgress = Math.min(Math.abs(dragTranslateY.value) / SHRINK_DISTANCE, 1);
    const scale =
      enterScale.value *
      (1 - dragShrinkEnabled.value * dragProgress * 0.28) *
      exitScale.value *
      flyScale.value;
    const dragFade = Math.min(Math.abs(dragTranslateY.value) / (SCREEN_HEIGHT * 0.6), 0.25);
    return {
      transform: [
        { translateX: flyTranslateX.value },
        { translateY: dragTranslateY.value },
        { scale },
      ],
      borderRadius: 24 * dragProgress * flyRadiusFactor.value,
      borderCurve: 'continuous',
      opacity: enterOpacity.value * exitOpacity.value * (1 - dragFade),
    };
  });

  // iOS 26 Photos-style close: content scale→0.8 + opacity→0 (180ms) then
  // unmount. Reduced motion users skip the animation.
  const closeViewer = useCallback(() => {
    // 先切换到静态模式：PagerView（SwiftUI TabView）在纯退出动画期卸载，
    // 不参与主线程动画竞争（真机「退出即闪退」根修，见 staticMode 注释）
    setStaticMode(true);
    if (reduceMotion) {
      onClose();
      return;
    }
    cancelAnimation(exitScale);
    cancelAnimation(exitOpacity);
    exitScale.value = withTiming(0.8, { duration: DURATION.exit });
    exitOpacity.value = withTiming(0, { duration: DURATION.exit }, (finished) => {
      if (finished) runOnJS(onClose)();
    });
  }, [reduceMotion, onClose, exitScale, exitOpacity]);

  // 交互式拖拽关闭（iOS Photos 风格）：
  // - 上滑、下滑均驱动关闭（activeOffsetY 已同时接受两个方向）
  // - 放开时距离或速度过阈值 → 有源矩形则“飞回缩略图”，否则沿手势方向飞出；
  //   未过阈值 → 弹簧回弹
  // - 缩放态（isZoomed）下禁用，交给 ZoomableImage 内的平移
  // 手势 useMemo 包裹（动画食谱 G1）：拖拽中途若页面重渲染（翻页/UI 切换），
  // 重建手势会重挂识别器、丢掉进行中的拖拽。依赖列 props/state 变化项；
  // 共享值为稳定 ref，一并列入口维护一致。
  const dismissGesture = useMemo(
    () =>
      Gesture.Pan()
        .enabled(!isZoomed)
        .activeOffsetY([-14, 14])
        .onUpdate((e) => {
          if (isDismissing.value) return;
          dragTranslateY.value = e.translationY;
        })
        .onEnd((e) => {
          if (isDismissing.value) return;
          const beyondThreshold =
            Math.abs(e.translationY) > 140 || Math.abs(e.velocityY) > 900;
          if (!beyondThreshold) {
            // 未过阈值 → 弹簧回弹
            dragTranslateY.value = withSpring(0, MOMENTUM);
            return;
          }
          const direction = e.translationY !== 0
            ? Math.sign(e.translationY)
            : (Math.sign(e.velocityY) || 1);
          isDismissing.value = true;
          // 决定关闭：切换静态模式（PagerView 卸载），后续动画由静态大图承担
          runOnJS(setStaticMode)(true);
          if (reduceMotionSV.value) {
            runOnJS(onClose)();
            return;
          }
          // 飞回判定需与飞回目标脱钩解耦：flyTarget* 只在打开瞬间按
          // initialIndex 页预算。滑到其他页后再拖拽关闭时，目标矩形已与该页
          // 图片脱钩（会“飞”向当初那张缩略图），此时退化为沿手势方向飞出。
          if (hasFlyTarget.value && currentIndex === initialIndex) {
            // 飞回被点击缩略图：先把当前拖拽缩小快照进 flyScale 再关闭缩小项
            // （有效缩放连续不跳变），随后整体动画到源矩形，背景同步淡出
            const progress = Math.min(Math.abs(dragTranslateY.value) / SHRINK_DISTANCE, 1);
            const currentShrink = 1 - progress * 0.28;
            dragShrinkEnabled.value = 0;
            flyScale.value = currentShrink;
            flyScale.value = withTiming(flyTargetScale.value, { duration: FLY_BACK_MS, easing: EASE_OUT });
            flyTranslateX.value = withTiming(flyTargetX.value, { duration: FLY_BACK_MS, easing: EASE_OUT });
            flyRadiusFactor.value = withTiming(0.35, { duration: FLY_BACK_MS, easing: EASE_OUT });
            flyOpacity.value = withTiming(0, { duration: FLY_BACK_MS, easing: EASE_OUT });
            dragTranslateY.value = withTiming(
              flyTargetY.value,
              { duration: FLY_BACK_MS, easing: EASE_OUT },
              (finished) => {
                if (finished) runOnJS(onClose)();
              },
            );
          } else {
            // 无源矩形（如 TweetCard 信息流图）：沿拖拽方向飞出（背景揭示到 100%，
            // 图片缩小淡出），结束后卸载 —— 方向跟随手势，上滑即飞出屏幕顶部
            dragTranslateY.value = withTiming(
              direction * SCREEN_HEIGHT,
              { duration: DURATION.exit },
              (finished) => {
                if (finished) runOnJS(onClose)();
              },
            );
          }
        }),
    [
      isZoomed,
      onClose,
      currentIndex,
      initialIndex,
      setStaticMode,
      reduceMotionSV,
      hasFlyTarget,
      dragTranslateY,
      isDismissing,
      dragShrinkEnabled,
      flyScale,
      flyTargetScale,
      flyTranslateX,
      flyTargetX,
      flyRadiusFactor,
      flyOpacity,
      flyTargetY,
    ],
  );

  const toggleUI = useCallback(() => {
    setShowUI((prev) => !prev);
  }, []);

  const handleClose = useCallback(() => {
    hapticForScene('press');
    closeViewer();
  }, [closeViewer]);

  const handlePageSelected = useCallback(
    (e: PagerViewOnPageSelectedEvent) => {
      hapticForScene('toggle');
      setCurrentIndex(e.nativeEvent.position + pageWindowStart);
    },
    [pageWindowStart],
  );

  const handleThumbnailPress = useCallback(
    (idx: number) => {
      const localIndex = idx - pageWindowStart;
      if (localIndex >= 0 && localIndex < pages.length) {
        // 目标页在当前窗口内：直接翻页（窗口随滑动重建）
        pagerRef.current?.setPage(localIndex);
      } else {
        // 目标页在当前窗口外（缩略条可跳远图）：直接更新 currentIndex，
        // 窗口围绕新页重建，再交给 setPageWithoutAnimation 对齐到新 anchor。
        setCurrentIndex(idx);
      }
    },
    [pageWindowStart, pages.length],
  );

  // iOS 27：RN 的 <StatusBar hidden /> 是 no-op，状态栏隐藏走原生 VC 级。
  // 时序（真机崩溃日志 tiebalite-*.ips：SIGABRT @ UIKit
  // _noteOverlayInsetsDidChange 断言）：
  // - 打开：延迟 700ms 才隐藏——Modal present 动画（~350ms）完全结束后
  //   再 setNeedsStatusBarAppearanceUpdate，否则 present 中途调用会让
  //   UIKit 断言 abort（「刚点进去还没进入大图就闪退」根因）
  // - 关闭：**绝不立即恢复**——Modal 尚在拆除/布局中，同样触发断言。
  //   恢复交给 mounted→false（teardown 完成、Modal 已卸载）后的 effect，
  //   再等 300ms 确保 CATransaction 完全落定。
  useEffect(() => {
    if (!visible) return;
    const t = setTimeout(() => TiebaNative.setModalStatusBarHidden(true), 700);
    return () => clearTimeout(t);
  }, [visible]);

  // Modal 完全卸载（teardown 宽限期结束）后才恢复状态栏：此时无任何
  // UIKit 动画/布局竞争，setNeedsStatusBarAppearanceUpdate 安全。
  useEffect(() => {
    if (mounted) return;
    const t = setTimeout(() => TiebaNative.setModalStatusBarHidden(false), 300);
    return () => clearTimeout(t);
  }, [mounted]);

  // Download and share image
  // 保存/分享/切原图按「菜单挂载的页」（index）取图：长按的是该页图片，
  // 用 currentIndex 在窗口内滑动后可能存错相邻页的图。
  // 保存到相册（普通档/原图档唯一分叉是取哪个 uri，其余流程完全一致）
  const saveImage = useCallback(async (uri: string | undefined) => {
    if (!uri) return;
    setDownloadProgress(true);
    try {
      const wm = getWatermarkText(forumName);
      await saveImageToGallery(uri, imageWatermarkEnabled ? wm : '');
      hapticForScene('action-success');
      saveToastRef.current?.show({ title: '保存成功', type: 'success' });
    } catch (e: unknown) {
      const message = readableError(e);
      if (message === 'PERMISSION_DENIED') {
        Alert.alert('权限不足', '请在设置中允许访问相册以保存图片');
        return;
      }
      Alert.alert('保存失败', message || '无法保存图片到相册');
    } finally {
      setDownloadProgress(false);
    }
  }, [getWatermarkText, imageWatermarkEnabled, forumName]);

  const handleSaveToGallery = useCallback(
    (index: number) => void saveImage(images[index]),
    [saveImage, images],
  );

  // 保存原图：无视用户图片参数设置，直接保存服务器最高质量原图
  const handleSaveOriginal = useCallback(
    (index: number) => void saveImage(imageOrigins?.[index] ?? images[index]),
    [saveImage, imageOrigins, images],
  );

  // Share image
  const handleShare = useCallback(async (index: number) => {
    hapticForScene('press');
    const uri = images[index];
    if (!uri) return;
    try {
      const filename = uri.split('/').pop()?.split('?')[0] ?? `image_${Date.now()}.jpg`;
      const watermark = getWatermarkText(forumName);
      await shareFile(uri, `share_${filename}`, {
        mimeType: 'image/jpeg',
        dialogTitle: watermark ? `分享图片 — ${watermark}` : '分享图片',
        watermarkText: imageWatermarkEnabled ? watermark : '',
      });
    } catch (e: unknown) {
      const message = readableError(e);
      if (message === 'SHARE_UNAVAILABLE') {
        Alert.alert('提示', '当前设备不支持分享功能');
      } else {
        // 其余失败不打扰用户，落日志便于排查（分享面板偶发系统级取消/降级）
        console.warn('[ImageViewer] shareFile failed:', e);
      }
    }
  }, [images, getWatermarkText, imageWatermarkEnabled, forumName]);

  /** 大图长按菜单（含保存原图/查看原图）：在长按位置弹出，与信息流同款样式 */
  const handlePageMenuAction = useCallback((index: number, actionId: string) => {
    if (actionId === 'save') void handleSaveToGallery(index);
    else if (actionId === 'save-original') void handleSaveOriginal(index);
    else if (actionId === 'share') void handleShare(index);
    else if (actionId === 'view-original') {
      // 长图默认已是原图，菜单不会出现此项；仅从有损档切换时进入
      setOriginMode((prev) => ({ ...prev, [index]: true }));
      setOriginLoading((prev) => ({ ...prev, [index]: true }));
      hapticForScene('press');
    }
  }, [handleSaveToGallery, handleSaveOriginal, handleShare]);

  /** 逐页菜单项：基础三项 + 服务端 showOriginalBtn 且当前未显示原图时追加「查看原图」 */
  const buildPageActions = useCallback((index: number) => {
    const meta = imageMeta?.[index];
    if (meta?.showOriginalBtn !== true || originMode[index] || isLongImageOf(index)) {
      return VIEWER_IMAGE_ACTIONS;
    }
    return [...VIEWER_IMAGE_ACTIONS, { id: 'view-original', title: '查看原图', icon: 'photo' }];
  }, [imageMeta, originMode, isLongImageOf]);

  if (images.length === 0) return null;

  return (
    <Modal
      visible={mounted}
      transparent
      animationType="none"
      statusBarTranslucent
      onRequestClose={closeViewer}
      supportedOrientations={['portrait', 'landscape']}
    >
      {/* RN Modal 内容不在页面层 SafeAreaProvider 内：不嵌套会拿到 insets=0，
          顶栏 paddingTop 只剩 30pt，被灵动岛遮住（用户实测）。官方推荐在
          Modal 内容根部再放一个 SafeAreaProvider，自动读窗口安全区。 */}
      <SafeAreaProvider style={styles.viewerRoot}>
        <GestureDetector gesture={dismissGesture}>
          <Animated.View
            style={[styles.modalContainer, { pointerEvents: visible ? 'auto' : 'none' }]}
          >
          {/* 状态栏隐藏/恢复走原生（TiebaNative.setModalStatusBarHidden）：iOS 27
              RN StatusBar 是 no-op 且 setStyle 会红屏；这里不放 StatusBar */}

          {/* 背景层 1：实时毛玻璃（模糊后方信息流，拖拽时渐显；GlassView 内置降级策略） */}
          <Animated.View style={[styles.bgLayer, bgBlurStyle]} pointerEvents="none">
            <GlassView
              theme="dark"
              glassEffectStyle="regular"
              style={StyleSheet.absoluteFill}
            />
          </Animated.View>
          {/* 背景层 2：黑色遮罩（静止时全黑，拖拽时渐隐揭示模糊背景） */}
          <Animated.View style={[styles.bgLayer, styles.bgScrim, bgScrimStyle]} pointerEvents="none" />

          {/* Image Gallery — native iOS PagerView */}
          <Animated.View style={[styles.pagerWrap, contentStyle]}>
          {staticMode ? (
            /* 静态模式：退出动画期间无 PagerView（SwiftUI TabView 已卸载，
               卸载冲突是「退出大图即闪退」根因）；用当前页大图承担退出动画。 */
            <Image
              source={{ uri: images[currentIndex] }}
              style={styles.pager}
              contentFit="contain"
              transition={0}
              recyclingKey={`viewer-static-${currentIndex}`}
            />
          ) : (
          <PagerView
            ref={pagerRef}
            style={styles.pager}
            initialPage={pageWindowAnchor}
            scrollEnabled={!isZoomed}
            onPageSelected={handlePageSelected}
            overdrag
          >
            {pages.map((page) => (
              <View key={String(page.index)} collapsable={false} style={styles.imagePage}>
                {/* 大图长按：在长按位置弹出选项框（无放大预览，页面本身已是大图） */}
                <TiebaPhotoContextMenu
                  fullUrl={imageOrigins?.[page.index] ?? page.uri}
                  previewEnabled={false}
                  actions={buildPageActions(page.index)}
                  onAction={(actionId) => handlePageMenuAction(page.index, actionId)}
                  style={StyleSheet.absoluteFill}
                >
                  <ZoomableImage
                    uri={page.uri}
                    onSingleTap={toggleUI}
                    onZoomChange={setIsZoomed}
                    active={page.active}
                    zoomed={isZoomed}
                    onLoadStart={() => {
                      // 仅当该页显示的是原图（长图默认/手动切换）时转圈：
                      // 普通档位图沿用原有直出行为，不闪加载动画
                      if (page.uri !== images[page.index]) {
                        setOriginLoading((prev) => ({ ...prev, [page.index]: true }));
                      }
                    }}
                    onLoadEnd={() => {
                      setOriginLoading((prev) => ({ ...prev, [page.index]: false }));
                    }}
                  />
                </TiebaPhotoContextMenu>
                {originLoading[page.index] ? (
                  <View pointerEvents="none" style={styles.originLoadingOverlay}>
                    <ActivityIndicator size="large" color="#FFFFFF" />
                  </View>
                ) : null}
                {watermarkText ? (
                  <Text
                    pointerEvents="none"
                    style={styles.watermarkOverlay}
                    numberOfLines={1}
                  >
                    {watermarkText}
                  </Text>
                ) : null}
              </View>
            ))}
          </PagerView>
          )}
        </Animated.View>

        {/* Top Bar */}
        <Animated.View
          style={[styles.topBar, { paddingTop: Math.max(insets.top, 30) }, topBarAnimStyle]}
          pointerEvents={showUI ? 'auto' : 'none'}
        >
          <GlassView
            theme="dark"
            // 顶栏被 0.45 黑色蒙版盖住，玻璃几乎不可见：显式静态，不占预算
            realTime={false}
            style={[StyleSheet.absoluteFill, { backgroundColor: 'rgba(0,0,0,0.45)' }]}
          />
          <Pressable
            onPress={handleClose}
            style={({ pressed }) => [styles.topBarButton, pressed && styles.topBarButtonPressed]}
            hitSlop={12}
            accessibilityRole="button"
            accessibilityLabel="关闭图片查看器"
          >
            <SymbolView name="xmark" size={22} weight="bold" tintColor="#FFFFFF" />
          </Pressable>

          {/* 中间：页码 + 上下文标题（帖子标题 / 回复文字前 30 字，超出省略）。
              绝对居中于整条顶栏（左右按钮数量不对称，flex:1 会偏向右侧，
              无法对齐灵动岛/刘海正中）。与 topBar 同 padding 且垂直居中，
              保证标题行与 x 按钮/右侧按钮精确同一直线。标题不可点，穿透给底层。 */}
          <View
            style={[
              styles.topBarCenter,
              { paddingTop: Math.max(insets.top, 30), paddingBottom: Spacing.sm },
            ]}
            pointerEvents="none"
          >
            <Text style={styles.counterText} accessibilityLiveRegion="polite">
              {currentIndex + 1}/{images.length}
            </Text>
            {contextTitle ? (
              <Text style={styles.contextTitleText} numberOfLines={1} ellipsizeMode="tail">
                {contextTitle}
              </Text>
            ) : null}
          </View>

          <View style={styles.topBarActions}>
            <Pressable
              onPress={() => handleSaveToGallery(currentIndex)}
              style={({ pressed }) => [styles.topBarButton, pressed && styles.topBarButtonPressed]}
              hitSlop={12}
              disabled={downloadProgress}
              accessibilityRole="button"
              accessibilityLabel="保存到相册"
            >
              <SymbolView
                name="square.and.arrow.down"
                size={22}
                weight="medium"
                tintColor={downloadProgress ? 'rgba(255,255,255,0.4)' : '#FFFFFF'}
              />
            </Pressable>
            <Pressable
              onPress={() => handleShare(currentIndex)}
              style={({ pressed }) => [styles.topBarButton, pressed && styles.topBarButtonPressed]}
              hitSlop={12}
              accessibilityRole="button"
              accessibilityLabel="分享图片"
            >
              <SymbolView name="square.and.arrow.up" size={22} weight="medium" tintColor="#FFFFFF" />
            </Pressable>
          </View>
        </Animated.View>

        {/* Bottom Thumbnail Strip */}
        {images.length > 1 && (
          <Animated.View
            style={[styles.bottomBar, { paddingBottom: Math.max(insets.bottom, 16) }, topBarAnimStyle]}
            pointerEvents={showUI ? 'auto' : 'none'}
          >
            <GlassView
              theme="dark"
              // 底部缩略图条同样被深色蒙版覆盖：显式静态，不占预算
              realTime={false}
              style={[StyleSheet.absoluteFill, { backgroundColor: 'rgba(0,0,0,0.45)' }]}
            />
            <ScrollView
              ref={thumbnailRef}
              horizontal
              showsHorizontalScrollIndicator={false}
              contentContainerStyle={styles.thumbnailStrip}
            >
              {images.map((uri, index) => (
                <ThumbnailCell
                  key={index}
                  uri={uri}
                  index={index}
                  currentIndex={currentIndex}
                  active={Math.abs(index - currentIndex) <= 1}
                  onPress={handleThumbnailPress}
                />
              ))}
            </ScrollView>
          </Animated.View>
        )}
      </Animated.View>
      </GestureDetector>
        </SafeAreaProvider>
          {/* 大图内部 toast（Modal 内最高层；外层 toast 被 Modal 遮挡） */}
          <Toast ref={saveToastRef} />

    </Modal>
  );
}

// ---------- Styles ----------

const styles = StyleSheet.create({
  viewerRoot: {
    flex: 1,
  },
  modalContainer: {
    flex: 1,
  },
  // 背景层：透明 Modal 下承载 模糊/遮罩（先于内容渲染，位于底层）
  bgLayer: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
  },
  bgScrim: {
    backgroundColor: '#000000',
  },
  pager: {
    flex: 1,
  },
  pagerWrap: {
    flex: 1,
    overflow: 'hidden',
  },
  imagePage: {
    width: SCREEN_WIDTH,
    height: SCREEN_HEIGHT,
    justifyContent: 'center',
    alignItems: 'center',
  },
  watermarkOverlay: {
    position: 'absolute',
    right: 20,
    bottom: 24,
    maxWidth: '70%',
    color: 'rgba(255,255,255,0.72)',
    fontSize: 12,
    fontWeight: '500',
    textShadowColor: 'rgba(0,0,0,0.6)',
    textShadowOffset: { width: 0, height: 1 },
    textShadowRadius: 3,
  },
  topBar: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: Spacing.md,
    paddingBottom: Spacing.sm,
    backgroundColor: 'transparent',
    zIndex: 10,
  },
  topBarButton: {
    width: 40,
    height: 40,
    borderRadius: 20,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(255,255,255,0.1)',
    justifyContent: 'center',
    alignItems: 'center',
  },
  topBarButtonPressed: {
    // 顶栏按钮无高光效果（2026-08-28 用户要求）；仅按压微降不透明度
    opacity: 0.55,
  },
  topBarActions: {
    flexDirection: 'row',
    gap: 8,
  },
  counterText: {
    color: '#FFFFFF',
    fontSize: 16,
    fontWeight: '600',
  },
  topBarCenter: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    // 使用与 topBar 相同的上下 padding 把内容垂直对齐到按钮行
    justifyContent: 'center',
    alignItems: 'center',
    paddingHorizontal: Spacing.sm,
  },
  originLoadingOverlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    justifyContent: 'center',
    alignItems: 'center',
    backgroundColor: 'transparent',
  },
  contextTitleText: {
    color: 'rgba(255,255,255,0.85)',
    fontSize: 13,
    fontWeight: '500',
    // 左右各留出按钮区（左 1 右 2 × 40pt + 间距），超长自动省略号截断
    maxWidth: SCREEN_WIDTH - 180,
  },
  bottomBar: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    paddingTop: Spacing.sm,
    backgroundColor: 'transparent',
    zIndex: 10,
  },
  thumbnailStrip: {
    paddingHorizontal: Spacing.md,
    gap: 6,
  },
});
