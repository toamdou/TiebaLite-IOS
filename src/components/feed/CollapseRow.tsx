/**
 * CollapseRow — 信息流「不感兴趣」折叠行（explore 动态页共用）
 *
 * 卡片垂直压扁（scaleY 1→0 + 同降透明度）280ms，动画完成才由
 * onCollapseEnd 移除数据。LegendList 按布局尺寸排版，不感知行内
 * transform 变化，动画期间行位保持、下方内容不跳动；数据移除后
 * LegendList 自然重排上移。
 * collapsing 复位时强制回 1（同步），保证动画状态不残留（行组件
 * 按需挂载/复用，残留的 collapsed 状态会串到其它卡片）。
 */

import { memo, useEffect, useRef } from 'react';
import Animated, {
  runOnJS,
  useAnimatedStyle,
  useSharedValue,
  withTiming,
} from 'react-native-reanimated';
import { EASE_OUT } from '@/theme';

export const CollapseRow = memo(function CollapseRow({
  collapsing,
  onCollapseEnd,
  children,
}: {
  collapsing: boolean;
  onCollapseEnd: () => void;
  children: React.ReactNode;
}) {
  const progress = useSharedValue(1);
  const endedRef = useRef(false);

  useEffect(() => {
    if (collapsing) {
      if (endedRef.current) return;
      endedRef.current = true;
      progress.value = withTiming(0, { duration: 280, easing: EASE_OUT }, (finished) => {
        if (finished) runOnJS(onCollapseEnd)();
      });
    } else {
      endedRef.current = false;
      progress.value = 1;
    }
  }, [collapsing, onCollapseEnd, progress]);

  const animatedStyle = useAnimatedStyle(() => ({
    opacity: progress.value,
    transform: [{ scaleY: progress.value }],
  }));

  return <Animated.View style={animatedStyle}>{children}</Animated.View>;
});