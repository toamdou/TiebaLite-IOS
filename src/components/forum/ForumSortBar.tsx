/**
 * 吧页 segment 下的排序/分类行（从 app/forum/[name].tsx 拆出）：
 * 最新 tab = 排序按钮 + 玻璃下拉菜单；精品 tab = 已选分类指示 + 筛选入口。
 * 菜单开合状态在页面持有（列表滚动/tab 切换会收起），本组件纯受控。
 */

import React from 'react';
import { View, StyleSheet } from 'react-native';
import { Text } from '../ui/CompatText';

import { SymbolView } from '@/components/ui/SymbolView';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { GlassView } from '@/components/ui/GlassView';
import { hapticForScene } from '@/theme/hapticsMap';
import { ForumSortType } from '@/types';
import {Shadows, Spacing, RadiusStyle, Radius} from '@/theme';
import { typographyStyles } from '@/theme/typography';

export interface ForumSortBarProps {
  currentTab: number;
  sortType: ForumSortType;
  sortMenuOpen: boolean;
  onToggleSortMenu: () => void;
  onCloseSortMenu: () => void;
  onSortChange: (sort: ForumSortType) => void;
  /** 精品 tab 已选分类名（未选=undefined，隐藏指示胶囊） */
  classifyLabel?: string;
  hasClassifies: boolean;
  onClearClassify: () => void;
  onOpenClassifyPicker: () => void;
  colors: any;
}

export const ForumSortBar = React.memo(function ForumSortBar({
  currentTab,
  sortType,
  sortMenuOpen,
  onToggleSortMenu,
  onCloseSortMenu,
  onSortChange,
  classifyLabel,
  hasClassifies,
  onClearClassify,
  onOpenClassifyPicker,
  colors,
}: ForumSortBarProps) {
  return (
    <View style={styles.fixedBar}>
      {/* 最新 tab 排序切换：按钮下方液态玻璃下拉（纯 RN 实现，
          SwiftUI Menu 嵌 RN 树在 iOS 26 上点击无响应） */}
      {currentTab === 1 && (
        <>
          <View style={styles.sortRow}>
            <HdrPressable
              style={styles.sortBtn}
              hitSlop={8}
              accessibilityRole="button"
              accessibilityLabel="帖子排序方式"
              onPress={() => {
                void hapticForScene('sheet-present');
                onToggleSortMenu();
              }}
            >
              <SymbolView name="arrow.up.arrow.down" size={14} weight="semibold" tintColor={colors.primary} />
              <Text style={[styles.sortBtnText, { color: colors.primary }]}>
                {sortType === ForumSortType.SEND_TIME ? '按发帖时间' : '按回复时间'}
              </Text>
              <SymbolView
                name={sortMenuOpen ? 'chevron.up' : 'chevron.down'}
                size={12}
                weight="semibold"
                tintColor={colors.primary}
              />
            </HdrPressable>
          </View>
          {sortMenuOpen && (
            <View style={styles.sortMenuWrap}>
              <GlassView
                borderRadius={Radius.card}
                glassEffectStyle="regular"
                tintColor={colors.card}
                style={styles.sortMenu}
              >
                {([
                  { label: '按回复时间', value: ForumSortType.REPLY_TIME },
                  { label: '按发帖时间', value: ForumSortType.SEND_TIME },
                ] as const).map((opt) => {
                  const selected = sortType === opt.value;
                  return (
                    <HdrPressable
                      key={opt.value}
                      // effect="subtle"：与精品分类 sheet 菜单项同款——菜单项去掉
                      // HDR 白闪高光（用户反馈），保留 pressed opacity 反馈。
                      effect="subtle"
                      style={({ pressed }) => [
                        styles.sortMenuItem,
                        { opacity: pressed ? 0.6 : 1 },
                      ]}
                      accessibilityRole="button"
                      accessibilityLabel={opt.label}
                      onPress={() => {
                        hapticForScene('toggle');
                        onCloseSortMenu();
                        onSortChange(opt.value);
                      }}
                    >
                      <Text style={[styles.sortMenuItemText, { color: selected ? colors.primary : colors.text }]}>
                        {opt.label}
                      </Text>
                      {selected && (
                        <SymbolView name="checkmark" size={15} weight="semibold" tintColor={colors.primary} />
                      )}
                    </HdrPressable>
                  );
                })}
              </GlassView>
            </View>
          )}
        </>
      )}

      {/* 精品分类指示 + 筛选 */}
      {currentTab === 2 && (
        <View style={styles.classifyRow}>
          {classifyLabel ? (
            <View style={styles.classifyIndicator}>
              <Text style={[styles.classifyIndicatorText, { color: colors.primary }]}>
                {classifyLabel}
              </Text>
              <HdrPressable onPress={() => { void hapticForScene('press'); onClearClassify(); }} hitSlop={8}>
                <SymbolView name="xmark" size={12} weight="semibold" tintColor={colors.primary} />
              </HdrPressable>
            </View>
          ) : null}
          {hasClassifies && (
            <HdrPressable
              // effect="subtle"：分类入口按钮去掉 HDR 白闪高光（用户反馈），
              // 交互保留（点按仍可用、无按压视觉变化）。
              effect="subtle"
              onPress={() => {
                void hapticForScene('sheet-present');
                onOpenClassifyPicker();
              }}
              style={styles.classifyFilterBtn}
              hitSlop={8}
            >
              <SymbolView name="line.3.horizontal.decrease.circle" size={18} tintColor={colors.primary} />
              <Text style={[styles.classifyFilterText, { color: colors.primary }]}>分类</Text>
            </HdrPressable>
          )}
        </View>
      )}
    </View>
  );
});

const styles = StyleSheet.create({
  fixedBar: {
    paddingTop: 6,
    paddingBottom: 2,
  },
  // ── 最新 tab 排序切换行 ──
  sortRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: Spacing.xl,
    marginTop: Spacing.xs,
  },
  sortBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingVertical: Spacing.xs,
    paddingHorizontal: 10,
    ...RadiusStyle.chip,
  },
  sortBtnText: { ...typographyStyles.footnoteBold },
  sortMenuWrap: {
    position: 'absolute',
    top: 44,
    left: Spacing.xl,
    zIndex: 60,
    ...Shadows.card,
  },
  sortMenu: {
    minWidth: 172,
    ...RadiusStyle.card,
    overflow: 'hidden',
    paddingVertical: 4,
  },
  sortMenuItem: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    paddingHorizontal: 16,
    paddingVertical: 12,
  },
  sortMenuItemText: { ...typographyStyles.subhead, fontWeight: '500' },
  // ── Good classify row ──
  classifyRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: Spacing.xl,
    marginTop: Spacing.xs,
  },
  classifyIndicator: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingHorizontal: 10,
    paddingVertical: Spacing.xs,
    ...RadiusStyle.chip,
  },
  classifyIndicatorText: { ...typographyStyles.footnoteBold },
  classifyFilterBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.xs,
    paddingVertical: Spacing.xs,
  },
  classifyFilterText: { ...typographyStyles.footnote, fontWeight: '500' },
});
