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
  useWindowDimensions,
} from 'react-native';
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  useAnimatedReaction,
  withSpring,
  withTiming,
  withDecay,
  FadeIn,
  FadeOut,
  withDelay,
  cancelAnimation,
  runOnJS,
  Easing,
  type SharedValue,
} from 'react-native-reanimated';
import { Gesture, GestureDetector } from 'react-native-gesture-handler';
import PagerView, {
  type PageScrollStateChangedNativeEvent,
  type PagerViewOnPageScrollEvent,
  type PagerViewOnPageSelectedEvent,
} from 'react-native-pager-view';
import { Image } from 'expo-image';

import { SymbolView } from '@/components/ui/SymbolView';
import { GlassView } from '@/components/ui/GlassView';
import { hapticForScene } from '@/theme/hapticsMap';
import { saveImageToGallery, shareFile } from '@/services/media';

import { SafeAreaProvider, useSafeAreaInsets } from 'react-native-safe-area-context';
import { useAppPreference } from '@/hooks/useAppPreference';
import { useReducedMotion } from '@/hooks/useReducedMotion';
import type { ImageSourceFrame, ViewerImageMeta } from '@/hooks/useImageViewer';
import { LongImageView, ZoomableImage, ThumbnailCell } from '@/components/imageviewer/parts';
import { viewerStyles as styles } from '@/components/imageviewer/styles';
import { revealOnOpen, getArmedFramesSnapshot, flushHShiftOnOpen } from '@/hooks/useViewerSourceReveal';
import { useAuthStore } from '@/stores/authStore';
import { TiebaPhotoContextMenu } from '../../modules/tieba-native/src/TiebaPhotoContextMenu';
import { TiebaNative } from '../../modules/tieba-native/src/TiebaNative';
import type { ScrollableRef } from 'react-native-zoom-reanimated';
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
/** 拖拽缩小全程：180pt 时图片缩至约 0.7（跟手缩小，松手后经退场动画归位）。
    2026-08-31：280→180 / 系数 0.25→0.3——旧值太钝，普通拖动（50-150pt）
    缩小几乎无感（用户反馈"跟手没有缩小过程"）。 */
const SHRINK_DISTANCE = 180;
/** 拖拽缩小系数（180pt 时 1 → 0.7） */
const DRAG_SHRINK_FACTOR = 0.3;
/** Twitter 式跟手限位（2026-08-31 v1）：图片不无限随手指移动——
    纵向最多跟手屏高 38%，横向最多 80pt；超过后图片"钉住"，背景揭示与
    缩放继续由 raw 累计驱动（Twitter 行为）。 */
const MAX_DRAG_Y_FACTOR = 0.38;
const MAX_DRAG_X = 80;
/** 退场动态时长（飞出按剩余距离/松手速度，clamp [350,1100]ms，见 prepareFlyOut） */

/** 档1（唯一）飞出：沿松手方向直线飞出的目标与时长（模块级纯函数，**显式 worklet**——
    在手势 worklet 内被调用：Reanimated 转换器对跨线程调用的非标记函数
    运行时可能抛 "non-worklet function" 异常，导致退场动画不启动、图片
    卡在松手位置（2026-08-31 用户实测卡住）。）
    方向=位移（过小取抛速方向）；时长与剩余距离/松手速度挂钩，
    参与计算的速度封顶 1400pt/s，clamp [350, 1100]ms（2026-08-31 定案档）。 */
function prepareFlyOut(
  e: {
    translationX: number;
    translationY: number;
    velocityX: number;
    velocityY: number;
  },
  fromX: number,
  fromY: number,
): { toX: number; toY: number; exitDuration: number } {
  'worklet';
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
  // 优雅退出（2026-08-31 用户："太慢，要优雅不要慢速"）：
  // - 飞出目标 0.6×屏（原来 1.0：尾部屏外空飞是"慢"的主因——配合
  //   watchdog 出屏判定，视觉更快完全出屏）；
  // - 低速兜底下限 180→400（慢拖不再被 clamp 到 950ms+）；
  // - 时长上限 1100/950→600ms，下限 300ms——全程 ~450-600ms 的利落节奏。
  const toX = dx * SCREEN_WIDTH * 0.6;
  const toY = dy * SCREEN_HEIGHT * 0.6;
  const travel = Math.hypot(toX - fromX, toY - fromY);
  const speed = Math.min(Math.max(Math.hypot(e.velocityX, e.velocityY), 400) * 0.5, 900);
  const exitDuration = Math.min(600, Math.max(300, (travel / speed) * 1000));
  return { toX, toY, exitDuration };
}
/** 相册转场统一时长：进入展开/飞回缩略图/飞出/顶栏关闭全部 300ms
    （iOS Photos：进入/退出同为轻快 0.3s，图片全程清晰无透明度变化） */
const VIEWER_TRANSITION_MS = 300;
/** 飞回/退场统一使用 EASE_OUT——x/y/scale 同曲线 → 轨迹为直线（iOS Photos 行为：
    无抛物线；松手后沿当前方向直线运动。2026-08-30 用户观察定案） */
// 关闭后延迟拆除的宽限期：给 PagerView 内部减速/手势收尾的时间，避免
// SwiftUI TabView 在动画途中被整树卸载（真机闪退），随后再真正卸载 Modal。
// 2026-08-31：400→100ms——两条关闭路径（飞回/淡出动画完成回调）触发
// onClose 时 PagerView 均已静止，宽限只需覆盖 React 重新渲染与布局收尾；
// 400ms 会让动画结束后"定住一下"且屏幕不可触摸（用户实测反馈）。
const TEARDOWN_GRACE_MS = 100;

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
  /** 逐图预览档 URL（列表刚显示的小档；与 images 下标一一对应，可缺省）。
      PagerView 普通图页（ZoomableImage）与 overlay 动画层都用它垫底秒显：
      大图档（bigPic/原图）首次进查看器缓存 miss，小档（srcPic）在列表
      展示时已入缓存，翻页/拖拽全程有图。 */
  imagePreviews?: (string | undefined)[];
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
  // 飞回原位目标（2026-08-31 v1 重新启用）：点击缩略图的屏幕矩形；
  // 缺省（头像/楼中楼引用等 3 参调用点）时退化为缩略条格/飞出。
  sourceFrame,
  imageOrigins,
  imagePreviews,
  contextTitle,
  imageMeta,
}: ImageViewerProps) {
  const [currentIndex, setCurrentIndex] = useState(initialIndex);
  const [showUI, setShowUI] = useState(true);
  const [downloadProgress, setDownloadProgress] = useState(false);
  // 保存成功提示（2026-08-31 用户："保存 toast 显示在左上角，应和点赞成功
  // 一样在屏幕底部、简洁地显示保存成功"）：底部深色药丸（同 ToastHost 的
  // 药丸样式）——大图 Modal 内自渲染（外层 ToastHost 被 Modal 盖住）
  const [savePill, setSavePill] = useState<string | null>(null);
  const savePillTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const showSavePill = useCallback((msg: string) => {
    setSavePill(msg);
    if (savePillTimerRef.current) clearTimeout(savePillTimerRef.current);
    savePillTimerRef.current = setTimeout(() => setSavePill(null), 2200);
  }, []);
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
  // Worklet 可读镜像（退出手势 onEnd 在 UI 线程，不能读 React state/insets）：
  // 飞回目标判定用——底部缩略条几何、打开时的源矩形与初始页下标
  const bottomInsetRef = useRef(0);
  bottomInsetRef.current = insets.bottom;
  // 退场判定共享值镜像（2026-08-31）：⚠️ 手势 worklet 读 JS ref
  // （sourceFrameRef / openInitialIndexRef 等）拿到的是 useMemo 创建时的
  // 冻结快照——日志实证 open 页=1 时 onEnd 读到 openIdx=0 → 点开第 2 张图
  // /翻页永远走条格档（用户复现"多图只有第一张能成功"）。判定数据在
  // 打开/reveal/滚动时同步进共享值，worklet 直读实时值。
  const srcFrameSV = useSharedValue<ImageSourceFrame | null>(null);
  const openIdxSV = useSharedValue(initialIndex);
  const thumbXSV = useSharedValue(0);
  const bottomInsetSV = useSharedValue(16);
  /** 横滑带整组帧镜像（打开时初始化 + reveal 修正后更新）：翻页退出按
      currentIdx 取对应帧，飞回横滑带里原图位置（2026-08-31 用户要求） */
  const flybackFramesSV = useSharedValue<ImageSourceFrame[] | null>(null);
  useEffect(() => {
    bottomInsetSV.value = insets.bottom; // Worklet 镜像（手势用）
  }, [insets.bottom, bottomInsetSV]);
  const sourceFrameRef = useRef<ImageSourceFrame | null>(null);
  const openInitialIndexRef = useRef(initialIndex);
  const pagerRef = useRef<PagerView>(null);
  // 照片级图库滑动适配器（react-native-zoom-reanimated parentScrollRef）：
  // 库 overflow 溢出时按 offset 换算目标页，驱动原生 PagerView 切页。
  // staticMode/未挂载时 pagerRef.current 为空 → 库侧守卫自然忽略。
  // **不要用模块级 SCREEN_WIDTH 换算页**（2026-08-30 日志实证：Dim 常量
  // 被转屏状态污染成 ~874pt 后，库请求 offset=401（1×402-1pt 微溢出）竟
  // 被 round 成第 0 页 → setPage(0) → 「两指准备放大就跳回第一张」）。
  // 用 useWindowDimensions 实时宽 + 就近页容差判定：
  // - 页面 = round(offset / liveW)
  // - |offset 与最近整页中心| 偏差 < 16% liveW → 视为同页微溢出/回弹，
  //   不切页（捏合两指时库会持续发当前页 ± 数 pt 的漂移请求）
  // 只响应确凿跨页请求。
  const { width: liveWindowWidth } = useWindowDimensions();
  const liveWRef = useRef(liveWindowWidth);
  liveWRef.current = liveWindowWidth;
  const currentIdxRef = useRef(currentIndex);
  currentIdxRef.current = currentIndex;
  const imagesRef = useRef(images);
  imagesRef.current = images;
  // 全量挂载（2026-08-31 起无窗口化）：adapter 直接按绝对下标切页，
  // 不再有窗内局部索引/窗外重建的分支——窗口重建与原生滚动竞争导致的
  // offset 错位（「高速滑动黑屏 + 只能往回滑」）从机制上消失。
  const galleryScrollRef = useRef<ScrollableRef>({
    scrollToOffset: ({ offset, animated }) => {
      const pager = pagerRef.current;
      if (!pager) return;
      const cur = currentIdxRef.current;
      const w = liveWRef.current || SCREEN_WIDTH;
      const pageFloat = offset / w;
      const nearest = Math.round(pageFloat);
      const frac = Math.abs(pageFloat - nearest);
      if (frac >= 0.16) return; // 半途位置（异常请求），忽略
      if (__DEV__) {
        console.warn(
          '[viewer-dbg]',
          new Date().toISOString().slice(11, 23),
          'gal-scroll',
          { offset: Math.round(offset), idx: nearest, cur, animated, w },
        );
      }
      if (nearest === cur) return;
      if (nearest < 0 || nearest >= imagesRef.current.length) return;
      if (animated === false) pager.setPageWithoutAnimation(nearest);
      else pager.setPage(nearest);
    },
  });
  const thumbnailRef = useRef<ScrollView>(null);
  // 缩略条横向滚动偏移（onScroll 记录；档2 飞回目标需按当前可见位置换算——
  // 条会滚动到当前格居中，固定几何在 9 图时会把目标算到屏外）
  const thumbnailScrollXRef = useRef(0);

  // ── 转场卡死取证（2026-08-30 临时埋点，验完即删）──
  // 复现后 Metro 日志看 [viewer-dbg] 序列：
  // - 事件行（open/flyTarget/enter-done/close-x/drag-*）带毫秒时间戳 → 时序
  // - probe 行（JS 线程每 100ms 采样）→ 进度值停住=动画推进停止；中断=JS 卡死
  // - frame 行（UI 线程 useFrameCallback 每 8 帧汇总帧间隔）→ avgMs≈16.7 满帧，
  //   暴涨段=掉帧发生的位置；frame 行停=UI 线程卡死
  // 取证日志通道（2026-08-30 转场卡死埋点）：Release 零输出（__DEV__ 门控），
  // dev 构建保留供真机排障；验完即删。
  const dbg = useCallback((...a: unknown[]) => {
    if (__DEV__) console.warn('[viewer-dbg]', new Date().toISOString().slice(11, 23), ...a);
  }, []);
  const lastRenderLogRef = useRef(0);

  // Watermark preference
  const imageWatermarkEnabled = useAppPreference('imageWatermarkEnabled', false);
  const imageWatermark = useAppPreference('imageWatermark', 'none');
  const account = useAuthStore((s) => s.account);
  const { reduceMotion } = useReducedMotion();

  // 长图判据：纯几何——fit-width 显示高度明显超过屏高才进阅读模式。服务端
  // isLongPic 标记对"稍高于屏"的图会过宽路由成阅读模式（顶部顶状态栏、
  // 底部被裁，用户 2026-08-29 反馈"部分图片靠上显示"）；有真实尺寸时以
  // 几何为准，尺寸未知才信服务端标记。阈值 1.3 倍屏高：仅"明显长"的图进
  // 阅读模式，略超屏的普通图保持捏合缩放浏览（用户 2026-08-30 反馈：未标
  // 长图的图被误判成长图、上下滑退不出）。
  const isLongImageOf = useCallback(
    (index: number): boolean => {
      const meta = imageMeta?.[index];
      if (!meta) return false;
      const w = meta.width;
      const h = meta.height;
      if (w > 0 && h > 0) {
        return (SCREEN_WIDTH * h) / w > SCREEN_HEIGHT * 1.3;
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

  // ── 全量挂载（2026-08-31 去窗口化）──
  // 窗口化（±1 页 + 窗口重建）在高速滑动时与原生滚动竞争：reload +
  // setPageWithoutAnimation 打断减速 → contentOffset 错位（视觉黑屏 +
  // 往前滑越界回弹只能往回）——真机复现根因。改为 PagerView 挂全部
  // images（cell 为空 View 零成本，图片仍按 active 单页解码，内存策略
  // 不变），滑动全程无重建、无对齐调用。
  // viewingIndex = 滑动途中视觉当前页（onPageScroll 实时翻转 → 新页
  // 立即 active 出图，不再等 settle 结束才亮）；currentIndex 仍由
  // settle 门控在减速结束后应用（页码/预取/触感对齐）。
  const [viewingIndex, setViewingIndex] = useState(initialIndex);

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
  // 跟手原始累计（不随限位钳制）：驱动背景揭示/缩小阈值与退出判定——
  // 图片拖到限位"钉住"后，progress 仍随手指继续（Twitter 行为）
  const dragRawY = useSharedValue(0);
  // Entrance animation for the image (scale 0.95→1, opacity 0→1)
  const enterOpacity = useSharedValue(1);
  // 进入展开起点（Photos 同款：有源矩形时从缩略图位置/尺寸放大到全屏；
  // 无源矩形退化为 0.95 居中淡入）。contentStyle 与 dragTranslate 相加。
  // 2026-08-31：进入展开动画已删（简化方案），enterTrans*/enterScale 恒
  // 0/1 无写入点，contentStyle 因子已移除——此注释块仅保留历史说明。
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
  // 手势仲裁：起始点 + 上一帧位移（onTouchesMove 手动激活判定 + 增量跟手）
  const touchStartX = useSharedValue(0);
  const touchStartY = useSharedValue(0);
  const prevTransX = useSharedValue(0);
  const prevTransY = useSharedValue(0);
  // 手势脉冲（页面级 zoomGestureLastTime 变化时 +1，UI 线程）：驱动顶栏
  // 自动收起——手势结束后 2.6s 渐隐（iOS Photos 行为），再手势重新计时。
  // 手势 worklet 只读镜像（手势 useMemo 不随渲染重建，直接读共享值拿新状态）
  const currentIdxSV = useSharedValue(initialIndex);
  const pageCountSV = useSharedValue(images.length);
  const initialIdxSV = useSharedValue(initialIndex);
  const isLongPageSV = useSharedValue(false);
  // 缩放态镜像：UI 线程直读——页面级钩子的 isZoomedIn 经 active 门控镜像
  // 写入（无 JS 往返，快速捏合不被中断）。退出手势/阅读 pan 的门控读本值。
  const zoomedSV = useSharedValue(false);
  // 手势脉冲（页面级 zoomGestureLastTime 变化时 +1，UI 线程）：驱动顶栏
  // 自动收起——手势结束后 2.6s 渐隐（iOS Photos 行为），再手势重新计时。
  const gesturePulse = useSharedValue(0);
  const uiVisibleSV = useSharedValue(showUI);
  useEffect(() => {
    uiVisibleSV.value = showUI;
  }, [showUI, uiVisibleSV]);
  // 手势结束 → 排一个延迟收起（仅 UI 可见且未在退场时）；单击 toggle 走
  // 既有 showUI 效果（cancelAnimation + 重置 opacity，自动取消待执行收起）。
  useAnimatedReaction(
    () => gesturePulse.value,
    (p, prev) => {
      if (p === prev) return;
      if (uiVisibleSV.value && exitProgress.value === 0) {
        overlayOpacity.value = withDelay(2600, withTiming(0, { duration: 220 }));
      }
    },
  );

  // ---------- 飞回源缩略图（iOS Photos 式交互关闭）----------
  // 飞回目标在打开时按 sourceFrame 预算好，手势 onEnd（UI 线程）直接取用；
  // 动画本体由上方 exitProgress 统一驱动，这里只存目标矩形。
  // 防抖：退场动画进行中忽略新触摸，避免二次拖拽劫持动画。
  const isDismissing = useSharedValue(false);

  // 长图页滚动状态查表（2026-08-31 P0 修复）：每张长图页各自持有 y/max，
  // 挂载时注册进本表；readPan/退出手势按当前页（currentIdxSV）读对应组。
  // 旧实现所有长图页写同一对共享值——全量挂载后多长图页必互踩（边界判定
  // 错乱：上下滑误触发退出/滚不到底）。
  const scrollStatesRef = useRef<Record<number, { y: SharedValue<number>; max: SharedValue<number> }>>({});
  const attachScrollState = useCallback(
    (i: number, y: SharedValue<number>, max: SharedValue<number>) => {
      scrollStatesRef.current[i] = { y, max };
    },
    [],
  );
  const detachScrollState = useCallback((i: number) => {
    delete scrollStatesRef.current[i];
  }, []);
  // 阅读滚动基线（手势激活期间单值安全：同一时刻只有一个长图页的手势活跃）
  const readBase = useSharedValue(0);
  const longReadPan = useMemo(
    () =>
      Gesture.Pan()
        .minDistance(4000)
        .maxPointers(1)
        .onTouchesDown(() => {
          const st = scrollStatesRef.current[currentIdxSV.value];
          if (st) readBase.value = st.y.value;
        })
        .onTouchesMove((_e, mgr) => {
          if (!zoomedSV.value) mgr.activate();
        })
        .onUpdate((e) => {
          const st = scrollStatesRef.current[currentIdxSV.value];
          if (!st) return;
          const target = readBase.value + e.translationY;
          st.y.value = Math.min(0, Math.max(-st.max.value, target));
        })
        .onEnd((e) => {
          if (isDismissing.value) return;
          const st = scrollStatesRef.current[currentIdxSV.value];
          if (!st) return;
          // 钉在边界（顶/底；含无可滚余量）不衰减——由退出手势接棒
          if (st.y.value <= -st.max.value + 0.5 || st.y.value >= -0.5 || st.max.value <= 0.5) {
            return;
          }
          st.y.value = withDecay({ velocity: e.velocityY, clamp: [-st.max.value, 0] });
        }),
    [zoomedSV, readBase, isDismissing],
  );
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
      setViewingIndex(initialIndex);
      sourceFrameRef.current = sourceFrame ?? null;
      srcFrameSV.value = sourceFrame ?? null;
      flybackFramesSV.value = getArmedFramesSnapshot();
      if (__DEV__) {
        console.warn('[hshift] snapshot', {
          n: flybackFramesSV.value?.length ?? 0,
          f0x: flybackFramesSV.value ? Math.round(flybackFramesSV.value[0].x) : -1,
          srcX: sourceFrame ? Math.round(sourceFrame.x) : -1,
        });
      }
      openInitialIndexRef.current = initialIndex;
      openIdxSV.value = initialIndex;
      setShowUI(true);
      setIsZoomed(false);
      overlayOpacity.value = 1;
      dragTranslateX.value = 0;
      dragTranslateY.value = 0;
      dragRawY.value = 0;
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
      isDismissing.value = false;
      // 简化方案（2026-08-30 用户决定）：移除进入展开/飞回动画——PagerView
      // 直显，不再有 overlay 进入动画（多轮实证 Reanimated withTiming 在
      // 本环境不稳定：覆盖竞态/伪帧立即完成/worklet 启动不推进）。
      setStaticMode(false);
      // 容器淡入（背景渐黑 + 内容渐现）：enterOpacity 同时驱动 modalContainer
      // 与黑色遮罩——进入 0→1（350ms 舒缓，JS 线程启动=已验证成功路径）；
      // reduceMotion / 关闭态直接落位。**必须每次打开重置**：teardown 会把
      // enterOpacity 压 0，不重置则第二次打开背景不黑（用户实测）。
      if (reduceMotion) {
        enterOpacity.value = 1;
      } else {
        enterOpacity.value = 0;
        enterOpacity.value = withTiming(1, { duration: 350, easing: EASE_OUT });
      }
      dbg('open', {
        initialIndex,
        isLong: isLongImageOf(initialIndex),
        reduceMotion,
      });
      // 打开时自动揭示被遮挡的源图（2026-08-31）：等淡入完成、PagerView 稳定
      // 后触发列表平滑滚动——用户拖动退出时背景已就位（此前在 teardown 后
      // 瞬间滚动，观感生硬）。返回值 = 移位后的可见源矩形，覆盖飞回预算
      // frame，保证拖动退出飞回的目标与滚动后的卡片位置一致。
      const revealTimer = setTimeout(() => {
        // 进入动画（350ms 淡入）已完成、背景被 Modal 完全遮住后才做后台
        // 移位——用户："大图模式下图片显示到位了才移动，如果还在加载动画
        // 瞬时移动，动画会极度错乱"。横滑带此时瞬间移正（后台不可见），
        // 用户拖动退出时已就位。
        flushHShiftOnOpen();
        const revealed = revealOnOpen();
        if (revealed) {
          sourceFrameRef.current = revealed.frame;
          srcFrameSV.value = revealed.frame;
          flybackFramesSV.value = revealed.frames;
        }
      }, 400);
      return () => clearTimeout(revealTimer);
    }
    // visible=false：无需清理（revealTimer 已被上面 return 的 cleanup 处理；
    // 若在 400ms 内关闭，cleanup 会在依赖变化时清掉 timer）
    return undefined;
  }, [visible, initialIndex, overlayOpacity, dragTranslateX, dragTranslateY, touchStartX, touchStartY, prevTransX, prevTransY, exitProgress, exitFromX, exitFromY, exitFromScale, exitToX, exitToY, exitToScale, enterOpacity, reduceMotion, isDismissing, setStaticMode, isLongImageOf, dbg]);


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

  // Scroll thumbnail strip to current item（跟手：用视觉页 viewingIndex）
  useEffect(() => {
    const thumbWidth = 56 + 6;
    const targetX = Math.max(0, viewingIndex * thumbWidth - SCREEN_WIDTH / 2 + thumbWidth / 2);
    // 预填滚动目标偏移（2026-08-31）：scrollTo(animated) 期间 onScroll 未到
    // 达时，退出手势按最新目标近似——防档2 条格几何用陈旧偏移算出屏外
    thumbnailScrollXRef.current = targetX;
    thumbXSV.value = targetX;
    thumbnailRef.current?.scrollTo({ x: targetX, animated: true });
  }, [viewingIndex]);

  // ── 相邻页大图预取（2026-08-31 连续滑动黑屏根治 v2）──
  // 快速滑动时 PagerView（UICollectionView paging）会直接跳过中间页，且
  // 视图层发起的下载随页卸载被取消——滑多了就整页停在黑屏（无请求、无
  // 报错）。预取走 expo-image 的 SDWebImagePrefetcher 独立通道，不随视图
  // 生命周期取消；预取落盘后页面激活即命中缓存秒显。
  // v2 三条通道：
  // 1. 打开即全量补漏预取（未预取过的页排队下载，SDWebImagePrefetcher
  //    自带缓存跳过/去重）——保证任何速度滑动到任何页都有缓存；
  // 2. onPageScroll 方向感知预取（滑动途中 position+offset 实时上报，
  //    100ms 节流）——跳过中间页时途经页也被预取；
  // 3. settled 后（currentIndex 变化）±3 窗口补漏（防抖 150ms 合并连滑）。
  const prefetchedRef = useRef<Set<string>>(new Set());
  const prefetchUris = useCallback(
    (uris: string[]) => {
      const fresh = uris.filter((u) => u && !prefetchedRef.current.has(u));
      if (fresh.length === 0) return;
      fresh.forEach((u) => prefetchedRef.current.add(u));
      dbg('prefetch', { n: fresh.length, first: fresh[0]?.slice(-24) });
      void Image.prefetch(fresh).then((ok) => {
        if (!ok) dbg('prefetch-incomplete');
      });
    },
    [dbg],
  );
  const prefetchWindow = useCallback(
    (center: number) => {
      const targets: string[] = [];
      for (const i of [center - 3, center - 2, center - 1, center + 1, center + 2, center + 3]) {
        if (i < 0 || i >= images.length) continue;
        const u = displayUriOf(i, images[i]);
        if (u) targets.push(u);
      }
      prefetchUris(targets);
    },
    [images, displayUriOf, prefetchUris],
  );

  // 通道 1：打开即全量补漏（低优先级队列顺次下载，不阻塞 UI）
  useEffect(() => {
    if (!visible) return;
    prefetchUris(images.map((_, i) => displayUriOf(i, images[i])));
  }, [visible, images, displayUriOf, prefetchUris]);

  // 通道 2：滑动途中方向感知预取 + 实时翻转 viewingIndex（100ms 节流；
  // event 每帧触发）。viewingIndex 让视觉新页立即 active 出图（缓存秒显），
  // 不再等 settle 结束才亮（旧窗口化版本滑动途中停留页=非 active 空页=黑屏）。
  // 防渲染风暴：passing 未变（同页回弹/微漂）不 setState——滑动中只在
  // 真正换页时触发一次重渲染（2026-08-31 审查 P2）。
  const lastPageScrollRef = useRef(0);
  const prevViewingRef = useRef(-1);
  const handlePageScroll = useCallback(
    (e: PagerViewOnPageScrollEvent) => {
      const { position, offset } = e.nativeEvent;
      const now = Date.now();
      if (now - lastPageScrollRef.current < 100) return;
      lastPageScrollRef.current = now;
      const passing = position + (offset >= 0.5 ? 1 : 0);
      dbg('page-scroll', { position, offset: Math.round(offset * 100) / 100 });
      if (passing !== prevViewingRef.current) {
        prevViewingRef.current = passing;
        setViewingIndex(passing);
      }
      prefetchWindow(passing);
    },
    [prefetchWindow, dbg],
  );

  // 通道 3：settled 后 ±3 补漏
  const prefetchTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const prefetchAdjacent = useCallback(() => {
    prefetchWindow(currentIndex);
  }, [currentIndex, prefetchWindow]);

  useEffect(() => {
    if (!visible) return;
    if (prefetchTimerRef.current) clearTimeout(prefetchTimerRef.current);
    prefetchTimerRef.current = setTimeout(prefetchAdjacent, 150);
    return () => {
      if (prefetchTimerRef.current) clearTimeout(prefetchTimerRef.current);
    };
  }, [visible, currentIndex, prefetchAdjacent]);

  // 全量挂载后无需窗口对齐（initialPage 已定位，滑动纯原生无重建）。

  // 关闭延迟拆除：visible=false 后保留 Modal 挂载 TEARDOWN_GRACE_MS，
  // 让 PagerView 内部 scroll view 的减速/手势彻底结束后再整树卸载
  // （真机实测：退出大图查看器立刻卸载会闪退；宽限期内按 mounted 渲染）。
  useEffect(() => {
    if (visible) {
      setMounted(true);
      return;
    }
    dbg('teardown-start');
    // 兜底强制内容透明：非减少动态路径退场动画已完成（progress 已到 1），
    // reduceMotion 路径是瞬间 onClose，这里直接压 0 保证宽限期不可见。
    enterOpacity.value = 0;
    exitProgress.value = 1;
    const t = setTimeout(() => {
      dbg('teardown-done');
      setMounted(false);
    }, TEARDOWN_GRACE_MS);
    return () => clearTimeout(t);
  }, [visible, enterOpacity, exitProgress, dbg]);

  const topBarAnimStyle = useAnimatedStyle(() => {
    // 拖拽启动时顶栏/缩略条随拖拽距离淡出（Twitter 行为）；退场时随 progress 隐去
    const dragLen = Math.hypot(dragTranslateX.value, dragTranslateY.value);
    const dragFade = Math.min(dragLen / 140, 1);
    return { opacity: overlayOpacity.value * (1 - dragFade) * (1 - exitProgress.value) };
  });

  // 容器淡入淡出（简化后唯一的进入/退出动画）：opacity 由 enterOpacity 驱动
  // ——打开 0→1（背景渐黑+内容渐现）、X 关闭 1→0。仅 JS 线程启动 withTiming
  // （历史实证 worklet 启动不推进）；拖拽退出不动 enterOpacity（保持 1），
  // 由 exitProgress 驱动内容飞出 + 黑幕淡出。
  const containerStyle = useAnimatedStyle(() => ({
    opacity: enterOpacity.value,
  }));

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

  // 背景模糊层恒显（不再逐帧动画）：全屏 UIBlurEffect 的 opacity 每帧变化 =
  // 每帧重采样整屏模糊，是拖拽/退场掉帧的主要来源（用户实测「拖动掉帧极其
  // 严重」「退出卡死」）。视觉等价方案：模糊层永远可见，明暗渐变全部由上方
  // 黑色 scrim 承担（单层合成，GPU 便宜）——静止全黑、拖拽渐透露模糊、
  // 退场渐隐，与旧公式（blur 渐显 + scrim 渐隐）观感一致。

  /**
   * 内容动效（iOS Photos 对齐，2026-08-30 v4 重做）：
   * - 图片层只做 transform（展开/跟手/飞回），**opacity 恒 1**——图片在动画
   *   全程清晰，不模糊不变浅（用户的观察：iOS 只有背景在变，图片不动色）；
   * - 背景模糊/变浅只发生在 bg 层（bgScrim/bgBlur 按拖拽距离+退场 progress）；
   * - 退场 x/y/scale 同一曲线（EASE_OUT）插值 → 轨迹是**直线**
   *   （iOS 无抛物线：松手后沿当前方向直线运动到目标/飞出）；
   * - 拖拽期圆角冻结（逐帧 borderRadius 每帧重栅格化=卡顿源）。
   */
  const contentStyle = useAnimatedStyle(() => {
    const p = exitProgress.value;
    if (p <= 0) {
      // ── 拖拽跟手态：进入展开位移 + 2D 跟手位移 + 按位移距离缩小 ──
      const dragLen = Math.hypot(dragTranslateX.value, dragTranslateY.value);
      const dragProgress = Math.min(dragLen / SHRINK_DISTANCE, 1);
      return {
        transform: [
          { translateX: dragTranslateX.value },
          { translateY: dragTranslateY.value },
          { scale: 1 - dragProgress * DRAG_SHRINK_FACTOR },
        ],
      };
    }
    // ── 退场态：直线轨迹（起点=手势当前位置）──
    // 2026-08-31 修双重缓动：progress 已由 withTiming 以 quad-out 驱动，
    // 这里再做 cubic 第二重插值会让起步瞬间速度 ≈ 6×平均（"怪异冲出去"）。
    // 位移与缩放共用同一 progress（quad-out）线性插值——同步到位：
    // 图片平滑放大/缩小，到目标位置时恰好达到目标大小（用户要求：
    // "刚好运行到原来位置的时候刚好达到初始大小"，缩放不单独走曲线）。
    // 圆角：不在此驱动（Fabric 动态 borderRadius 不可靠）——由 React state
    // 静态样式供给（在图片上，见渲染处 exitRadiusStyle）。
    const x = exitFromX.value + (exitToX.value - exitFromX.value) * p;
    const y = exitFromY.value + (exitToY.value - exitFromY.value) * p;
    const s = exitFromScale.value + (exitToScale.value - exitFromScale.value) * p;
    return {
      transform: [
        { translateX: x },
        { translateY: y },
        { scale: s },
      ],
    };
  });

  // 退场动画统一入口（JS 线程启动；X 关闭与手势退出共用）：
  // - 在 **JS 线程**调用 withTiming——与进入动画（effect 里启动）同一条成功
  //   路径。日志实证（2026-08-30）：在手势 worklet（onEnd）里直接启动的
  //   withTiming 会偶发完全不推进（exit 恒 0 + UI 帧回调断流），而 JS 线程
  //   启动的进入动画每次都正常。
  // - 缓动 quad-out（2026-08-31 三轮调慢）：cubic-out 起步瞬时速度为平均
  //   3 倍、"嗖地冲出去"是用户"飞出太快"观感的主因；quad-out 起步 2 倍，
  //   配合 onEnd 的 1.1s 均匀时长，冲刺感大减。
  // - 看门狗兜底：120ms 后 progress 仍未推进（UI 动画驱动异常）→ 改由 JS
  //   定时器逐帧写 exitProgress（quad-out 近似），保证退出动画必定完成、
  //   界面必定关闭——从机制上杜绝「退出卡死」。
  const startExitAnimation = useCallback(
    (opts: { duration?: number; tag: string }) => {
      const { duration = VIEWER_TRANSITION_MS, tag } = opts;
      // staticMode（PagerView 隐藏、overlay 承担画面）与退出动画同任务切换
      setStaticMode(true);
      // 优雅曲线（2026-08-31 用户："要优雅不要慢速"）：out(quad) 起步
      // 2× 平均速（冲出感/生硬）——inOut(cubic) 慢起慢收、头尾速度 0；
      // 配合 600ms 上限时长：柔和起止 + 利落节奏
      const easing = Easing.inOut(Easing.cubic);
      // 横滑带兜底：400ms revealTimer 前退出（<400ms）时横滑带尚未移正——
      // 此刻补一次瞬间滚动（后台被 staticMode overlay 盖住，不可见），
      // 保证横滑带停在移位后位置（2026-08-31 用户复现"飞回的不是位移后
      // 的位置"——flush 未触发，横滑带根本没移）
      flushHShiftOnOpen();
      // 主路径：JS 线程启动 withTiming
      exitProgress.value = withTiming(
        1,
        { duration, easing },
        (finished) => {
          if (finished) runOnJS(onClose)();
        },
      );
      // 看门狗 v2（2026-08-31）：停滞检测而非一次性检查——历史 reanimated
      // 坑是动画"推进一段后停住"（progress 停在 0.05~0.9 任意处），旧版
      // 120ms 后见 progress>0.05 即放手，停在中途会永久卡住（用户实测
      // "松手后图片卡住无法回去"）。现在：60ms 周期采样，progress 连续
      // 3 次（~180ms）未前进且未完成 → JS 定时器逐帧驱动到 1 并 onClose。
      const t0 = Date.now();
      let lastP = exitProgress.value;
      let stallCount = 0;
      // 视觉出屏提前关闭（2026-08-31 用户："图片已完全退出屏幕，界面仍一秒
      // 不可点"）：飞出目标=屏外 1.0×屏——图片完全越出屏幕后动画仍在屏外
      // 空飞（最长 1100ms 的尾部），期间 Modal 一直挡触摸。
      // 解析几何求「图片**完全**出屏」的进度阈值 outT（中心线直线路径 +
      // 等比缩放）：图最内缘越过屏幕边 → |c(t)| − half·s(t) ≥ half。
      // ⚠️ 符号务必为「减」：|c|+half·s ≥ half 是"贴边"（轻拖时起点即满足
      // → outT=0 → 动画第一拍被截断，列表闪现——用户实测"飞出过程闪几下"）。
      // 二分求解；四方向取最后越出的边（max）。outT>0 才启用。
      const outT = (() => {
        const fx = exitFromX.value;
        const fy = exitFromY.value;
        const tx = exitToX.value;
        const ty = exitToY.value;
        const fs = exitFromScale.value;
        const ts = exitToScale.value;
        const hw = SCREEN_WIDTH / 2;
        const hh = SCREEN_HEIGHT / 2;
        const solve = (c0: number, c1: number, half: number): number | null => {
          const f = (t: number) => {
            const c = c0 + (c1 - c0) * t;
            const s = fs + (ts - fs) * t;
            return Math.abs(c) - half * s - half; // 图完全出屏的判据
          };
          if (f(1) <= 0) return null; // 终点仍未完全出屏
          if (f(0) >= 0) return 0; // 起点已完全出屏（不会发生）
          let lo = 0;
          let hi = 1;
          for (let i = 0; i < 16; i++) {
            const mid = (lo + hi) / 2;
            if (f(mid) >= 0) hi = mid;
            else lo = mid;
          }
          return hi;
        };
        const tsOut = [solve(fx, tx, hw), solve(fy, ty, hh), solve(-fx, -tx, hw), solve(-fy, -ty, hh)];
        const valid = tsOut.filter((v): v is number => v !== null && v > 0);
        return valid.length === 0 ? null : Math.max(...valid);
      })();
      const watchdog = setInterval(() => {
        const p = exitProgress.value;
        const elapsed = (Date.now() - t0) / duration;
        // 图片完全越出屏幕 → 立即关闭（尾部屏外空飞不再阻塞触摸）
        if (outT !== null && p >= outT) {
          clearInterval(watchdog);
          onClose();
          return;
        }
        if (p >= 0.99 || elapsed > 1.15) {
          clearInterval(watchdog);
          if (p < 0.99) onClose(); // 超时但未完成：强制关闭
          return;
        }
        if (elapsed < 0.06) return; // 起步期不判
        if (p > lastP + 0.01) {
          lastP = p;
          stallCount = 0;
          return;
        }
        stallCount += 1;
        if (stallCount < 3) return;
        dbg('exit-watchdog-stall', { p, tag });
        clearInterval(watchdog);
        const drive = setInterval(() => {
          const t = Math.min(1, (Date.now() - t0) / duration);
          const e = 1 - Math.pow(1 - t, 2); // quad-out 近似
          exitProgress.value = Math.max(exitProgress.value, e);
          if (t >= 1) {
            clearInterval(drive);
            onClose();
          }
        }, 16);
      }, 60);
      return () => clearInterval(watchdog);
    },
    [exitFromX, exitFromY, exitFromScale, exitToX, exitToY, exitToScale, exitProgress, onClose, dbg],
  );

  // X 关闭（简化 2026-08-30）：不做飞回动画——容器 350ms 渐淡出后关闭，
  // 由 teardown 宽限期平滑拆除（PagerView 内部滚动收尾，防卸载闪退）。
  const closeViewer = useCallback(() => {
    dbg('close-x', {
      n: images.length,
      dragX: dragTranslateX.value,
      dragY: dragTranslateY.value,
    });
    isDismissing.value = true;
    // X 关闭也补横滑带移位（后台不可见，瞬间移动）：与 startExitAnimation
    // 同一语义（revealTimer 400ms 前关闭时横滑带尚未移正）
    flushHShiftOnOpen();
    if (reduceMotion) {
      onClose();
      return;
    }
    // 淡出（JS 线程启动）+ 超时兜底：动画异常（withTiming 不推进的历史
    // 问题）时 520ms 后强制关闭，杜绝「点 X 关不掉」。
    enterOpacity.value = withTiming(
      0,
      { duration: 350, easing: EASE_OUT },
      (finished) => {
        if (finished) runOnJS(onClose)();
      },
    );
    setTimeout(onClose, 520);
  }, [dbg, images.length, dragTranslateX, dragTranslateY, isDismissing, reduceMotion, enterOpacity, onClose]);

// 交互式拖拽关闭（iOS Photos 风格，2026-08-29 重构 v2 / 08-30 增补）：
// - 手势本体稳定（门控全走共享值，不随 isZoomed 重建——快速捏合不被掐断）；
// - minDistance=10 自动激活兜底（不再依赖纯手动 activate：嵌套 PagerView
//   环境下手动模式会偶发收不到 touchesMove，普通图纵滑退不出——用户实测）；
//   激活后 onUpdate 里仲裁：长图页滚动区内纵向不跟手（滚动归阅读 pan，
//   贴顶下拉/贴底上拉才接管退出）；横向仅 PagerView 翻不了的方向（首页右
//   拉/末页左拉）跟手，其余横向拖动（翻页）X 归零不污染。
//   长图边界判定符号注意：scrollY ∈ [-max, 0]（向下滚为负），贴底 =
//   scrollY ≥ -max+0.5（旧版写成 ≥ max-0.5 恒不成立 → 底部退不出）。
// - 放开时距离或速度过阈值 → 三档退场目标：源缩略图矩形（点击页）→ 底栏
//   缩略条格（翻页后当前页）→ 沿手势方向缩小淡出（单图无缩略条）；
//   未过阈值 → 弹簧回弹。缩放态（zoomedSV）下禁用，交给页内缩放 pan。
const dismissGesture = useMemo(
    () =>
      Gesture.Pan()
        .minDistance(10)
        .maxPointers(1)
        .simultaneousWithExternalGesture(longReadPan)
        .onTouchesDown((e) => {
          if (zoomedSV.value) return;
          const t = e.changedTouches[0];
          touchStartX.value = t.x;
          touchStartY.value = t.y;
          prevTransX.value = 0;
          prevTransY.value = 0;
        })
        .onStart((e) => {
          // 退场动画进行中忽略新拖拽（2026-08-30：第二次拖拽在 isDismissing
          // 期再次 onStart 会叠加 setStaticMode/探针，状态错乱）
          if (isDismissing.value) return;
          // 自动激活（minDistance 10）时 translation 已累计了按下到激活点的
          // 位移：以激活点为增量基线，onUpdate 从 0 起跟手（无首帧跳变）。
          prevTransX.value = e.translationX;
          prevTransY.value = e.translationY;
          runOnJS(dbg)('drag-start', { isLong: isLongPageSV.value, zoomed: zoomedSV.value });
          // 拖拽即切静态大图（仅非长图页）：PagerView（SwiftUI TabView）宿主
          // transform 是 120fps 卡顿源，拖拽跟手全程落在轻量 Image 上；
          // 长图页保持阅读形态，退场时才切（onEnd 里）。回弹时切回 PagerView。
          if (!isLongPageSV.value) runOnJS(setStaticMode)(true);
        })
        .onTouchesMove((e, mgr) => {
          if (isDismissing.value || zoomedSV.value) return;
          // 兜底手动激活：minDistance=10 已能自动激活，这里只做激活前仲裁
          //（长图页非边界纵向、翻页横向不抢）
          const dx = e.changedTouches[0].x - touchStartX.value;
          const dy = e.changedTouches[0].y - touchStartY.value;
          let yGo = false;
          if (isLongPageSV.value) {
            const st = scrollStatesRef.current[currentIdxSV.value];
            const sy = st?.y.value ?? 0;
            const smax = st?.max.value ?? 0;
            const atTop = sy <= 0.5;
            const atBottom = sy >= -smax + 0.5;
            yGo = Math.abs(dy) >= 10 && ((dy > 0 && atTop) || (dy < 0 && atBottom));
          } else {
            yGo = Math.abs(dy) >= 10;
          }
          const xGo =
            Math.abs(dx) >= 10 &&
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
          // 横向跟手：斜向拖动（X 分量 ≲ Y 分量）→ X 自由跟随（用户实测
          // 「不能随手势自由拖动」= 非边缘页横动被归 0）；纯横向（X 主导）
          // → 仍只跟边缘页（其余交 PagerView 翻页，不污染退场位移）。
          const diag =
            Math.abs(dX) <= Math.abs(dY) * 1.5 ||
            Math.abs(dX) <= Math.abs(dY);
          const xGo =
            diag ||
            (dX > 0 && currentIdxSV.value <= 0) ||
            (dX < 0 && currentIdxSV.value >= pageCountSV.value - 1);
          // Twitter 式跟手限位：显示位移钳制在附近范围（X ±80pt，
          // Y ±38% 屏高）——超过后图片"钉住"，raw 继续累计驱动 progress
          dragTranslateX.value = xGo
            ? Math.max(-MAX_DRAG_X, Math.min(MAX_DRAG_X, dragTranslateX.value + dX))
            : 0;
          let followY = true;
          if (isLongPageSV.value) {
            const st = scrollStatesRef.current[currentIdxSV.value];
            const sy = st?.y.value ?? 0;
            const smax = st?.max.value ?? 0;
            const atTop = sy <= 0.5;
            const atBottom = sy >= -smax + 0.5;
            followY =
              (e.translationY > 2 && atTop) ||
              (e.translationY < -2 && atBottom) ||
              (atTop && atBottom);
          }
          if (followY) {
            dragRawY.value += dY;
            const maxY = SCREEN_HEIGHT * MAX_DRAG_Y_FACTOR;
            dragTranslateY.value = Math.max(-maxY, Math.min(maxY, dragRawY.value));
          }
        })
        .onEnd((e) => {
          if (isDismissing.value || zoomedSV.value) return;
          // 阈值判定用 raw 累计（图片钉在限位后 raw 仍增长，拉过限位照常触发）
          const dragLen = Math.hypot(dragTranslateX.value, dragRawY.value);
          const beyondThreshold = dragLen > 140 || Math.abs(e.velocityY) > 900;
          if (!beyondThreshold) {
            // 未过阈值 → 弹簧回弹（X/Y/raw 一起回）；拖拽期间切的静态大图换回
            // PagerView（恢复翻页/缩放，长图页本就没切）
            runOnJS(dbg)('drag-end-spring', { len: dragLen, vy: e.velocityY });
            runOnJS(setStaticMode)(false);
            dragRawY.value = withSpring(0, MOMENTUM);
            dragTranslateX.value = withSpring(0, MOMENTUM);
            dragTranslateY.value = withSpring(0, MOMENTUM);
            return;
          }
          isDismissing.value = true;
          runOnJS(dbg)('drag-end-exit', {
            len: dragLen,
            vy: e.velocityY,
            isLong: isLongPageSV.value,
          });
          if (reduceMotionSV.value) {
            runOnJS(onClose)();
            return;
          }
          const dragProgress = Math.min(dragLen / SHRINK_DISTANCE, 1);
          // 退场起点=当前跟手位置（clamp 后的显示值）；scale 按拖拽距离缩小
          const fromX = dragTranslateX.value;
          const fromY = dragTranslateY.value;
          const fromScale = 1 - dragProgress * DRAG_SHRINK_FACTOR;
          // 切除 PagerView（SwiftUI TabView）→ 静态大图：同 URI + imageWarm 免
          // 过渡，换图像素级无感；退场 transform 落在轻量 Image 上，120fps 平滑。
          // staticMode 与圆角在 startExitAnimation（JS 同任务）里一并切换——若
          // 在此 runOnJS 单独切，overlay 先以无圆角姿态显示一帧（用户实测）。
          // ── 退场目标（2026-08-31 v2：横滑带帧优先）──
          // ── 退场目标（2026-08-31 用户拍板：回归初始"滑出屏幕"）──
          // 删除飞回原位/条格/横滑带帧全部档位：手势退出 = 沿松手方向
          // 飞出屏幕（fallback0，动态时长），长图/普通图一视同仁。
          const fallback0 = prepareFlyOut(e, fromX, fromY);
          const toX = fallback0.toX;
          const toY = fallback0.toY;
          const toScale = 0.35;
          const exitDuration = fallback0.exitDuration;
          const tag = 'exit-drag';
          // 退场目标取证（2026-08-31 临时）：复现"滑出屏幕"问题看 exit-target 行
          runOnJS(dbg)('exit-target', {
            flyback: tag,
            idx: currentIdxSV.value,
            openIdx: openIdxSV.value,
            toX: Math.round(toX),
            toY: Math.round(toY),
            toScale,
            tag,
          });
          // 动画统一由 JS 线程启动（startExitAnimation 内部带看门狗兜底——
          // 日志实证 worklet 里直接 withTiming 会偶发不推进，JS 启动是
          // 与进入动画相同的成功路径）。
          // toScale 不做钳制（2026-08-31 用户要求）：松手后图片平滑放大到
          // 初始大小（撤销跟手缩小），恰好到位时恰好恢复——目标由各档
          // 几何给出（源矩形宽比/条格/0.35），宽高比由 scale 自然适配。
          exitFromX.value = fromX;
          exitFromY.value = fromY;
          exitFromScale.value = fromScale;
          exitToX.value = toX;
          exitToY.value = toY;
          exitToScale.value = toScale;
          runOnJS(startExitAnimation)({ duration: exitDuration, tag });
        }),
    [
      onClose,
      reduceMotionSV,
      zoomedSV,
      longReadPan,
      isLongPageSV,
      currentIdxSV,
      openIdxSV,
      initialIdxSV,
      touchStartX,
      touchStartY,
      prevTransX,
      prevTransY,
      dragTranslateX,
      dragTranslateY,
      isDismissing,
      exitFromX,
      exitFromY,
      exitFromScale,
      exitToX,
      exitToY,
      exitToScale,
      exitProgress,
      setStaticMode,
      dbg,
      startExitAnimation,
    ],
  );

  const toggleUI = useCallback(() => {
    setShowUI((prev) => !prev);
  }, []);

  const handleClose = useCallback(() => {
    hapticForScene('press');
    closeViewer();
  }, [closeViewer]);

  // ══ 翻页 settle 门控（2026-08-31 快滑卡死根治）══
  // 快速滑动时 onPageSelected 每停一页都触发 setCurrentIndex → 窗口重建
  //（PagerView reload 子视图 + setPageWithoutAnimation），在 UICollectionView
  // 自身减速动画中反复打断 → 卡在半页（半页之间无内容 = 黑屏）+ 分页系统
  // 拉回 = 翻不动（真机复现「黑屏时无法滑到下一张」）。
  // 门控：dragging/settling 期间只记录目标页（pending），等减速真正结束
  //（pageScrollState=idle）再一次性应用最终页（窗口重建+预取+触感）。
  // 兜底：settling 超过 600ms 未 idle（减速异常）强制应用，防永久卡死。
  const pendingIdxRef = useRef(-1);
  const settleTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const applyPendingPage = useCallback(() => {
    if (settleTimerRef.current) {
      clearTimeout(settleTimerRef.current);
      settleTimerRef.current = null;
    }
    if (pendingIdxRef.current < 0) return;
    const idx = pendingIdxRef.current;
    pendingIdxRef.current = -1;
    dbg('apply-page', { idx });
    hapticForScene('toggle');
    setCurrentIndex(idx);
    setViewingIndex(idx);
  }, [dbg]);
  // 卸载/关闭时清理兜底定时器
  useEffect(() => () => {
    if (settleTimerRef.current) clearTimeout(settleTimerRef.current);
  }, []);

  const handlePageSelected = useCallback(
    (e: PagerViewOnPageSelectedEvent) => {
      // 全量挂载：position 即绝对下标
      const pos = e.nativeEvent.position;
      pendingIdxRef.current = pos;
      dbg('page-sel', { pos, pending: true });
      // 应用交给 onPageScrollStateChanged 的 idle（慢滑/快滑统一走 settle 结束）
    },
    [dbg],
  );

  const handlePageScrollStateChanged = useCallback(
    (e: PageScrollStateChangedNativeEvent) => {
      const st = e.nativeEvent.pageScrollState;
      dbg('page-state', { st });
      if (st === 'idle') {
        applyPendingPage();
      } else if (st === 'settling') {
        // 兜底：减速异常（settling 一直不结束）600ms 后强制应用
        if (settleTimerRef.current) clearTimeout(settleTimerRef.current);
        settleTimerRef.current = setTimeout(applyPendingPage, 600);
      }
    },
    [applyPendingPage, dbg],
  );

  const handleThumbnailPress = useCallback(
    (idx: number) => {
      // 全量挂载：绝对下标直接切页（onPageSelected → settle 门控应用）
      pagerRef.current?.setPage(idx);
    },
    [],
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
      showSavePill('保存成功');
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

  // 渲染风暴取证（节流 250ms）：JS 线程卡死前的最后阶段往往伴随高频重渲染，
  // 此日志高频出现即渲染风暴实锤（临时埋点，验完即删）。
  // ⚠️ 不在 render 里读共享值（isDismissing.value 曾在此打点——Reanimated 4
  // 渲染期读 .value 会警告且值可能过期，已移除）。
  if (__DEV__) {
    const now = Date.now();
    if (now - lastRenderLogRef.current > 250) {
      lastRenderLogRef.current = now;
      console.warn('[viewer-dbg]', new Date().toISOString().slice(11, 23), 'render', {
        visible,
        mounted,
        staticMode,
        currentIndex,
        viewingIndex,
        isZoomed,
      });
    }
  }

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
            style={[
              styles.modalContainer,
              { pointerEvents: visible ? 'auto' : 'none' },
              containerStyle,
            ]}
          >
          {/* 状态栏隐藏/恢复走原生（TiebaNative.setModalStatusBarHidden）：iOS 27
              RN StatusBar 是 no-op 且 setStyle 会红屏；这里不放 StatusBar */}

          {/* 背景层 1：毛玻璃（恒显；明暗渐变由黑 scrim 承担，见
              bgScrimStyle 注释——blur opacity 逐帧动画=每帧重采样，掉帧源）。
              realTime={false}：背后信息流在查看器打开期间是静止的，实时
              模糊的输出与静态模拟观感等价，省掉全屏每帧高斯重采样
              （顶/底栏同款静态模拟；拖拽揭示时显示为暗色半透明+高光渐变）。 */}
          <View style={styles.bgLayer} pointerEvents="none">
            <GlassView
              theme="dark"
              glassEffectStyle="regular"
              realTime={false}
              style={StyleSheet.absoluteFill}
            />
          </View>
          {/* 背景层 2：黑色遮罩（静止时全黑，拖拽时渐隐揭示模糊背景） */}
          <Animated.View style={[styles.bgLayer, styles.bgScrim, bgScrimStyle]} pointerEvents="none" />

          {/* Image Gallery — native iOS PagerView
              v4（2026-08-30）：PagerView 永不卸载、不参与任何 transform——
              动画（进入展开/拖拽跟手/退场飞回）全部由 overlay 静态大图承担：
              轻量 Image 单层 transform 是 120fps 顺手活，SwiftUI TabView 多页
              宿主变换才是掉帧源。staticMode=true 时 PagerView 仅 opacity 0
              （保持挂载/解码推进），overlay 盖在其上动画。 */}
          <View style={styles.pagerWrap}>
            <PagerView
              ref={pagerRef}
              style={[styles.pager, staticMode && styles.pagerWhileStatic]}
              initialPage={initialIndex}
              scrollEnabled={!isZoomed}
              onPageScroll={handlePageScroll}
              onPageSelected={handlePageSelected}
              onPageScrollStateChanged={handlePageScrollStateChanged}
            >
            {/* 全量挂载（2026-08-31）：cell 为空 View 零成本，图片按 active
                单页解码；active 跟随 viewingIndex——滑动途中视觉新页立即
                出图（缓存秒显），不再等 settle 结束才亮。 */}
            {images.map((uri, index) => {
              const longPage = isLongImageOf(index);
              const pageMeta = imageMeta?.[index];
              const pageIsActive = index === viewingIndex;
              return (
              <View key={String(index)} collapsable={false} style={styles.imagePage}>
                {/* 大图长按：在长按位置弹出选项框（无放大预览，页面本身已是大图） */}
                <TiebaPhotoContextMenu
                  fullUrl={imageOrigins?.[index] ?? displayUriOf(index, uri)}
                  previewEnabled={false}
                  actions={buildPageActions(index)}
                  onAction={(actionId) => handlePageMenuAction(index, actionId)}
                  style={StyleSheet.absoluteFill}
                >
                  {longPage ? (
                    /* 长图阅读模式（2026-08-29）：小档秒出 + 原图后台加载完淡入；
                       fit-width + 单指下滑读完；捏合/双击缩放。修复长图默认直接
                       解码 originSrc 巨图导致的整机冻结。 */
                    <LongImageView
                      baseUri={uri}
                      originUri={imageOrigins?.[index]}
                      imageWidth={pageMeta?.width}
                      imageHeight={pageMeta?.height}
                      onSingleTap={toggleUI}
                      onZoomChange={setIsZoomed}
                      active={pageIsActive}
                      readPan={longReadPan}
                      scrollIndex={index}
                      onScrollAttach={attachScrollState}
                      onScrollDetach={detachScrollState}
                      gallerySwipe
                      galleryScrollRef={galleryScrollRef}
                      galleryIndex={viewingIndex}
                      galleryItemWidth={SCREEN_WIDTH}
                      zoomMirror={zoomedSV}
                      gesturePulse={gesturePulse}
                      onLoadStart={() => {
                        if (displayUriOf(index, uri) !== uri) {
                          setOriginLoading((prev) => ({ ...prev, [index]: true }));
                        }
                      }}
                      onLoadEnd={() => {
                        setOriginLoading((prev) => ({ ...prev, [index]: false }));
                      }}
                    />
                  ) : (
                    <ZoomableImage
                      uri={displayUriOf(index, uri)}
                      previewUri={imagePreviews?.[index]}
                      onSingleTap={toggleUI}
                      onZoomChange={setIsZoomed}
                      active={pageIsActive}
                      gallerySwipe
                      galleryScrollRef={galleryScrollRef}
                      galleryIndex={viewingIndex}
                      galleryItemWidth={SCREEN_WIDTH}
                      zoomMirror={zoomedSV}
                      gesturePulse={gesturePulse}
                      onLoadStart={() => {
                        // 仅当该页显示的是原图（长图默认/手动切换）时转圈：
                        // 普通档位图沿用原有直出行为，不闪加载动画
                        if (displayUriOf(index, uri) !== uri) {
                          setOriginLoading((prev) => ({ ...prev, [index]: true }));
                        }
                      }}
                      onLoadEnd={() => {
                        setOriginLoading((prev) => ({ ...prev, [index]: false }));
                      }}
                    />
                  )}
                </TiebaPhotoContextMenu>
                {originLoading[index] ? (
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
          {/* overlay 动画层（常驻单图，staticMode 仅瞬时切显隐）：transform
              全落在纯 RN Animated.View 容器。2026-08-30 删预览垫底层——
              双图全量解码与「每次只加载一个」冲突；且进入动画已删，overlay
              只在拖拽/退场承担画面，此时图 = 当前页显示档（displayUriOf），
              与 PagerView 内当前页同 URL → 内存缓存命中即显、零额外解码。
              transition 0：缓存命中无需淡入，避免与退场 transform 竞争。 */}
          <Animated.View
            pointerEvents="none"
            style={[
              styles.pager,
              styles.pagerOverlay,
              staticMode ? styles.pagerOverlayActive : null,
              // 圆角**不能**放在本容器：图片 contentFit=contain 居中，图片
              // 四角根本不接触容器边缘，容器圆角对图片无效（2026-08-31 用户
              // 实测"动画过程方角、末尾才圆角"=teardown 后真卡片圆角）。
              // 圆角直接给 overlay 内两个 Image（见下），scale 动画时等比跟随。
              contentStyle,
            ]}
          >
            {/* 垫底小档（当页预览 URI）：staticMode 承担拖拽/退场画面时，若大图
                尚未加载（快速翻页后立即拖动），预览先出图避免退场黑屏。 */}
            {(() => {
              const overlayMain = displayUriOf(viewingIndex, images[viewingIndex]);
              const overlayPreview = imagePreviews?.[viewingIndex];
              // 注意：退出（飞出）动画的 Image **不带 borderRadius**——iOS 上
              // cornerRadius+mask 的视图在 transform 动画中逐帧重栅格化，
              // 全屏大图 scale 轨迹卡顿闪烁（2026-08-31 用户实测"飞出过程
              // 卡顿明显闪几下"）。纯飞出场景无圆角需求（此前圆角诉求属于
              // 已删除的飞回原位档）。
              return overlayPreview && overlayPreview !== overlayMain ? (
                <Image
                  source={{ uri: overlayPreview }}
                  style={StyleSheet.absoluteFill}
                  contentFit="contain"
                  transition={0}
                  cachePolicy="memory-disk"
                  recyclingKey={`viewer-static-preview-${overlayPreview}`}
                />
              ) : null;
            })()}
            <Image
              source={{ uri: displayUriOf(viewingIndex, images[viewingIndex]) }}
              style={StyleSheet.absoluteFill}
              contentFit="contain"
              transition={0}
              cachePolicy="memory-disk"
              recyclingKey={`viewer-static-${viewingIndex}`}
            />
          </Animated.View>
        </View>

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
              {viewingIndex + 1}/{images.length}
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
              scrollEventThrottle={32}
              onScroll={(e) => {
                thumbnailScrollXRef.current = e.nativeEvent.contentOffset.x;
                thumbXSV.value = e.nativeEvent.contentOffset.x;
              }}
            >
              {images.map((uri, index) => (
                <ThumbnailCell
                  key={index}
                  uri={uri}
                  index={index}
                  currentIndex={viewingIndex}
                  onPress={handleThumbnailPress}
                />
              ))}
            </ScrollView>
          </Animated.View>
        )}
      </Animated.View>
      </GestureDetector>
        </SafeAreaProvider>
          // 底部保存成功药丸（2026-08-31 用户要求：与点赞成功一致、底部、简洁）
  {savePill ? (
    <Animated.View
      entering={FadeIn.duration(180)}
      exiting={FadeOut.duration(180)}
      pointerEvents="none"
      style={[styles.savePill, { bottom: Math.max(insets.bottom, 16) + 96 }]}
    >
      <Text style={styles.savePillText}>{savePill}</Text>
    </Animated.View>
  ) : null}

    </Modal>
  );
}
