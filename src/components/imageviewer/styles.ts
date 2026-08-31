/**
 * ImageViewer 样式（2026-08-31 从主组件拆出——主文件超 1k 行红线收敛）。
 * 依赖：SCREEN_WIDTH/HEIGHT（模块级竖屏快照，见主文件注释）、Spacing。
 */
import { StyleSheet } from 'react-native';
import { Spacing } from '@/theme';
import { Dimensions } from 'react-native';

const { width: SCREEN_WIDTH, height: SCREEN_HEIGHT } = Dimensions.get('window');

export const viewerStyles = StyleSheet.create({
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
/* overlay 动画层：绝对铺满 pagerWrap，常态 opacity 0（PagerView 交互），
   staticMode 期间 pagerOverlayActive 置 1 承担全部 transform。
   overflow hidden：退场飞回时 contentStyle 下发 borderRadius（源矩形圆角），
   须裁剪子图片才可见圆角（2026-08-31 用户实测"动画中无圆角"）*/
  pagerOverlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    opacity: 0,
    overflow: 'hidden',
  },
  pagerOverlayActive: {
    opacity: 1,
  },
  /* staticMode 期间 PagerView 仅隐藏（保持挂载/解码），不让它参与动画 */
  pagerWhileStatic: {
    opacity: 0,
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