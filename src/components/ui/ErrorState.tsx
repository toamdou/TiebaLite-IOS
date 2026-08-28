// ============================================================
// TiebaLite React Native - Error State View
// Native SwiftUI ContentUnavailableView with retry action.
// ============================================================

import type { StyleProp, ViewStyle } from 'react-native';

import { StateView } from './EmptyState';

// ---------- ErrorState Props ----------
export interface ErrorStateProps {
  /** Main error title */
  title?: string;
  /** Detailed error message */
  message?: string;
  /** Error icon name (SF Symbol) */
  icon?: string;
  /** Called when retry is pressed */
  onRetry?: () => void;
  /** Retry button label */
  retryLabel?: string;
  /** Custom style */
  style?: StyleProp<ViewStyle>;
  /** Accessibility label */
  accessibilityLabel?: string;
}

// ---------- ErrorState Component（薄包装：参数归一后交给 StateView） ----------
export function ErrorState({
  title = '出错了',
  message,
  icon = 'exclamationmark.triangle',
  onRetry,
  retryLabel = '重试',
  style,
  accessibilityLabel,
}: ErrorStateProps) {
  return (
    <StateView
      kind="error"
      icon={icon}
      title={title}
      description={message}
      style={style}
      accessibilityLabel={accessibilityLabel}
      action={
        onRetry
          ? { label: retryLabel, onPress: onRetry, variant: 'tinted', icon: 'arrow.clockwise' }
          : undefined
      }
    />
  );
}

export default ErrorState;