/**
 * 精品分类选择（原生 bottom sheet，从 app/forum/[name].tsx 拆出）。
 */

import React, { useCallback } from 'react';
import { View, StyleSheet } from 'react-native';
import { Text } from '../ui/CompatText';
import BottomSheetComponent, { BottomSheetScrollView } from '@expo/ui/community/bottom-sheet';

import { SymbolView } from '@/components/ui/SymbolView';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { hapticForScene } from '@/theme/hapticsMap';
import { Spacing } from '@/theme';
import { typographyStyles } from '@/theme/typography';
import type { GoodClassifyItem } from '@/stores/forumStore';

export const ClassifyPickerSheet = React.memo(function ClassifyPickerSheet({
  visible,
  onClose,
  goodClassify,
  goodClassifyId,
  setGoodClassifyId,
  colors,
}: {
  visible: boolean;
  onClose: () => void;
  goodClassify: GoodClassifyItem[];
  goodClassifyId: string | null;
  setGoodClassifyId: (id: string | null) => void;
  colors: any;
}) {
  const handleSelect = useCallback(
    (classId: string | null) => {
      hapticForScene('toggle');
      setGoodClassifyId(classId);
      onClose();
    },
    [setGoodClassifyId, onClose],
  );

  return (
    <BottomSheetComponent
      index={visible ? 0 : -1}
      snapPoints={['40%']}
      enablePanDownToClose
      onClose={onClose}
    >
      <BottomSheetScrollView
        style={styles.classifySheetScroll}
        contentContainerStyle={styles.classifySheetContent}
        showsVerticalScrollIndicator={false}
        bounces={false}
      >
        <Text style={[styles.menuTitle, { color: colors.textSecondary }]}>选择分类</Text>
        <HdrPressable
          // effect="subtle"：无白闪高光（用户反馈 sheet 菜单项不要 HDR flash），
          // 保留 pressed opacity 0.7 反馈；直出 Plain Pressable，零动画开销
          // （同时避免 sheet 关闭卸载时 reanimated 动画在途的崩溃风险）。
          effect="subtle"
          style={({ pressed }) => [styles.menuItem, { opacity: pressed ? 0.7 : 1 }]}
          onPress={() => {
            void hapticForScene('toggle');
            handleSelect(null);
          }}
          accessibilityRole="button"
          accessibilityLabel="全部"
        >
          <Text style={[styles.menuItemText, { color: colors.text }]}>全部</Text>
          <View style={{ flex: 1 }} />
          {goodClassifyId === null && (
            <SymbolView name="checkmark" size={16} weight="semibold" tintColor={colors.primary} />
          )}
        </HdrPressable>
        {goodClassify.map((c) => {
          const selected = goodClassifyId === c.classId;
          return (
            <HdrPressable
              key={c.classId}
              effect="subtle"
              style={({ pressed }) => [styles.menuItem, { opacity: pressed ? 0.7 : 1 }]}
              onPress={() => {
            void hapticForScene('toggle');
            handleSelect(c.classId);
          }}
              accessibilityRole="button"
              accessibilityLabel={c.className}
            >
              <Text style={[styles.menuItemText, { color: colors.text }]}>{c.className}</Text>
              <View style={{ flex: 1 }} />
              {selected && (
                <SymbolView name="checkmark" size={16} weight="semibold" tintColor={colors.primary} />
              )}
            </HdrPressable>
          );
        })}
        <HdrPressable
          effect="subtle"
          style={({ pressed }) => [
            styles.menuCancelItem,
            styles.menuCancelPadding,
            { opacity: pressed ? 0.7 : 1 },
          ]}
          onPress={() => {
            void hapticForScene('press');
            onClose();
          }}
          accessibilityRole="button"
          accessibilityLabel="取消"
        >
          <Text style={[styles.menuCancelText, { color: colors.textSecondary }]}>取消</Text>
        </HdrPressable>
      </BottomSheetScrollView>
    </BottomSheetComponent>
  );
});

const styles = StyleSheet.create({
  classifySheetScroll: {
    flex: 1,
  },
  classifySheetContent: {
    paddingHorizontal: Spacing.lg,
    paddingTop: Spacing.sm,
    paddingBottom: 24,
  },
  menuTitle: { ...typographyStyles.footnote, fontWeight: '700', textAlign: 'center', marginBottom: Spacing.sm },
  menuItem: { flexDirection: 'row', alignItems: 'center', gap: 14, paddingHorizontal: Spacing.xl, paddingVertical: 14 },
  menuItemText: { ...typographyStyles.callout },
  menuCancelItem: {
    justifyContent: 'center',
    borderTopWidth: StyleSheet.hairlineWidth,
    marginTop: Spacing.xs,
  },
  menuCancelPadding: {
    paddingVertical: 14,
  },
  menuCancelText: { ...typographyStyles.calloutBold },
});
