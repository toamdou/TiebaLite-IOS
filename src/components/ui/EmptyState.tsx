// ============================================================
// TiebaLite React Native - Empty State View
// 2026-09-09 纯 RN 重写（原为 SwiftUI ContentUnavailableView 包装）：
// 借鉴 panelui-native EmptyState 的设计——图标小卡背后扇形叠两张
// 幽灵卡（rotate ±8°）作视觉锚，标题/描述居中一列，动作槽在下。
// 文案原则同文：「说清这里本来会有什么、怎么搞到内容」——调用方
// 传 description，别让空列表读起来像加载失败。
// 纯 RN 化顺带根除 SwiftUI 空态在 LegendList header 内初次测量塌缩
// 的前科（消息页/UserTabList 的 minHeight 补丁即为此而打）。
// ============================================================

import {
  StyleSheet,
  View,
  type StyleProp,
  type ViewStyle,
} from 'react-native';

import { Spacing, RadiusStyle } from '@/theme';
import { typographyStyles } from '@/theme/typography';
import { useThemeColors } from '@/theme/ThemeContext';
import { Text } from './CompatText';
import { SymbolView } from './SymbolView';
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
  const { colors } = useThemeColors();
  const prefix = kind === 'error' ? '错误' : '空状态';
  const ghostTone = { backgroundColor: colors.card, borderColor: colors.borderCard };

  return (
    <View
      style={[styles.container, style]}
      // 注意：容器不设 accessibilityRole（曾用 "text" 会把内部按钮语义吞掉）。
      // 整个区域一条无障碍标签（文档原则：一个区域只播报一次，图标装饰不进树）。
      accessibilityLabel={
        accessibilityLabel ??
        `${prefix}：${title}${description ? `，${description}` : ''}`
      }
    >
      {/* 视觉锚：图标小卡 + 背后两张旋转幽灵卡（声明顺序即层级，幽灵在下） */}
      <View style={styles.mediaWrap} accessible={false}>
        <View style={[styles.ghostCard, styles.ghostLeft, ghostTone]} />
        <View style={[styles.ghostCard, styles.ghostRight, ghostTone]} />
        <View style={[styles.iconCard, { backgroundColor: colors.surfaceSecondary, borderColor: colors.borderCard }]}>
          <SymbolView name={icon as any} size={24} tintColor={colors.textTertiary} />
        </View>
      </View>

      <Text style={[styles.title, { color: colors.text }]}>{title}</Text>
      {description ? (
        <Text style={[styles.description, { color: colors.textSecondary }]}>{description}</Text>
      ) : null}

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

/** 视觉锚几何：幽灵卡与图标卡同尺寸 56，锚容器 72 留出扇形外溢 */
const MEDIA_CARD = 56;
const MEDIA_WRAP = 72;

const styles = StyleSheet.create({
  container: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: Spacing.page,
    paddingHorizontal: Spacing.lg,
  },

  mediaWrap: {
    width: MEDIA_WRAP,
    height: MEDIA_WRAP,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: Spacing.lg,
  },
  // 幽灵卡：与图标卡同形，rotate ±8° + 左右各偏 7pt 扇形展开
  ghostCard: {
    position: 'absolute',
    width: MEDIA_CARD,
    height: MEDIA_CARD,
    ...RadiusStyle.input,
    borderWidth: StyleSheet.hairlineWidth,
    borderCurve: 'continuous',
  },
  ghostLeft: {
    transform: [{ rotate: '-8deg' }, { translateX: -7 }, { translateY: -1 }],
  },
  ghostRight: {
    transform: [{ rotate: '8deg' }, { translateX: 7 }, { translateY: -1 }],
  },
  iconCard: {
    width: MEDIA_CARD,
    height: MEDIA_CARD,
    ...RadiusStyle.input,
    borderWidth: StyleSheet.hairlineWidth,
    borderCurve: 'continuous',
    alignItems: 'center',
    justifyContent: 'center',
  },

  title: {
    ...typographyStyles.title3,
    textAlign: 'center',
  },
  description: {
    ...typographyStyles.subhead,
    textAlign: 'center',
    marginTop: 6,
    // 长描述限宽换行，避免一行拉满屏
    maxWidth: 300,
  },

  actionContainer: {
    marginTop: Spacing.lg,
  },
});

export default EmptyState;
