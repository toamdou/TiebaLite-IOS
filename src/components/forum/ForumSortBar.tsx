/**
 * 吧页 segment 下的排序/分类行（从 app/forum/[name].tsx 拆出）：
 * 最新 tab = 排序按钮 + 下拉菜单；精品 tab = 已选分类指示 + 筛选入口。
 * 菜单开合状态在页面持有（列表滚动/tab 切换会收起），本组件纯受控。
 *
 * 下拉菜单不挂在本行（列表头子树）内：绝对定位的浮层超出 ListHeader
 * 边界会被 LegendList 回收容器裁剪/被列表内容盖住（zIndex 只在兄弟
 * 作用域生效），模拟器实测"菜单弹不出"。菜单由页面根级 overlay 渲染
 * （ForumSortMenu），锚点用按钮 measureInWindow 实测。
 */

import React, { useRef } from 'react';
import { View, Pressable, StyleSheet } from 'react-native';
import { Text } from '../ui/CompatText';

import { SymbolView } from '@/components/ui/SymbolView';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { hapticForScene } from '@/theme/hapticsMap';
import { ForumSortType } from '@/types';
import {Shadows, Spacing, RadiusStyle} from '@/theme';
import { typographyStyles } from '@/theme/typography';

export interface ForumSortBarProps {
  currentTab: number;
  sortType: ForumSortType;
  sortMenuOpen: boolean;
  /** 点击排序按钮：参数=按钮底边在窗口坐标系的 y（菜单锚点，页面级 overlay 用） */
  onToggleSortMenu: (anchorY: number) => void;
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
  classifyLabel,
  hasClassifies,
  onClearClassify,
  onOpenClassifyPicker,
  colors,
}: ForumSortBarProps) {
  const sortBtnRef = useRef<View>(null);
  return (
    <View style={styles.fixedBar}>
      {/* 最新 tab 排序切换：菜单卡由页面根级 overlay 渲染（ForumSortMenu），
          本行只负责按钮与锚点上报（纯 RN 实现，SwiftUI Menu 嵌 RN 树在
          iOS 26 上点击无响应） */}
      {currentTab === 1 && (
        <View style={styles.sortRow}>
          {/* ref 壳：HdrPressable 不透传 ref，用外层 View 量锚点（y+高） */}
          <View ref={sortBtnRef}>
            <HdrPressable
              style={styles.sortBtn}
              hitSlop={8}
              accessibilityRole="button"
              accessibilityLabel="帖子排序方式"
              onPress={() => {
                void hapticForScene('sheet-present');
                sortBtnRef.current?.measureInWindow((_x, y, _w, h) => {
                  onToggleSortMenu(y + h + 6);
                });
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
        </View>
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
  // 左基线与列表 TweetCard 卡片外边距统一 10pt（2026-09-09）
  sortRow: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 10,
    marginTop: Spacing.xs,
  },
  sortBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingVertical: Spacing.xs,
  },
  sortBtnText: { ...typographyStyles.footnoteBold },
  menuBackdrop: {
    ...StyleSheet.absoluteFill,
    backgroundColor: 'rgba(0,0,0,0.08)',
  },
  sortMenuWrap: {
    ...StyleSheet.absoluteFill,
    left: 10,
    zIndex: 60,
  },
  sortMenu: {
    position: 'absolute',
    minWidth: 172,
    borderWidth: StyleSheet.hairlineWidth,
    borderRadius: 14,
    borderCurve: 'continuous',
    overflow: 'hidden',
    paddingVertical: 4,
    ...Shadows.card,
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
    paddingHorizontal: 10,
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

export interface ForumSortMenuProps {
  /** 菜单卡顶边的窗口坐标 y（排序按钮底边 + 间隙，由页面测量传入） */
  anchorTop: number;
  sortType: ForumSortType;
  onSelect: (sort: ForumSortType) => void;
  onClose: () => void;
  colors: any;
}

/**
 * 排序下拉菜单：页面根级 overlay 渲染（列表头子树外）。实色卡片——
 * 玻璃物化在 LegendList 虚拟化容器内不可靠（UIGlassEffect 首挂离屏
 * 永久扁平），临时浮层一律实色卡。全屏背板点击即收起。
 */
export function ForumSortMenu({ anchorTop, sortType, onSelect, onClose, colors }: ForumSortMenuProps) {
  return (
    <View style={StyleSheet.absoluteFill}>
      <Pressable
        style={styles.menuBackdrop}
        onPress={onClose}
        accessibilityRole="button"
        accessibilityLabel="关闭排序菜单"
      />
      <View style={styles.sortMenuWrap}>
        <View style={[styles.sortMenu, { top: anchorTop, backgroundColor: colors.card, borderColor: colors.borderCard }]}>
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
                  onSelect(opt.value);
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
        </View>
      </View>
    </View>
  );
}
