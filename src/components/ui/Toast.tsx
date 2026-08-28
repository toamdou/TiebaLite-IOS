 
// ============================================================
// TiebaLite React Native - Lightweight Toast Notification
// Auto-dismissing, non-intrusive popup messages
// ============================================================

import {
  useCallback,
  useEffect,
  useImperativeHandle,
  forwardRef,
  useRef,
  useState,
} from 'react';
import { StyleSheet, View } from 'react-native';
import { Text } from './CompatText';
import Animated, { useSharedValue, useAnimatedStyle, withSpring, withTiming, cancelAnimation, Easing, FadeIn, FadeOut } from 'react-native-reanimated';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { SymbolView } from '@/components/ui/SymbolView';
import { GlassView } from '@/components/ui/GlassView';
import { useReducedMotion } from '@/hooks/useReducedMotion';

import { useThemeColors } from '@/theme/ThemeContext';
import {Shadows, Spacing, typographyStyles, PRESS_ENTER, RadiusStyle, Radius, DURATION} from '@/theme';
import type { SemanticColors } from '@/theme/colors';

// ---------- Toast Types ----------
export type ToastType = 'info' | 'success' | 'warning' | 'error';

// ---------- Toast Options ----------
export interface ToastOptions {
  title: string;
  message?: string;
  type?: ToastType;
  duration?: number; // ms, default 3000
  icon?: string; // SF Symbol name override
}

// ---------- Toast Ref (imperative API) ----------
export interface ToastRef {
  show: (options: ToastOptions) => void;
  hide: () => void;
}

// ---------- Type Config Helper ----------
interface TypeConfig {
  color: string;
  icon: string;
  label: string;
}

// 颜色走语义令牌：success/warning/error/tint，深浅色自适应
function getTypeConfig(type: ToastType, colors: SemanticColors): TypeConfig {
  switch (type) {
    case 'success':
      return { color: colors.success, icon: 'checkmark.circle.fill', label: '成功' };
    case 'warning':
      return { color: colors.warning, icon: 'exclamationmark.triangle.fill', label: '警告' };
    case 'error':
      return { color: colors.error, icon: 'xmark.circle.fill', label: '错误' };
    case 'info':
    default:
      return { color: colors.tint, icon: 'info.circle.fill', label: '信息' };
  }
}

// ---------- Toast Component ----------
export const Toast = forwardRef<ToastRef>(function Toast(_props, ref) {
  const { colors } = useThemeColors();
  const { reduceMotion } = useReducedMotion();
  const insets = useSafeAreaInsets();
  const [visible, setVisible] = useState(false);
  const [options, setOptions] = useState<ToastOptions>({ title: '' });

  const translateY = useSharedValue(-100);
  const opacity = useSharedValue(0);
  const hideTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const clearHideTimer = useCallback(() => {
    if (hideTimerRef.current) {
      clearTimeout(hideTimerRef.current);
      hideTimerRef.current = null;
    }
  }, []);

  const hide = useCallback(() => {
    clearHideTimer();
    cancelAnimation(translateY);
    cancelAnimation(opacity);
    if (reduceMotion) {
      opacity.value = withTiming(0, { duration: 100 });
      hideTimerRef.current = setTimeout(() => setVisible(false), 120);
    } else {
      translateY.value = withTiming(-80, { duration: 150, easing: Easing.in(Easing.quad) });
      opacity.value = withTiming(0, { duration: 150, easing: Easing.in(Easing.quad) });
      hideTimerRef.current = setTimeout(() => setVisible(false), 170);
    }
  }, [reduceMotion, opacity, translateY, clearHideTimer]);

  const show = useCallback((opts: ToastOptions) => {
    clearHideTimer();
    setOptions(opts);
    setVisible(true);

    // Cancel any in-flight animation (interruptibility)
    cancelAnimation(translateY);
    cancelAnimation(opacity);

    if (reduceMotion) {
      // 仅 opacity 淡入，无位移
      translateY.value = 0;
      opacity.value = withTiming(1, { duration: 200 });
    } else {
      translateY.value = withSpring(0, PRESS_ENTER);
      opacity.value = withTiming(1, { duration: 200 });
    }

    const duration = opts.duration ?? 3000;
    hideTimerRef.current = setTimeout(() => {
      hide();
    }, duration);
  }, [reduceMotion, hide, clearHideTimer, opacity, translateY]);

  useEffect(
    () => () => clearHideTimer(),
    [clearHideTimer],
  );

  useImperativeHandle(ref, () => ({ show, hide }), [show, hide]);

  const animatedStyle = useAnimatedStyle(() => ({
    transform: [{ translateY: translateY.value }],
    opacity: opacity.value,
  }));

  if (!visible) return null;

  const typeConfig = getTypeConfig(options.type ?? 'info', colors);

  const accessibilityProps = {
    accessibilityRole: 'alert' as const,
    accessibilityLiveRegion: 'polite' as const,
    accessibilityLabel: `${typeConfig.label}: ${options.title}${options.message ? `. ${options.message}` : ''}`,
  };

  const content = (
    <>
      <View style={styles.iconContainer}>
        <SymbolView
          name={(options.icon ?? typeConfig.icon) as any}
          size={20}
          weight="medium"
          tintColor={typeConfig.color}
        />
      </View>
      <View style={styles.textContainer}>
        <Text
          style={[typographyStyles.subheadBold, { color: colors.text }]}
          numberOfLines={1}
        >
          {options.title}
        </Text>
        {options.message ? (
          <Text
            style={[typographyStyles.footnote, { color: colors.textSecondary, marginTop: 2 }]}
            numberOfLines={2}
          >
            {options.message}
          </Text>
        ) : null}
      </View>
    </>
  );

  // §5.2 — iOS 26 liquid glass capsule. GlassView owns the platform fallback,
  // so there is no separate non-glass render branch. 玻璃不带实底色，让
  // 模糊透出；阴影走 Shadows.floating 令牌。
  // 顶部胶囊必须落到导航栏下缘之下：旧值固定 60pt 藏在原生导航栏
  //（含状态栏 ~100pt）背后，真机“复制无 toast”根因（2026-08-27）。
  return (
    <Animated.View
      style={[animatedStyle, styles.container, { top: insets.top + 64 }]}
      {...accessibilityProps}
    >
      <GlassView
        glassEffectStyle="regular"
        isInteractive={false}
        borderRadius={Radius.input}
        style={styles.body}
      >
        {content}
      </GlassView>
    </Animated.View>
  );
});

// ---------- Styles ----------
const styles = StyleSheet.create({
  container: {
    position: 'absolute',
    left: Spacing.md,
    right: Spacing.md,
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: Spacing.md,
    paddingVertical: Spacing.sm,
    // 统一阴影令牌：floating（悬浮浮层）
    ...Shadows.floating,
    zIndex: 9999,
  },
  // 玻璃体自身：圆角须与 wrapper padding 对齐（外层 View 只承担定位/布局）
  body: {
    ...RadiusStyle.input,
  },
  iconContainer: {
    width: 28,
    height: 28,
    alignItems: 'center',
    justifyContent: 'center',
    marginRight: Spacing.sm,
  },
  textContainer: {
    flex: 1,
  },
});

export default Toast;

// ─────────────────────────────────────────────────────────────
// 第二套 Toast 体系：底部药丸提示（全局单例，showToast 命令式调用）
// ─────────────────────────────────────────────────────────────
// 与上方浮层 Toast（Animated.View + GlassView）分区：
//   · 上方 = 受主题语义色驱动的玻璃胶囊（title/message/icon，3s 自动消失）
//   · 下方 = 无图标、屏幕底部小药丸、自动消失免点击
// 根布局挂载 <ToastHost /> 一次，任意位置调用 showToast('保存成功')；
// 连续调用重置计时并重放动画。

const PILL_DURATION_MS = 2400;

let currentPillShow: ((message: string) => void) | null = null;

/** 屏幕底部弹出药丸型提示，自动消失（无需用户确认） */
export function showToast(message: string) {
  if (__DEV__) console.log(`[toast] show: ${message}`);
  currentPillShow?.(message);
}

export function ToastHost() {
  const insets = useSafeAreaInsets();
  const [pillMessage, setPillMessage] = useState<string | null>(null);
  // 每次调用自增：换 key 重放进入动画（连续提示也可见）
  const pillSeqRef = useRef(0);
  const pillTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(() => {
    currentPillShow = (msg) => {
      pillSeqRef.current += 1;
      setPillMessage(msg);
      if (pillTimerRef.current) clearTimeout(pillTimerRef.current);
      pillTimerRef.current = setTimeout(() => setPillMessage(null), PILL_DURATION_MS);
    };
    return () => {
      currentPillShow = null;
      if (pillTimerRef.current) clearTimeout(pillTimerRef.current);
    };
  }, []);

  if (!pillMessage) return null;

  return (
    <Animated.View
      key={pillSeqRef.current}
      entering={FadeIn.duration(DURATION.enter)}
      exiting={FadeOut.duration(DURATION.exit)}
      pointerEvents="none"
      style={[stylesPill.pill, { bottom: insets.bottom + 96 }]}
    >
      <Text style={stylesPill.pillText} numberOfLines={1}>
        {pillMessage}
      </Text>
    </Animated.View>
  );
}

const stylesPill = StyleSheet.create({
  pill: {
    position: 'absolute',
    alignSelf: 'center',
    maxWidth: '82%',
    // 固定深色药丸为设计意图：轻量系统提示与主题无关、不随深浅色变化
    // （与上方浮层 Toast 的语义色玻璃体系刻意区分；数值保持原样不令牌化）。
    backgroundColor: 'rgba(28, 28, 30, 0.88)',
    borderRadius: 18,
    borderCurve: 'continuous',
    paddingHorizontal: 16,
    paddingVertical: 9,
    shadowColor: '#000',
    shadowOpacity: 0.18,
    shadowRadius: 10,
    shadowOffset: { width: 0, height: 3 },
    elevation: 6,
  },
  pillText: {
    // 白色文字与深色药丸配对，同样为设计意图
    color: '#FFFFFF',
    fontSize: 13,
    fontWeight: '500',
    textAlign: 'center',
  },
});
