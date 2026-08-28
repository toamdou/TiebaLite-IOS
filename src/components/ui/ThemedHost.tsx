/**
 * ThemedHost — @expo/ui Host wrapper that auto-passes colorScheme
 *
 * Fixes: SwiftUI Host defaults to light mode unless colorScheme is explicitly set.
 * This wrapper reads the app's dark mode state and propagates it to the native layer.
 */
import React from 'react';
import { Host } from '@expo/ui/swift-ui';
import { useThemeColors } from '@/theme/ThemeContext';

export function ThemedHost(props: React.ComponentProps<typeof Host>) {
  const { isDark } = useThemeColors();
  return <Host {...props} colorScheme={isDark ? 'dark' : 'light'} />;
}
