/**
 * Thread Floating Bar（帖子详情页底部浮动玻璃胶囊）— 4 个动作：复制链接 /
 * 帖点赞 / 收藏 / 更多。滚动自动隐藏完全走 UI 线程 shared value（#1）。
 * 拆自 src/app/thread/[id].tsx（4 抽 1 留拆分，#8）。
 */

import { useCallback, useEffect } from 'react';
import { Dimensions, StyleSheet } from 'react-native';
import { Text } from '../ui/CompatText';
import type { NativeScrollEvent, NativeSyntheticEvent } from 'react-native';
import Reanimated, {
  useAnimatedStyle,
  useSharedValue,
  withTiming,
  type AnimatedStyle,
} from 'react-native-reanimated';
import { GlassContainer } from 'expo-glass-effect';

import { SymbolView } from '@/components/ui/SymbolView';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { GlassView } from '@/components/ui/GlassView';
import { hapticForScene } from '@/theme/hapticsMap';
import { useThemeColors } from '@/theme/ThemeContext';
import { DURATION } from '@/theme/springs';
import { formatCount } from '@/utils';
import type { ThreadInfo } from '@/types';

const { width: SCREEN_WIDTH } = Dimensions.get('window');
const FLOATING_BAR_WIDTH = SCREEN_WIDTH * 0.72;

// ────────────────────────────────────────────────────────────
// Scroll auto-hide (fully on the UI thread, Issue #1)
// ────────────────────────────────────────────────────────────

export interface FloatingBarAutoHide {
  onScroll: (event: NativeSyntheticEvent<NativeScrollEvent>) => void;
  containerStyle: AnimatedStyle<{ transform: { translateY: number }[] }>;
}

/**
 * 滚动驱动自动隐藏：Shared values（非 React state）保证滚动不触发页面
 * re-render。列表 onScroll 以普通函数语义直接调用（LegendList/ScrollView
 * 均为事件签名)；useAnimatedScrollHandler 返回的对象会触发
 * "TypeError: undefined is not a function"。保持普通函数 + JS 线程设
 * sharedValue（withTiming 动画仍在 UI 线程跑）。
 */
export function useFloatingBarAutoHide(reduceMotion: boolean): FloatingBarAutoHide {
  const barTranslateY = useSharedValue(0);
  const lastScrollY = useSharedValue(0);
  const lastScrollTime = useSharedValue(0);
  const barVisible = useSharedValue(1); // 1 = visible, 0 = hidden
  const lastScrollProcessedAt = useSharedValue(0);
  const reduceMotionSV = useSharedValue(reduceMotion);

  useEffect(() => {
    reduceMotionSV.value = reduceMotion;
  }, [reduceMotion, reduceMotionSV]);

  const onScroll = useCallback((event: NativeSyntheticEvent<NativeScrollEvent>) => {
    const e = event?.nativeEvent ?? event ?? {};
    const y = e?.contentOffset?.y ?? 0;
    const now = Date.now();
    const animateBar = (visible: boolean) => {
      barVisible.value = visible ? 1 : 0;
      barTranslateY.value = reduceMotionSV.value
        ? (visible ? 0 : 120)
        : withTiming(visible ? 0 : 120, { duration: visible ? DURATION.enter : DURATION.exit });
    };

    // Near the top: reveal immediately, never throttle.
    if (y < 10) {
      lastScrollProcessedAt.value = now;
      if (barVisible.value === 0) animateBar(true);
      return;
    }

    // Sample velocity at most every 60ms; mid-list scrolls only drive shared values.
    if (now - lastScrollProcessedAt.value < 60) return;
    lastScrollProcessedAt.value = now;

    const dt = now - lastScrollTime.value;
    const dy = y - lastScrollY.value;
    lastScrollY.value = y;
    lastScrollTime.value = now;

    const velocity = dt > 0 ? dy / dt : 0;
    if (velocity > 0.3 && barVisible.value === 1) {
      animateBar(false);
    } else if (velocity < -0.3 && barVisible.value === 0) {
      animateBar(true);
    }
  }, [reduceMotionSV, barVisible, barTranslateY, lastScrollProcessedAt, lastScrollTime, lastScrollY]);

  const containerStyle = useAnimatedStyle(() => ({
    transform: [{ translateY: barTranslateY.value }],
  }));

  return { onScroll, containerStyle };
}

// ────────────────────────────────────────────────────────────
// Floating bar UI
// ────────────────────────────────────────────────────────────

/** 浮动按钮按压反馈：按下缩到 0.88 */
const pressedScale = ({ pressed }: { pressed: boolean }) => [
  styles.floatingBtn,
  { transform: [{ scale: pressed ? 0.88 : 1 }] },
];

export interface ThreadFloatingBarProps {
  thread: ThreadInfo | null;
  /** 收藏态（star 填充色） */
  isCollected: boolean;
  /** 距屏幕底部 inset（传 insets.bottom） */
  bottom: number;
  /** useFloatingBarAutoHide 返回的动画容器样式 */
  containerStyle: FloatingBarAutoHide['containerStyle'];
  onCopyLink: () => void;
  onAgree: () => void;
  onCollect: () => void;
  onMore: () => void;
}

/**
 * 居中 72% 宽度液态玻璃胶囊（iOS 26 浮动控件风格）。
 * ⚠️ iOS 26 Stack.Toolbar 官方说明：只支持标准按钮，无法承载自定义点赞数
 * 展示；Stack.Toolbar 必须放在页面组件（而非 layout），未来可迁移。
 */
export function ThreadFloatingBar({
  thread,
  isCollected,
  bottom,
  containerStyle,
  onCopyLink,
  onAgree,
  onCollect,
  onMore,
}: ThreadFloatingBarProps) {
  const { colors, isDark } = useThemeColors();

  return (
    <Reanimated.View
      style={[styles.floatingBarWrapper, { bottom }, containerStyle]}
      pointerEvents="box-none"
    >
      <GlassView
        theme={isDark ? 'dark' : 'light'}
        borderRadius={999}
        glassEffectStyle="clear"
        tintColor={isDark ? 'rgba(28,28,30,0.15)' : 'rgba(255,255,255,0.15)'}
        style={styles.floatingBar}
      >
        {/* §5.5: GlassContainer combines child glass views into a unified effect */}
        <GlassContainer spacing={0} style={styles.floatingBarInner}>
          {/* Copy link（与 more 页 'copy' 统一走 handleCopyLink → 同一 Toast） */}
          <HdrPressable
            onPress={() => { hapticForScene('press'); onCopyLink(); }}
            style={pressedScale}
            effect="subtle"
          >
            <SymbolView name="link" size={20} tintColor={colors.text} />
          </HdrPressable>

          {/* Thread agree / like */}
          <HdrPressable
            onPress={onAgree}
            style={pressedScale}
            effect="subtle"
          >
            <SymbolView
              name={thread?.hasAgree ? 'heart.fill' : 'heart'}
              size={20}
              tintColor={thread?.hasAgree ? colors.liked : colors.text}
            />
            {(thread?.zanNum ?? 0) > 0 && (
              <Text style={[styles.floatingAgreeCount, { color: thread?.hasAgree ? colors.liked : colors.textSecondary }]}>
                {formatCount(thread?.zanNum ?? 0)}
              </Text>
            )}
          </HdrPressable>

          {/* Collect / Favorite */}
          <HdrPressable
            onPress={() => { hapticForScene('favorite'); onCollect(); }}
            style={pressedScale}
            effect="subtle"
          >
            <SymbolView
              name={isCollected ? 'star.fill' : 'star'}
              size={20}
              tintColor={isCollected ? '#FFCC00' : colors.text}
            />
          </HdrPressable>

          {/* More menu */}
          <HdrPressable
            onPress={onMore}
            style={pressedScale}
            effect="subtle"
          >
            <SymbolView name="ellipsis" size={20} tintColor={colors.text} />
          </HdrPressable>
        </GlassContainer>
      </GlassView>
    </Reanimated.View>
  );
}

const styles = StyleSheet.create({
  floatingBarWrapper: {
    position: 'absolute',
    left: 0,
    right: 0,
    alignItems: 'center',
    zIndex: 100,
    // Fully transparent — only the floating pill has glass; no side/bottom strips
    backgroundColor: 'transparent',
  },
  floatingBar: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-evenly',
    width: FLOATING_BAR_WIDTH,
    height: 54,
    borderRadius: 999,
    shadowColor: '#000',
    shadowOffset: { width: 0, height: 4 },
    shadowOpacity: 0.06,
    shadowRadius: 16,
    elevation: 4,
  },
  floatingBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 3,
    width: 44,
    height: 44,
    borderRadius: 22,
    borderCurve: 'continuous',
  },
  floatingBarInner: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-evenly',
    flex: 1,
  },
  floatingAgreeCount: {
    fontSize: 11,
    fontWeight: '600',
    fontVariant: ['tabular-nums'],
  },
});