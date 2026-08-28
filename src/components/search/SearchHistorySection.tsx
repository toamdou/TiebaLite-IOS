/**
 * SearchHistorySection — 搜索前内容区（搜索建议 + 搜索历史 + 空态）
 *
 * 从搜索页抽离的纯展示区：建议药丸、历史药丸（展开/收起、删除、长按单删）
 * 与无历史空态。交互回调全部由页面注入，本组件不持有状态。
 */

import React from 'react';
import { Pressable, StyleSheet, View } from 'react-native';
import { Text } from '../ui/CompatText';

import { SymbolView } from '@/components/ui/SymbolView';
import { useTimeLabel } from '@/hooks/useTimeLabel';
import {Spacing, typographyStyles, Radius} from '@/theme';
import type { SemanticColors } from '@/theme';
import type { SearchHistoryItem } from '@/storage/searchHistory';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { hapticForScene } from '@/theme/hapticsMap';

const VISIBLE_HISTORY_COUNT = 6;

interface SearchHistorySectionProps {
  suggestions: string[];
  history: SearchHistoryItem[];
  historyExpanded: boolean;
  onToggleExpand: () => void;
  onClearHistory: () => void;
  onPressKeyword: (keyword: string) => void;
  onLongPressKeyword: (keyword: string) => void;
  colors: SemanticColors;
}

export const SearchHistorySection = React.memo(function SearchHistorySection({
  suggestions,
  history,
  historyExpanded,
  onToggleExpand,
  onClearHistory,
  onPressKeyword,
  onLongPressKeyword,
  colors,
}: SearchHistorySectionProps) {
  const timeLabel = useTimeLabel();
  return (
    <>
      {suggestions.length > 0 && (
        <View style={styles.historySection}>
          <View style={styles.historyHeader}>
            <Text style={[styles.historyTitle, { color: colors.text }]}>搜索建议</Text>
          </View>
          <View style={styles.tagWrap}>
            {suggestions.map((item, idx) => (
              <HdrPressable
                key={`sug-${item}-${idx}`}
                onPress={() => {
                  void hapticForScene('press');
                  onPressKeyword(item);
                }}
                style={[styles.tagPill, { backgroundColor: colors.chip }]}
                // 药丸级小控件不扫光（用户反馈条带状高光多余，2026-08-26）
                effect="subtle"
                flashRadius={10}
                glowOutset={5}
              >
                <Text style={[styles.tagText, { color: colors.text }]} numberOfLines={1}>
                  {item}
                </Text>
              </HdrPressable>
            ))}
          </View>
        </View>
      )}
      {history.length > 0 && (
        <View style={styles.historySection}>
          <View style={styles.historyHeader}>
            <Pressable
              onPress={onToggleExpand}
              hitSlop={8}
              style={styles.historyTitleRow}
              accessibilityLabel={historyExpanded ? '收起搜索历史' : '展开搜索历史'}
            >
              <Text style={[styles.historyTitle, { color: colors.text }]}>搜索历史</Text>
              <SymbolView
                name={historyExpanded ? 'chevron.up' : 'chevron.down'}
                size={14}
                tintColor={colors.textTertiary}
              />
            </Pressable>
            <View style={styles.historyHeaderActions}>
              {history.length > VISIBLE_HISTORY_COUNT && (
                <HdrPressable
                  onPress={() => {
                    void hapticForScene('press');
                    onToggleExpand();
                  }}
                  hitSlop={8}
                  style={{ padding: Spacing.xs }}
                  flashRadius={8}
                  glowOutset={5}
                >
                  <Text style={[styles.historyToggleText, { color: colors.textTertiary }]}>
                    {historyExpanded ? '收起' : '全部'}
                  </Text>
                </HdrPressable>
              )}
              <HdrPressable onPress={() => { void hapticForScene('destructive'); onClearHistory(); }} hitSlop={8} style={{ padding: Spacing.xs }} flashRadius={8} glowOutset={5}>
                <SymbolView name="trash" size={16} tintColor={colors.textTertiary} />
              </HdrPressable>
            </View>
          </View>
          <View style={styles.tagWrap}>
            {(historyExpanded ? history : history.slice(0, VISIBLE_HISTORY_COUNT)).map((item, idx) => (
              <HdrPressable
                key={`${item.keyword}-${item.timestamp}-${idx}`}
                onPress={() => {
                  void hapticForScene('press');
                  onPressKeyword(item.keyword);
                }}
                onLongPress={() => {
                  void hapticForScene('long-press');
                  onLongPressKeyword(item.keyword);
                }}
                style={[styles.historyPill, { backgroundColor: colors.chip }]}
                // 药丸级小控件不扫光（用户反馈条带状高光多余，2026-08-26）
                effect="subtle"
                flashRadius={10}
                glowOutset={5}
              >
                <Text style={[styles.tagText, { color: colors.text }]} numberOfLines={1}>
                  {item.keyword}
                </Text>
                <Text style={[styles.historyTime, { color: colors.textTertiary }]}>
                  {timeLabel(item.timestamp)}
                </Text>
              </HdrPressable>
            ))}
          </View>
        </View>
      )}
      {history.length === 0 && (
        <View style={styles.emptyWrap}>
          <SymbolView name="tray" size={40} tintColor={colors.textDisabled} />
          <Text style={[styles.emptyTitle, { color: colors.textSecondary }]}>
            搜索贴吧、帖子和用户
          </Text>
        </View>
      )}
    </>
  );
});

const styles = StyleSheet.create({
  historySection: {
    marginBottom: 24,
  },
  historyHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: 14,
  },
  historyTitleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
  },
  historyHeaderActions: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.sm,
  },
  historyToggleText: typographyStyles.footnote,
  historyTitle: {
    fontSize: 18,
    fontWeight: '700',
  },
  tagWrap: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 10,
  },
  tagPill: {
    paddingHorizontal: 14,
    paddingVertical: Spacing.sm,
    borderRadius: Radius.capsule,
    maxWidth: 200,
  },
  historyPill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingHorizontal: 14,
    paddingVertical: Spacing.sm,
    borderRadius: Radius.capsule,
    maxWidth: 220,
  },
  historyTime: {
    fontSize: 10,
  },
  tagText: {
    fontSize: 14,
    fontWeight: '400',
  },
  emptyWrap: {
    alignItems: 'center',
    paddingTop: 80,
    gap: Spacing.md,
  },
  emptyTitle: typographyStyles.subhead,
});