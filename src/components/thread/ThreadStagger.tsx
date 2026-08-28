/**
 * ThreadStagger — 首屏入场级联包装（StaggerItem）。
 *
 * 拆自 src/app/thread/[id].tsx（4 抽 1 留拆分，#8 的补充：主文件 ≤550 行目标
 * 要求 entrance 包装独立成文件；扫描报告未点名该文件，属拆分必要补充）。
 *
 * 语义：只对第一个成功批次（前 ENTRANCE_ROW_WINDOW 行）按 index 级联渐入；
 * 窗口外行随全局进度推进即为 1（不透明），否则 index 足够大时 local 会被
 * clamp 到 0，loadMore 追加的行永久透明 →"新回复被遮挡"。reduceMotion 保持
 * 全不透明（由页面在 entranceProgress 上直接置 1 实现）。
 */

import { memo, type ReactNode } from 'react';
import Reanimated, { useAnimatedStyle, type SharedValue } from 'react-native-reanimated';
import { DURATION } from '@/theme/springs';

export interface StaggerItemProps {
  index: number;
  entrance: SharedValue<number>;
  entryTotal: SharedValue<number>;
  children: ReactNode;
}

export const StaggerItem = memo(function StaggerItem({
  index,
  entrance,
  entryTotal,
  children,
}: StaggerItemProps) {
  const style = useAnimatedStyle(() => {
    'worklet';
    const p = entrance.value;
    const enter = DURATION.enter;
    const stagger = DURATION.stagger;
    const windowCount = Math.max(entryTotal.value, 1);
    const total = enter + stagger * windowCount;
    const start = (index * stagger) / total;
    const span = enter / total;
    const local =
      index < windowCount
        ? Math.min(Math.max((p - start) / span, 0), 1)
        : Math.min(p, 1);
    return {
      opacity: local,
      transform: [{ translateY: (1 - local) * 10 }],
    };
  });
  return <Reanimated.View style={style}>{children}</Reanimated.View>;
});