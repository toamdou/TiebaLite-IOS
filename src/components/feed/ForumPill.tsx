// ============================================================
// TiebaLite - Forum pill (可点击的吧名入口)
// 历史页（history）与收藏页（threadstore）共用：meta 里的吧名药丸入口，
// 内含 pill 样式与冒泡阻断（stopPropagation，@/utils/gesture），点击不触发整卡导航。
// ============================================================

import { Pressable, StyleSheet, View } from 'react-native';
import { Text } from '../ui/CompatText';
import { useThemeColors } from '@/theme/ThemeContext';
import { typographyStyles } from '@/theme';
import { stopPropagation } from '@/utils/gesture';
import { hapticForScene } from '@/theme/hapticsMap';

/** meta 里可点击的吧名入口（药丸背景；阻断冒泡，不触发整卡导航） */
export function ForumPill({
  forumName,
  onPress,
  color,
}: {
  forumName: string;
  onPress: () => void;
  color: string;
}) {
  const { colors } = useThemeColors();
  return (
    <Pressable
      onPress={(e) => { stopPropagation(e); void hapticForScene('press'); onPress(); }}
      onPressIn={stopPropagation}
      onPressOut={stopPropagation}
      hitSlop={6}
      accessibilityRole="button"
      accessibilityLabel={`进入${forumName}吧`}
    >
      <View style={[styles.forumPill, { backgroundColor: colors.surfaceSecondary }]}>
        <Text style={[styles.metaForum, { color }]} numberOfLines={1}>
          {forumName}
        </Text>
      </View>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  // 内容区 meta 吧名：药丸背景（对齐热榜吧名 chip 样式）
  forumPill: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderRadius: 8,
    borderCurve: 'continuous',
  },
  metaForum: typographyStyles.caption1Bold,
});