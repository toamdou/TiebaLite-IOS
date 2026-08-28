/**
 * BottomFade — 底部渐罩（index 关注页 / explore 动态页共用）
 *
 * absolute 贴底、transparent → 轻微灰罩（明暗随主题，alpha 0.12）。
 * 底栏液态玻璃叠在纯平背景上时视觉等于实心色带（短列表/空列表/滚到底尤其明显），
 * 渐罩给玻璃背后提供渐变内容可折射；pointerEvents="none" 不挡点击、不挡滚动。
 */

import { StyleSheet } from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { useThemeColors } from '@/theme/ThemeContext';

export function BottomFade() {
  const { isDark } = useThemeColors();
  const tint = isDark ? 'rgba(255,255,255,0.12)' : 'rgba(120,120,128,0.12)';
  return (
    <LinearGradient
      colors={['transparent', tint]}
      locations={[0, 1]}
      pointerEvents="none"
      style={styles.bottomFade}
    />
  );
}

const styles = StyleSheet.create({
  /* 底部渐罩：absolute 贴底 110pt，不参与布局；pointerEvents="none" 过手势 */
  bottomFade: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    height: 110,
  },
});