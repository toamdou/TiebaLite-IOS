/**
 * useFormTint — 设置页 Form 环境染色修饰符（SwiftUI .tint 向下传播）。
 *
 * 跟随主题主色：Form 内原生行（SF 图标、Picker 选中值、开关、按钮）统一染色；
 * 主题为「默认」（初始内置态）时返回空数组 = 不染色，行图标保持五彩
 * （与 settings/index.tsx 的 RowIcon 五彩态配套，2026-08-28 用户要求）。
 */

import { tint } from '@expo/ui/swift-ui/modifiers';
import { useThemeColors } from '@/theme/ThemeContext';

export function useFormTint() {
  const { colors, themeName } = useThemeColors();
  return themeName === 'default' ? [] : [tint(colors.primary)];
}
