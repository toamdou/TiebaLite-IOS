// ============================================================
// SymbolView — iOS SF Symbol icon component
// ============================================================
//
// The app targets iOS only, so every icon renders through the
// native SF Symbols API (expo-symbols). No vector-icon fallback
// or second icon package is bundled.
// ============================================================

import type { ComponentProps } from 'react';
import { SymbolView as ExpoSymbolView } from 'expo-symbols';
import type { SFSymbol } from 'sf-symbols-typescript';

// ----------------------------------------------------------------
// Props
// ----------------------------------------------------------------
// 类型与 expo-symbols 原生组件对齐（ComponentProps<typeof ExpoSymbolView>），
// 消除 style/name/weight 三处 any；name 保持宽松 string——调用面大量传动态
// 图标名变量，运行期无效名由原生侧兜底渲染空白（不 crash）。
type ExpoSymbolViewProps = ComponentProps<typeof ExpoSymbolView>;

export interface SymbolViewProps {
  /** SF Symbol 名（宽松 string；无效名由原生侧兜底） */
  name: string;
  /** Symbol 尺寸（默认 24） */
  size?: ExpoSymbolViewProps['size'];
  /** Symbol 字重（默认 'unspecified'） */
  weight?: ExpoSymbolViewProps['weight'];
  /** 着色 */
  tintColor?: ExpoSymbolViewProps['tintColor'];
  /** 容器样式 */
  style?: ExpoSymbolViewProps['style'];
}

// ----------------------------------------------------------------
// Component
// ----------------------------------------------------------------

export function SymbolView({
  name,
  size = 24,
  weight,
  tintColor,
  style,
}: SymbolViewProps) {
  return (
    <ExpoSymbolView
      name={name as SFSymbol}
      size={size}
      tintColor={tintColor}
      style={style}
      weight={weight}
    />
  );
}

export default SymbolView;