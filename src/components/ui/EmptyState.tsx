// ============================================================
// TiebaLite React Native - Empty State View
// Native SwiftUI ContentUnavailableView with optional action.
// ============================================================

import {
  StyleSheet,
  View,
  type StyleProp,
  type ViewStyle,
} from 'react-native';
import { ContentUnavailableView } from '@expo/ui/swift-ui';

import { Spacing } from '@/theme';
import { ThemedHost } from './ThemedHost';
import { Button } from './Button';

// ---------- StateKind / StateView（EmptyState/ErrorState 共用实现） ----------
export type StateKind = 'empty' | 'error';

/** 内部共享实现（仅 EmptyState/ErrorState 两个薄包装使用），非公共 API。 */
export interface StateViewProps {
  /** 语义：'empty' 空状态文案前缀 / 'error' 错误前缀 */
  kind: StateKind;
  /** SF Symbol name for the placeholder icon */
  icon: string;
  /** Main title text */
  title: string;
  /** Descriptive subtitle text */
  description?: string;
  /** Optional action button block */
  action?: {
    label: string;
    onPress?: () => void;
    /** Declarative route for action button (replaces onPress for navigation) */
    href?: string;
    /** Button variant: empty=filled / error=tinted（各包装自带） */
    variant: 'filled' | 'tinted';
    /** Leading SF Symbol name */
    icon?: string;
  };
  /** Custom style */
  style?: StyleProp<ViewStyle>;
  /** Accessibility label */
  accessibilityLabel?: string;
}

export function StateView({
  kind,
  icon,
  title,
  description,
  action,
  style,
  accessibilityLabel,
}: StateViewProps) {
  const prefix = kind === 'error' ? '错误' : '空状态';

  return (
    <View
      style={[styles.container, style]}
      // 注意：容器不设 accessibilityRole（曾用 "text" 会把内部按钮语义吞掉）。
      accessibilityLabel={
        accessibilityLabel ??
        `${prefix}：${title}${description ? `，${description}` : ''}`
      }
    >
      <ThemedHost matchContents>
        <ContentUnavailableView
          title={title}
          description={description}
          systemImage={icon as any}
        />
      </ThemedHost>

      {action ? (
        <View style={styles.actionContainer}>
          <Button
            title={action.label}
            onPress={action.onPress}
            href={action.href}
            variant={action.variant}
            size="medium"
            icon={action.icon}
          />
        </View>
      ) : null}
    </View>
  );
}

// ---------- EmptyState Props ----------
export interface EmptyStateProps {
  /** SF Symbol name for the placeholder icon */
  icon?: string;
  /** Main title text */
  title: string;
  /** Descriptive subtitle text */
  description?: string;
  /** Action button label (shows button if provided) */
  actionLabel?: string;
  /** Action button callback */
  onAction?: () => void;
  /** Declarative route for action button (replaces onAction for navigation) */
  actionHref?: string;
  /** Custom style */
  style?: StyleProp<ViewStyle>;
  /** Accessibility label */
  accessibilityLabel?: string;
}

// ---------- EmptyState Component（薄包装：参数归一后交给 StateView） ----------
export function EmptyState({
  icon = 'tray',
  title,
  description,
  actionLabel,
  onAction,
  actionHref,
  style,
  accessibilityLabel,
}: EmptyStateProps) {
  return (
    <StateView
      kind="empty"
      icon={icon}
      title={title}
      description={description}
      style={style}
      accessibilityLabel={accessibilityLabel}
      action={
        actionLabel && (onAction || actionHref)
          ? { label: actionLabel, onPress: onAction, href: actionHref, variant: 'filled' }
          : undefined
      }
    />
  );
}

// ---------- Styles ----------
const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: Spacing.page,
    paddingHorizontal: Spacing.lg,
  },
  actionContainer: {
    marginTop: Spacing.lg,
  },
});

export default EmptyState;