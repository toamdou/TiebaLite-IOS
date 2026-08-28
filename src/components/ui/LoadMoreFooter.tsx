/**
 * LoadMoreFooter — footer states for infinite lists.
 *
 * Loading is driven by LegendList's onEndReached (virtualization
 * threshold) rather than a per-frame JS onScroll handler. The footer
 * itself is static, so scrolling never triggers a React state update.
 */

import { ActivityIndicator, View, StyleSheet } from 'react-native';
import { Text } from './CompatText';

import {Spacing, Radius} from '@/theme';
import { typographyStyles } from '@/theme/typography';
import type { SemanticColors } from '@/theme/colors';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { hapticForScene } from '@/theme/hapticsMap';

// ────────────────────────────────────────────────────────────
// Footer component
// ────────────────────────────────────────────────────────────

export interface LoadMoreFooterProps {
  hasMore: boolean;
  loading: boolean;
  colors: Pick<SemanticColors, 'primary' | 'textTertiary'>;
  onLoadMore: () => void;
}

export function LoadMoreFooter({
  hasMore,
  loading,
  colors,
  onLoadMore,
}: LoadMoreFooterProps) {
  if (loading) {
    return (
      <View style={styles.container}>
        <ActivityIndicator size="small" color={colors.primary} />
        <Text style={[styles.text, { color: colors.textTertiary }]}>加载中...</Text>
      </View>
    );
  }

  if (!hasMore) {
    return (
      <View style={styles.container}>
        <Text style={[styles.noMoreText, { color: colors.textTertiary }]}>
          没有更多了
        </Text>
      </View>
    );
  }

  return (
    <HdrPressable
      onPress={() => {
        void hapticForScene('press');
        onLoadMore();
      }}
      accessibilityRole="button"
      accessibilityLabel="加载更多"
      style={({ pressed }) => [
        styles.container,
        styles.button,
        { opacity: pressed ? 0.7 : 1 },
      ]}
    >
      <Text style={[styles.text, { color: colors.primary }]}>加载更多</Text>
    </HdrPressable>
  );
}

// ────────────────────────────────────────────────────────────
// Styles
// ────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: Spacing.xl,
    gap: 10,
  },
  button: {
    alignSelf: 'center',
    paddingHorizontal: Spacing.xxl,
    borderRadius: Radius.capsule,
    marginVertical: Spacing.xs,
  },
  text: {
    ...typographyStyles.footnoteBold,
  },
  noMoreText: {
    ...typographyStyles.caption1,
    fontWeight: '500',
  },
});

export default LoadMoreFooter;