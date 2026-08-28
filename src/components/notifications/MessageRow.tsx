// ============================================================
// TiebaLite React Native - MessageRow — 消息行渲染子组件集（notifications tab 专用）
//
// 从 notifications.tsx 拆出：AvatarPressable 用户点击封装、类型图标/分段文案
// 映射、key 提取器与消息行样式。MessageTabList 与 notifications.tsx 均从这里
// 导入，保持单向依赖。
//
// 首屏入场 EntranceRow 收敛到公共版 @/components/feed/EntranceRow（原本地副本
// 缺少「首屏后零开销直出」优化——每行常驻 Animated.View + shared value +
// worklet，长列表滚动挂载路径上是纯常驻成本；此处 re-export 保持旧导入面不变）。
// ============================================================

import { memo, type ReactNode } from 'react';
import { Pressable, StyleSheet, type StyleProp, type ViewStyle } from 'react-native';
import {Spacing, typographyStyles, RadiusStyle} from '@/theme';
import { stopPropagation } from '@/utils/gesture';
import type { SemanticColors } from '@/theme/colors';
import type { MessageItem } from '@/types';
import { hapticForScene } from '@/theme/hapticsMap';

export type MessageTab = 'reply' | 'at' | 'agree';

/** getMoreMsg 合并查询返回的条目：原 MessageItem + 分类打标 category */
export type CategorizedMessage = MessageItem & { category: MessageTab };

// 合并流中不同分类可能产生重复 id，键加分类前缀避免 LegendList 复用冲突
export const messageKeyExtractor = (item: CategorizedMessage) => `${item.category}:${item.id}`;

/** 公共首屏入场组件（feed 版：首屏批次后逐行零动画壳直出） */
export { EntranceRow } from '@/components/feed/EntranceRow';

export function getSegmentLabel(tab: MessageTab): string {
  switch (tab) {
    case 'reply': return '回复消息';
    case 'at': return '@消息';
    case 'agree': return '赞消息';
  }
}

/** 类型图标（SF Symbol）与颜色：回复 / @ / 点赞 可一眼区分 */
export function getTypeIcon(
  type: CategorizedMessage['category'],
  colors: SemanticColors,
): { name: string; color: string } {
  switch (type) {
    // 主题无"回复/提到/点赞"独立语义色，取语义色系变体：
    // reply=主题 tint（primary/info 同源）、at=warning 橙、agree=success 绿
    case 'reply': return { name: 'arrowshape.turn.up.left.fill', color: colors.tint };
    case 'at': return { name: 'at', color: colors.warning };
    case 'agree': return { name: 'hand.thumbsup.fill', color: colors.success };
  }
}

/**
 * 头像 / 昵称的"查看用户"点击封装：点击跳转作者主页，并阻止事件冒泡
 * （避免触发整行的消息点击）。
 */
export const AvatarPressable = memo(function AvatarPressable({
  msg,
  onAuthorPress,
  style,
  children,
}: {
  msg: MessageItem;
  onAuthorPress: (msg: MessageItem) => void;
  style?: StyleProp<ViewStyle>;
  children: ReactNode;
}) {
  return (
    <Pressable
      onPress={(event) => {
        stopPropagation(event);
        void hapticForScene('press');
        onAuthorPress(msg);
      }}
      onPressIn={stopPropagation}
      onPressOut={stopPropagation}
      accessibilityRole="button"
      accessibilityLabel="查看用户"
      style={style}
    >
      {children}
    </Pressable>
  );
});

/** 消息行样式（行容器/未读点/头像按压/正文） */
export const messageRowStyles = StyleSheet.create({
  messageRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: 10,
    ...RadiusStyle.card,
    padding: Spacing.md,
    marginBottom: Spacing.sm,
    position: 'relative',
  },
  messageAvatarPressable: {
    ...RadiusStyle.card,
  },
  messageNamePressable: {
    flexShrink: 1,
  },
  // 未读红点：定位到头像右上角（行内边距 12 + 头像 40 → 头像右缘 x=52，
  // 圆点 8x8 骑在右上角：left=48/top=8）
  unreadDot: {
    position: 'absolute',
    top: 8,
    left: 48,
    width: 8,
    height: 8,
    borderRadius: 4,
    borderCurve: 'continuous',
  },
  messageBody: { flex: 1, gap: 3 },
  messageHeader: { flexDirection: 'row', alignItems: 'center', gap: Spacing.sm },
  messageName: { flexShrink: 1, ...typographyStyles.subheadBold },
  // 14→subhead(15)：差 1pt 在容差内；lineHeight 20 与 subhead 完全一致
  messageContent: { ...typographyStyles.subhead },
  messageThread: { ...typographyStyles.caption1 },
  messageTime: { ...typographyStyles.caption2 },
});