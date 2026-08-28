// ============================================================
// TiebaLite React Native - SegmentPager
// 与 SwiftUI segmented 联动的横向分页器（react-native-pager-view）。
//
// 行为（对齐用户要求"凡有 segment 栏都支持左右滑动切换板块"）：
// - 整页左右滑动切换板块；segment 点击 ↔ pager 双向同步；
// - canExit=true（push 进来的界面：吧页/搜索页）时：
//   最左板块（page 0）继续向右滑 → 视觉反馈完全交给 pager 原生橡皮筋
//   （overdrag 即 collectionView.bounces，跟手零延迟）；JS 只在松手时按
//   距离/速度判定，过阈值直接 onExit()（router.back 的原生 pop 转场收尾）。
//   不再做整页平移：旧实现外层叠 translateX 会与原生 bounce 叠成双倍位移，
//   且原生层即时 / JS 层慢一帧、两层回弹曲线不同会短暂撕裂。
//   原生栈返回手势由调用方关闭（gestureEnabled:false），不会抢横滑。
// - canExit=false（一级 tab 页：动态/消息）时最左向右滑只回弹，不退出。
// ============================================================

import { useCallback, useEffect, useRef, type ReactNode } from 'react';
import { StyleSheet, View } from 'react-native';
import { hapticForScene } from '@/theme/hapticsMap';
import PagerView from 'react-native-pager-view';

/** 松手时"退出 vs 回弹"的距离阈值（页宽的 30%） */
const EXIT_DISTANCE = 0.3;
/** 松手时甩动速度阈值（页宽/秒），快滑即退出 */
const EXIT_VELOCITY = 1.4;
/** 松手速度采样窗口（ms）：取窗口内首尾样本差分。拖到边缘停住再松手时，
 * 窗口外样本被排除，不会被大 dt 误判成低速。 */
const EXIT_VELOCITY_WINDOW_MS = 90;

/** 单帧 overdrag 样本（ratio = 已拖出页宽的比例） */
interface DragSample {
  ratio: number;
  ts: number;
}

export interface SegmentPagerProps {
  /** 当前页下标（受控；segment 变化时也应同步更新本值） */
  pageIndex: number;
  onPageIndexChange: (index: number) => void;
  /** 最左页继续右滑是否触发退出（push 进栈的界面传 true + onExit） */
  canExit?: boolean;
  onExit?: () => void;
  children: ReactNode;
}

export function SegmentPager({
  pageIndex,
  onPageIndexChange,
  canExit = false,
  onExit,
  children,
}: SegmentPagerProps) {
  const pagerRef = useRef<PagerView>(null);
  // 拖动中的 overdrag 样本（供松手速度差分）；仅保留最近窗口+少量余量
  const dragSamplesRef = useRef<DragSample[]>([]);
  const draggingRef = useRef(false);
  const lastIndexRef = useRef(pageIndex);
  const onExitRef = useRef(onExit);
  onExitRef.current = onExit;

  // 外部（segment 点击）改变 pageIndex → 命令式翻页；仅在真正变化时翻。
  // 用无动画瞬跳（2026-08-26 用户反馈）：setPage 的整页横滑会把列表头
  // （吧卡片/资料卡+segment）一起滑走，观感是"整个页面切换"；瞬跳后头部
  // 纹丝不动、只有下方卡片列表换成目标页，符合预期。手势滑动不经此路径
  // （onPageSelected 已同步 lastIndexRef），仍由 pager 原生动画驱动。
  useEffect(() => {
    if (pageIndex !== lastIndexRef.current && pagerRef.current) {
      lastIndexRef.current = pageIndex;
      pagerRef.current.setPageWithoutAnimation(pageIndex);
    }
  }, [pageIndex]);

  // 松手判定：距离或速度过阈 → 直接退出（收尾交给原生 pop 转场）；
  // 未过阈 → 原生橡皮筋自行回弹，无需任何 JS 动画。
  const settleExit = useCallback(() => {
    draggingRef.current = false;
    const samples = dragSamplesRef.current;
    dragSamplesRef.current = [];
    const last = samples[samples.length - 1];
    if (!last) return;
    const cutoff = last.ts - EXIT_VELOCITY_WINDOW_MS;
    let first: DragSample | null = null;
    for (const s of samples) {
      if (s.ts >= cutoff) {
        first = s;
        break;
      }
    }
    const velocity =
      first && last.ts > first.ts
        ? Math.abs((last.ratio - first.ratio) / ((last.ts - first.ts) / 1000))
        : 0;
    if (last.ratio >= EXIT_DISTANCE || velocity >= EXIT_VELOCITY) {
      onExitRef.current?.();
    }
  }, []);

  const handlePageScroll = useCallback(
    (e: { nativeEvent: { position: number; offset: number } }) => {
      const { position, offset } = e.nativeEvent;
      // 只跟踪"最左页继续右滑"：position===0 && offset<0（overdrag 橡皮筋）
      if (!(canExit && draggingRef.current && position <= 0 && offset < 0)) return;
      const samples = dragSamplesRef.current;
      const now = Date.now();
      samples.push({ ratio: Math.min(1, -offset), ts: now });
      // 窗口裁剪：只留速度窗口 + 余量，长拖不无限堆积
      while (samples.length > 2 && samples[0].ts < now - EXIT_VELOCITY_WINDOW_MS * 3) {
        samples.shift();
      }
    },
    [canExit],
  );

  const handlePageScrollStateChanged = useCallback(
    (e: { nativeEvent: { pageScrollState: string } }) => {
      const state = e.nativeEvent.pageScrollState;
      if (state === 'dragging') {
        draggingRef.current = true;
        dragSamplesRef.current = [];
      } else if ((state === 'idle' || state === 'settling') && draggingRef.current) {
        settleExit();
      }
    },
    [settleExit],
  );

  return (
    <View style={styles.container}>
      <PagerView
        ref={pagerRef}
        style={styles.fill}
        initialPage={pageIndex}
        // overdrag=可橡皮筋：停在最左继续右拖有原生跟手反馈；onPageScroll 的
        // 负 offset 仅作松手判定的数据源，不再驱动任何视觉平移
        overdrag={canExit}
        onPageSelected={(e) => {
          const index = e.nativeEvent.position;
          lastIndexRef.current = index;
          // segment 点击与手势滑动两种来源统一在此给触觉反馈（点击经
          // setPage 动画落定、滑动由原生翻页落定，均触发 onPageSelected）
          hapticForScene('segment');
          onPageIndexChange(index);
        }}
        onPageScroll={handlePageScroll}
        onPageScrollStateChanged={handlePageScrollStateChanged}
      >
        {children}
      </PagerView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  fill: { flex: 1 },
});
