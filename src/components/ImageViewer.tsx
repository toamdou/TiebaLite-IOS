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
  withDecay,
  cancelAnimation,
  runOnJS,
  Easing,
} from 'react-native-reanimated';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import PagerView, { type PagerViewOnPageSelectedEvent } from 'react-native-pager-view';
import { Image } from 'expo-image';
import { SymbolView } from '@/components/ui/SymbolView';
import { GlassView } from '@/components/ui/GlassView';
import { hapticForScene } from '@/theme/hapticsMap';
import { saveImageToGallery, shareFile } from '@/services/media';
import { isImageWarm, markImageWarm } from '@/utils/imageWarm';

import { SafeAreaProvider, useSafeAreaInsets } from 'react-native-safe-area-context';
import { useAppPreference } from '@/hooks/useAppPreference';
import { useReducedMotion } from '@/hooks/useReducedMotion';
import type { ImageSourceFrame, ViewerImageMeta } from '@/hooks/useImageViewer';
import { buildPageWindow, LongImageView, ZoomableImage, ThumbnailCell } from '@/components/imageviewer/parts';
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
// 改动面大且涉及时序敏感区，本轮不做（见 teardown 注释）。
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
/** 拖拽缩小全程：280pt 时图片缩至约 0.75（跟手缩小，松手后经退场动画归位） */
const SHRINK_DISTANCE = 280;
/** 拖拽缩小系数（280pt 时 1 → 0.75） */
const DRAG_SHRINK_FACTOR = 0.25;
/** 飞回源缩略图动画时长（Photos 观感：跟手松手 → 减速归位，~0.36s 平滑收尾） */
const FLY_BACK_MS = 360;
/** 无源矩形沿手势方向飞出的时长 */
const EXIT_FLING_MS = 300;
/** 退场双轴缓动：x 快出慢收、y 缓起缓落——同一 progress 插值出抛物线轨迹
    （水平分量先行、垂直分量后至），轨迹自然且两轴全程同步（单驱动无竞态）。 */
const EXIT_EASE_X = Easing.out(Easing.cubic);
const EXIT_EASE_Y = Easing.inOut(Easing.quad);
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
  // 静态模式：退出动画改用当前页静态大图承担（PagerView/SwiftUI TabView 不参与
  // 退场 transform——宿主视图变换是 120fps 卡顿源）；切换时 URI 与当前页显示档
  // 一致 + imageWarm 免过渡，换图像素级无感（不再有裸换树闪白）。
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

  // 长图判据：纯几何——fit-width 显示高度超过屏高才进阅读模式。服务端
  // isLongPic 标记对"稍高于屏"的图会过宽路由成阅读模式（顶部顶状态栏、
  // 底部被裁，用户 2026-08-29 反馈"部分图片靠上显示"）；有真实尺寸时以
  // 几何为准，尺寸未知才信服务端标记。阅读模式自带顶部安全区让位。
  const isLongImageOf = useCallback(
    (index: number): boolean => {
      const meta = imageMeta?.[index];
      if (!meta) return false;
      const w = meta.width;
      const h = meta.height;
      if (w > 0 && h > 0) {
        return (SCREEN_WIDTH * h) / w > SCREEN_HEIGHT + 1;
      }
      return meta.isLongPic === true;
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
  // Drag-to-dismiss translation（Twitter 式 2D 跟手：Y 为主退出轴，X 同步跟手）
  const dragTranslateX = useSharedValue(0);
  const dragTranslateY = useSharedValue(0);
  // Entrance animation for the image (scale 0.95→1, opacity 0→1)
  const enterScale = useSharedValue(1);
  const enterOpacity = useSharedValue(1);
  // 退场统一动画（唯一驱动）：exitProgress 0→1，x/y/scale/圆角/透明度全部由
  // 同一个 progress 插值（双轴缓动不同 → 抛物线轨迹），杜绝多 timing 竞态顿挫。
  // 目标参数在手势 onEnd / closeViewer 时写入，动画期间不再读取手势位移。
  const exitProgress = useSharedValue(0);
  const exitFromX = useSharedValue(0);
  const exitFromY = useSharedValue(0);
  const exitFromScale = useSharedValue(1);
  const exitToX = useSharedValue(0);
  const exitToY = useSharedValue(0);
  const exitToScale = useSharedValue(1);
  // 退场期圆角冻结值（拖拽结束时的圆角；退场期间不再逐帧改 borderRadius——
  // 大图切圆角每帧重栅格化是退场卡顿源之一）
  const exitRadius = useSharedValue(0);
  // 手势仲裁：起始点 + 上一帧位移（onTouchesMove 手动激活判定 + 增量跟手）
  const touchStartX = useSharedValue(0);
  const touchStartY = useSharedValue(0);
  const prevTransX = useSharedValue(0);
  const prevTransY = useSharedValue(0);
  // 长图页滚动状态（longReadPan 写入）：偏移/最大可滚量。
  // 最大可滚量由 LongImageView 按内容高+顶部安全区写入；退出手势据此仲裁
  // "滚动 vs 退出"（顶下拉/底上拉）。
  const longScrollY = useSharedValue(0);
  const longScrollMax = useSharedValue(0);
  // 手势 worklet 只读镜像（手势 useMemo 不随渲染重建，直接读共享值拿新状态）
  const currentIdxSV = useSharedValue(initialIndex);
  const pageCountSV = useSharedValue(images.length);
  const initialIdxSV = useSharedValue(initialIndex);
  const isLongPageSV = useSharedValue(false);
  // 缩放态镜像：退出手势/阅读 pan 的门控走共享值，手势本体不随 isZoomed
  // 重建——快速捏合时父级 setIsZoomed 重渲染不会掐断进行中的捏合（真机：
  // 快速捏合后松手弹回原尺寸的根因）。
  const zoomedSV = useSharedValue(isZoomed);
  useEffect(() => {
    zoomedSV.value = isZoomed;
  }, [isZoomed, zoomedSV]);

  // ---------- 飞回源缩略图（iOS Photos 式交互关闭）----------
  // 飞回目标在打开时按 sourceFrame 预算好，手势 onEnd（UI 线程）直接取用；
  // 动画本体由上方 exitProgress 统一驱动，这里只存目标矩形。
  // 防抖：退场动画进行中忽略新触摸，避免二次拖拽劫持动画。
  const isDismissing = useSharedValue(false);

  // 长图阅读滚动 pan：与退出手势 RNGH-RNGH 同流（不再套原生 ScrollView——
  // UIKit 滚动抢先吃触摸、边界仲裁失效是真机"大图退不出"的实证根因）。
  // offset 由本手势直接写入 longScrollY（UI 线程），退出手势读到的边界状态
  // 帧帧新鲜；缩放时由 zoomedSV 门控不激活（交给各页内缩放 pan）。
  const readBase = useSharedValue(0);
  const longReadPan = useMemo(
    () =>
      Gesture.Pan()
        .minDistance(4000)
        .maxPointers(1)
        .onTouchesDown(() => {
          readBase.value = longScrollY.value;
        })
        .onTouchesMove((_e, mgr) => {
          if (!zoomedSV.value) mgr.activate();
        })
        .onUpdate((e) => {
          const target = readBase.value + e.translationY;
          longScrollY.value = Math.min(0, Math.max(-longScrollMax.value, target));
        })
        .onEnd((e) => {
          if (isDismissing.value) return;
          // 钉在边界（顶/底；含无可滚余量）不衰减——由退出手势接棒
          if (
            longScrollY.value <= -longScrollMax.value + 0.5 ||
            longScrollY.value >= -0.5 ||
            longScrollMax.value <= 0.5
          ) {
            return;
          }
          longScrollY.value = withDecay({ velocity: e.velocityY, clamp: [-longScrollMax.value, 0] });
        }),
    [zoomedSV, longScrollY, longScrollMax, readBase, isDismissing],
  );
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
      dragTranslateX.value = 0;
      dragTranslateY.value = 0;
      touchStartX.value = 0;
      touchStartY.value = 0;
      prevTransX.value = 0;
      prevTransY.value = 0;
      // 重置退场/飞回动画状态
      exitProgress.value = 0;
      exitFromX.value = 0;
      exitFromY.value = 0;
      exitFromScale.value = 1;
      exitToX.value = 0;
      exitToY.value = 0;
      exitToScale.value = 1;
      exitRadius.value = 0;
      isDismissing.value = false;
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
  }, [visible, initialIndex, overlayOpacity, dragTranslateX, dragTranslateY, touchStartX, touchStartY, prevTransX, prevTransY, enterScale, enterOpacity, exitProgress, exitFromX, exitFromY, exitFromScale, exitToX, exitToY, exitToScale, exitRadius, reduceMotion, isDismissing]);

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

  // 手势 worklet 镜像：当前页/总页数/长图态（随渲染刷新，手势 useMemo 不重建
  // 也能在 onTouchesMove / onEnd 里拿到新值）
  useEffect(() => {
    currentIdxSV.value = currentIndex;
    pageCountSV.value = images.length;
    isLongPageSV.value = isLongImageOf(currentIndex);
  }, [currentIndex, images.length, isLongImageOf, currentIdxSV, pageCountSV, isLongPageSV]);

  useEffect(() => {
    initialIdxSV.value = initialIndex;
  }, [initialIndex, initialIdxSV]);

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
    // 兜底强制内容透明：非减少动态路径退场动画已完成（progress 已到 1），
    // reduceMotion 路径是瞬间 onClose，这里直接压 0 保证宽限期不可见。
    enterOpacity.value = 0;
    exitProgress.value = 1;
    const t = setTimeout(() => setMounted(false), TEARDOWN_GRACE_MS);
    return () => clearTimeout(t);
  }, [visible, enterOpacity, exitProgress]);

  const topBarAnimStyle = useAnimatedStyle(() => {
    // 拖拽启动时顶栏/缩略条随拖拽距离淡出（Twitter 行为）；退场时随 progress 隐去
    const dragLen = Math.hypot(dragTranslateX.value, dragTranslateY.value);
    const dragFade = Math.min(dragLen / 140, 1);
    return { opacity: overlayOpacity.value * (1 - dragFade) * (1 - exitProgress.value) };
  });

  /**
   * 背景揭示（Twitter 拖拽关闭）：
   * - 黑色遮罩随拖拽距离渐隐（200pt 完全揭示），退场阶段随 progress 淡出
   * - 底层 GlassView 实时模糊后方信息流，透明度随拖拽渐显，退场阶段随 progress 全显
   * - 进场（enterOpacity）阶段同步淡入淡出
   */
  const bgScrimStyle = useAnimatedStyle(() => {
    const p = exitProgress.value;
    const dragLen = Math.hypot(dragTranslateX.value, dragTranslateY.value);
    const reveal = Math.min(dragLen / BG_REVEAL_DISTANCE, 1);
    return { opacity: (1 - reveal) * enterOpacity.value * (1 - p) };
  });

  const bgBlurStyle = useAnimatedStyle(() => {
    const p = exitProgress.value;
    const dragLen = Math.hypot(dragTranslateX.value, dragTranslateY.value);
    const reveal = Math.min(dragLen / BG_REVEAL_DISTANCE, 1);
    return {
      opacity: enterOpacity.value * (reveal + (1 - reveal) * p),
    };
  });

  /**
   * 内容统一动效：入场缩放 × 拖拽 2D 位移/缩小（1→0.72，320pt 全程）× 退场位移缩放。
   * 拖拽期与退场期共用一套共享值，单一 transform 计算避免多 style 数组覆盖。
   * 拖拽时同步增大圆角（Twitter 缩小图片的圆角收束感）；退场时随 progress 收束到
   * 缩略图级别圆角。退场 x/y/scale 全部由 exitProgress 同一驱动插值（双轴缓动
   * 不同 → 抛物线轨迹），保证 120fps 下各属性严格同步、无顿挫。
   */
  const contentStyle = useAnimatedStyle(() => {
    const p = exitProgress.value;
    if (p <= 0) {
      // ── 拖拽跟手态：2D 位移 + 按位移距离缩小 ──
      const dragLen = Math.hypot(dragTranslateX.value, dragTranslateY.value);
      const dragProgress = Math.min(dragLen / SHRINK_DISTANCE, 1);
      const dragFade = Math.min(dragLen / (SCREEN_HEIGHT * 0.6), 0.25);
      return {
        transform: [
          { translateX: dragTranslateX.value },
          { translateY: dragTranslateY.value },
          { scale: enterScale.value * (1 - dragProgress * DRAG_SHRINK_FACTOR) },
        ],
        borderRadius: 24 * dragProgress,
        borderCurve: 'continuous',
        opacity: enterOpacity.value * (1 - dragFade),
      };
    }
    // ── 退场态：单 progress 插值（x 快出慢收、y 缓起缓落 → 抛物线归位/飞出）──
    const ex = EXIT_EASE_X(p);
    const ey = EXIT_EASE_Y(p);
    const x = exitFromX.value + (exitToX.value - exitFromX.value) * ex;
    const y = exitFromY.value + (exitToY.value - exitFromY.value) * ey;
    const s = exitFromScale.value + (exitToScale.value - exitFromScale.value) * ey;
    return {
      transform: [
        { translateX: x },
        { translateY: y },
        { scale: s * enterScale.value },
      ],
      // 退场期圆角冻结在拖拽结束值（逐帧改 borderRadius 会重栅格化大图）
      borderRadius: exitRadius.value,
      borderCurve: 'continuous',
      opacity: enterOpacity.value * (1 - p),
    };
  });

  // iOS 26 Photos-style close: 单 progress 统一退场（原地缩小+淡出 180ms），
  // 与拖拽退场同一套动画系统。先切静态模式（轻量 Image 承担退场 transform，
  // 120fps 平滑）；卸载竞态由 TEARDOWN_GRACE_MS 宽限兜底。
  const closeViewer = useCallback(() => {
    if (reduceMotion) {
      onClose();
      return;
    }
    isDismissing.value = true;
    setStaticMode(true);
    exitFromX.value = dragTranslateX.value;
    exitFromY.value = dragTranslateY.value;
    exitFromScale.value = 1;
    exitToX.value = dragTranslateX.value;
    exitToY.value = dragTranslateY.value;
    exitToScale.value = 0.8;
    exitRadius.value = 0;
    exitProgress.value = withTiming(1, { duration: DURATION.exit, easing: EASE_OUT }, (finished) => {
      if (finished) runOnJS(onClose)();
    });
  }, [reduceMotion, onClose, isDismissing, setStaticMode, dragTranslateX, dragTranslateY, exitFromX, exitFromY, exitFromScale, exitToX, exitToY, exitToScale, exitRadius, exitProgress]);

// 交互式拖拽关闭（iOS Photos 风格，2026-08-29 重构 v2）：
// - 手势本体稳定（门控全走共享值，不随 isZoomed 重建——快速捏合不被掐断）；
// - 手动激活仲裁（minDistance 关闭自动激活，onTouchesMove 判定后显式 activate）：
//   普通页任意方向纵向可退；长图页（阅读滚动 pan 驱动）仅滚动边界可退——
//   顶部下拉 / 底部上拉（滚动区内纵向手势归阅读滚动，不抢）；
//   PagerView 翻不了的方向（首页右拉 / 末页左拉）横向也可退（左缘滑动退出）。
// - 2D 跟手：激活后 X/Y 同步跟随手指（增量累计，跨滚动区到边界不跳变），
//   拖动中按距离缩小（跟手缩小，0.25@280pt）。
// - 放开时距离或速度过阈值 → 有源矩形则沿抛物线“飞回缩略图”（起点=手势
//   当前位置，终点=源矩形，360ms 减速归位），否则沿手势 2D 方向飞出；
//   未过阈值 → 弹簧回弹。缩放态（zoomedSV）下禁用，交给页内缩放 pan。
const dismissGesture = useMemo(
    () =>
      Gesture.Pan()
        .minDistance(4000)
        .maxPointers(1)
        // 长图页与阅读滚动 pan 同流（RNGH-RNGH）：滚动/退出按边界仲裁
        .simultaneousWithExternalGesture(longReadPan)
        .onTouchesDown((e) => {
          if (zoomedSV.value) return;
          const t = e.changedTouches[0];
          touchStartX.value = t.x;
          touchStartY.value = t.y;
        })
        .onTouchesMove((e, mgr) => {
          if (isDismissing.value || zoomedSV.value) return;
          const dx = e.changedTouches[0].x - touchStartX.value;
          const dy = e.changedTouches[0].y - touchStartY.value;
          let yGo = false;
          if (isLongPageSV.value) {
            // 长图页：仅手指方向会把滚动钉在边界（顶下拉/底上拉）时才接管退出
            const atTop = longScrollY.value <= 0.5;
            const atBottom = longScrollY.value >= longScrollMax.value - 0.5;
            yGo = Math.abs(dy) >= 14 && ((dy > 0 && atTop) || (dy < 0 && atBottom));
          } else {
            yGo = Math.abs(dy) >= 14;
          }
          // 横向：PagerView 无法翻页的方向（首页右拉/末页左拉）接管为退出
          const xGo =
            Math.abs(dx) >= 14 &&
            ((dx > 0 && currentIdxSV.value <= 0) ||
              (dx < 0 && currentIdxSV.value >= pageCountSV.value - 1));
          if (yGo || xGo) mgr.activate();
        })
        .onUpdate((e) => {
          if (isDismissing.value || zoomedSV.value) return;
          // 增量跟手：滚动区内的位移不累计（容器归 0、内容正常滚动），
          // 滚动到边界后继续拉时从 0 起跟——跨区全程无跳变。
          const dX = e.translationX - prevTransX.value;
          const dY = e.translationY - prevTransY.value;
          prevTransX.value = e.translationX;
          prevTransY.value = e.translationY;
          let followY = true;
          if (isLongPageSV.value) {
            const atTop = longScrollY.value <= 0.5;
            const atBottom = longScrollY.value >= longScrollMax.value - 0.5;
            followY =
              (e.translationY > 2 && atTop) ||
              (e.translationY < -2 && atBottom) ||
              (atTop && atBottom);
          }
          dragTranslateX.value += dX;
          if (followY) dragTranslateY.value += dY;
          else dragTranslateY.value = 0;
        })
        .onEnd((e) => {
          if (isDismissing.value || zoomedSV.value) return;
          const dragLen = Math.hypot(dragTranslateX.value, dragTranslateY.value);
          const beyondThreshold = dragLen > 140 || Math.abs(e.velocityY) > 900;
          if (!beyondThreshold) {
            // 未过阈值 → 弹簧回弹（X/Y 一起回）
            dragTranslateX.value = withSpring(0, MOMENTUM);
            dragTranslateY.value = withSpring(0, MOMENTUM);
            return;
          }
          isDismissing.value = true;
          if (reduceMotionSV.value) {
            runOnJS(onClose)();
            return;
          }
          const dragProgress = Math.min(dragLen / SHRINK_DISTANCE, 1);
          exitFromX.value = dragTranslateX.value;
          exitFromY.value = dragTranslateY.value;
          exitFromScale.value = 1 - dragProgress * DRAG_SHRINK_FACTOR;
          exitRadius.value = 24 * dragProgress;
          // 切除 PagerView（SwiftUI TabView）→ 静态大图：同 URI + imageWarm 免
          // 过渡，换图像素级无感；退场 transform 落在轻量 Image 上，120fps 平滑
          runOnJS(setStaticMode)(true);
          if (hasFlyTarget.value && currentIdxSV.value === initialIdxSV.value) {
            // 飞回被点击缩略图：从手势当前位置（含横向跟手分量）沿抛物线归位；
            // 背景同步淡出，露出列表缩略图
            exitToX.value = flyTargetX.value;
            exitToY.value = flyTargetY.value;
            exitToScale.value = flyTargetScale.value;
            exitProgress.value = withTiming(
              1,
              { duration: FLY_BACK_MS, easing: EASE_OUT },
              (finished) => {
                if (finished) runOnJS(onClose)();
              },
            );
          } else {
            // 无源矩形（如 TweetCard 信息流图）：沿手势 2D 方向飞出
            // （方向跟随手势向量，不再固定上下），结束后卸载
            let dx = e.translationX;
            let dy = e.translationY;
            if (Math.abs(dx) < 8 && Math.abs(dy) < 8) {
              dx = e.velocityX * 0.05;
              dy = e.velocityY * 0.05;
            }
            const len = Math.hypot(dx, dy);
            if (len < 1) {
              dx = 0;
              dy = 1;
            } else {
              dx /= len;
              dy /= len;
            }
            exitToX.value = dx * SCREEN_WIDTH * 1.4;
            exitToY.value = dy * SCREEN_HEIGHT * 1.4;
            exitToScale.value = 0.82;
            exitProgress.value = withTiming(
              1,
              { duration: EXIT_FLING_MS, easing: EASE_OUT },
              (finished) => {
                if (finished) runOnJS(onClose)();
              },
            );
          }
        }),
    [
      onClose,
      reduceMotionSV,
      zoomedSV,
      longReadPan,
      longScrollY,
      longScrollMax,
      isLongPageSV,
      currentIdxSV,
      pageCountSV,
      initialIdxSV,
      touchStartX,
      touchStartY,
      prevTransX,
      prevTransY,
      dragTranslateX,
      dragTranslateY,
      isDismissing,
      hasFlyTarget,
      flyTargetX,
      flyTargetY,
      flyTargetScale,
      exitFromX,
      exitFromY,
      exitFromScale,
      exitToX,
      exitToY,
      exitToScale,
      exitProgress,
      exitRadius,
      setStaticMode,
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
            /* 静态模式：退场动画由当前页静态大图承担（SwiftUI TabView 变换是
               卡顿源）；URI 与页面实际显示档一致 + imageWarm 免过渡 → 换树无感 */
            <Image
              source={{ uri: displayUriOf(currentIndex, images[currentIndex]) }}
              style={styles.pager}
              contentFit="contain"
              cachePolicy="memory-disk"
              transition={isImageWarm(displayUriOf(currentIndex, images[currentIndex])) ? 0 : 200}
              onLoad={() => markImageWarm(displayUriOf(currentIndex, images[currentIndex]))}
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
            {pages.map((page) => {
              const longPage = isLongImageOf(page.index);
              const pageMeta = imageMeta?.[page.index];
              return (
              <View key={String(page.index)} collapsable={false} style={styles.imagePage}>
                {/* 大图长按：在长按位置弹出选项框（无放大预览，页面本身已是大图） */}
                <TiebaPhotoContextMenu
                  fullUrl={imageOrigins?.[page.index] ?? page.uri}
                  previewEnabled={false}
                  actions={buildPageActions(page.index)}
                  onAction={(actionId) => handlePageMenuAction(page.index, actionId)}
                  style={StyleSheet.absoluteFill}
                >
                  {longPage ? (
                    /* 长图阅读模式（2026-08-29）：小档秒出 + 原图后台加载完淡入；
                       fit-width + 单指下滑读完；捏合/双击缩放。修复长图默认直接
                       解码 originSrc 巨图导致的整机冻结。 */
                    <LongImageView
                      baseUri={images[page.index]}
                      originUri={imageOrigins?.[page.index]}
                      imageWidth={pageMeta?.width}
                      imageHeight={pageMeta?.height}
                      zoomed={isZoomed}
                      onSingleTap={toggleUI}
                      onZoomChange={setIsZoomed}
                      readPan={longReadPan}
                      scrollY={longScrollY}
                      scrollMax={longScrollMax}
                      onLoadStart={() => {
                        if (page.uri !== images[page.index]) {
                          setOriginLoading((prev) => ({ ...prev, [page.index]: true }));
                        }
                      }}
                      onLoadEnd={() => {
                        setOriginLoading((prev) => ({ ...prev, [page.index]: false }));
                      }}
                    />
                  ) : (
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
                  )}
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
              );
            })}
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
