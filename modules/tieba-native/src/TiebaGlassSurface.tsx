import { requireNativeViewManager } from 'expo-modules-core';
import type { ReactNode } from 'react';
import {
  Pressable,
  StyleSheet,
  View,
  useColorScheme,
  type StyleProp,
  type ViewStyle,
} from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { useReducedMotion } from '@/hooks/useReducedMotion';
import { useGlassBudget } from '@/hooks/useGlassBudget';
import { glassTokens } from '@/theme/glass';

const NativeGlassSurface = requireNativeViewManager(
  'TiebaNative',
  'TiebaGlassSurfaceView',
);

export interface GlassSurfaceProps {
  /**
   * 系统材质（默认 "regular"）。
   * "regular" | "clear"（最接近液态玻璃透明）| "dark" | "light"，或系统材质全名
   * 如 "systemThinMaterial"、"systemMaterialDark"。
   */
  material?: string;
  /**
   * 材质着色（UIVisualEffectView 无直接 tint，原生用覆盖半透明色层实现）。
   * 建议传 alpha ≤ 0.15 的颜色，如 'rgba(255,255,255,0.1)'。
   */
  tintColor?: string;
  /** squircle 连续曲率圆角（默认 20） */
  cornerRadius?: number;
  /** hairline 描边色（缺省走 glassTokens.border） */
  borderColor?: string;
  /** 顶部高光（默认 true；深色模式原生自动减弱） */
  highlight?: boolean;
  /** 容器样式（宽高/布局；圆角请走 cornerRadius prop） */
  style?: StyleProp<ViewStyle>;
  /** 可选按压回调（导航下浮条等可点场景） */
  onPress?: () => void;
  /** 内容层（原生盖在玻璃材质之上） */
  children?: ReactNode;
}

/**
 * 静态玻璃降级容器（超预算 / reduceTransparency 时替代原生 UIVisualEffectView）：
 * 半透明 tint 底 + 顶部高光渐变 + 细描边（仅带圆角时，避免盖掉外层自带边框）。
 * 与 GlassView 的 StaticGlassFallback 同一套 glassTokens 模拟，零实时高斯开销。
 * onPress 走 RN Pressable，按压语义与原生一致。
 */
function StaticGlassSurface({
  tintColor,
  cornerRadius,
  borderColor,
  highlight,
  style,
  onPress,
  children,
}: GlassSurfaceProps) {
  const resolvedTheme: 'light' | 'dark' =
    useColorScheme() === 'dark' ? 'dark' : 'light';
  const tint = tintColor ?? glassTokens.tint[resolvedTheme];
  const highlightColors = glassTokens.highlight[resolvedTheme];
  const border = borderColor ?? glassTokens.border[resolvedTheme];
  const borderWidth = glassTokens.border.width;

  const containerStyle: StyleProp<ViewStyle> = [
    cornerRadius != null
      ? { borderRadius: cornerRadius, overflow: 'hidden' as const }
      : undefined,
    style,
  ];

  const layers = (
    <>
      {/* 半透明底色（staticGlass 用 tint 令牌，弱化纯色断档） */}
      <View
        style={[StyleSheet.absoluteFill, { backgroundColor: tint }]}
        pointerEvents="none"
      />
      {/* 顶部高光渐变，静态渲染一次（highlight=false 时不画） */}
      {highlight !== false && (
        <LinearGradient
          colors={highlightColors}
          start={{ x: 0, y: 0 }}
          end={{ x: 0, y: 1 }}
          style={StyleSheet.absoluteFill}
          pointerEvents="none"
        />
      )}
      {/* 细描边（仅带圆角的玻璃面，与原生 squircle 描边语义一致） */}
      {cornerRadius != null && (
        <View
          style={[
            StyleSheet.absoluteFill,
            { borderRadius: cornerRadius, borderWidth, borderColor: border },
          ]}
          pointerEvents="none"
        />
      )}
      {children}
    </>
  );

  if (onPress) {
    return (
      <Pressable style={containerStyle} onPress={onPress}>
        {layers}
      </Pressable>
    );
  }
  return <View style={containerStyle}>{layers}</View>;
}

/**
 * 原生玻璃容器：UIVisualEffectView 系统材质 + squircle 圆角 + hairline 描边 +
 * 可选顶部高光。用于导航下玻璃、浮条、分组标题。哑视图，不接页面。
 *
 * 性能规则 2（每屏实时玻璃最多 1 处）：挂载时参与 useGlassBudget 模块级计数，
 * 超预算或 reduceTransparency 开启时降级为 StaticGlassSurface（RN 静态玻璃模拟），
 * props 接口不变，降级仅在内部决定。
 */
export function GlassSurface({
  material,
  tintColor,
  cornerRadius = 20,
  borderColor,
  highlight,
  style,
  onPress,
  children,
}: GlassSurfaceProps) {
  // §5.12 — Respect "Reduce Transparency" accessibility setting
  const { reduceTransparency } = useReducedMotion();
  // 性能规则 2 — 实时玻璃预算：超预算同样降级（任一触发即降级，与 GlassView 一致）
  const { shouldUseStaticGlass } = useGlassBudget();

  const needsStaticFallback = reduceTransparency || shouldUseStaticGlass;

  if (needsStaticFallback) {
    return (
      <StaticGlassSurface
        tintColor={tintColor}
        cornerRadius={cornerRadius}
        borderColor={borderColor}
        highlight={highlight}
        style={style}
        onPress={onPress}
      >
        {children}
      </StaticGlassSurface>
    );
  }

  return (
    <NativeGlassSurface
      style={style}
      material={material}
      tintColor={tintColor}
      cornerRadius={cornerRadius}
      borderColor={borderColor}
      highlight={highlight}
      onPress={onPress}
    >
      {children}
    </NativeGlassSurface>
  );
}

export default GlassSurface;
