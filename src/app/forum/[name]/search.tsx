/**
 * In-Forum Search Page (吧内搜索)
 * Migrated from com.huanchengfly.tieba.post.ui.page.forum.ForumSearchPostPage
 *
 * Search posts within a specific forum with sort/filter options,
 * search history, and paginated results.
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  View,
  StyleSheet,
  Alert,
  Text,
} from 'react-native';
import { VStack, RNHostView } from '@expo/ui/swift-ui';
import {
  frame,
} from '@expo/ui/swift-ui/modifiers';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import type { SearchBarCommands } from 'react-native-screens';
import { hapticForScene } from '@/theme/hapticsMap';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { SearchHistorySection } from '@/components/search/SearchHistorySection';
import { EmptyState } from '@/components/ui/EmptyState';
import { ErrorState } from '@/components/ui/ErrorState';
import { SearchPostList } from '@/components/search/SearchResultList';
import { useThemeColors } from '@/theme/ThemeContext';
import { Spacing, RadiusStyle, Radius } from '@/theme';
import { SkeletonList } from '../../../components/ui/Skeleton';
import { searchPost } from '@/services/api/endpoints/search';
import { usePagedList } from '@/hooks/usePagedList';
import { useSearchHistory } from '@/hooks/useSearchHistory';
import type { SearchPostResult } from '@/types';
import { SymbolView } from '@/components/ui/SymbolView';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { GlassView } from '@/components/ui/GlassView';

// ---------- Constants ----------
// 取值对齐 Kotlin ForumSearchPostSortType / ForumSearchPostFilterType
//（混合接口 /mo/q/search/thread 的 st/tt 参数）：
//   st: 1=按时间（NEWEST）, 2=按相关性（RELATIVE）
//   tt: 1=仅主题贴（ONLY_THREAD）, 2=全部（ALL）
const SORT_OPTIONS = [
  { label: '按时间', value: '1' },
  { label: '按相关性', value: '2' },
];
const FILTER_OPTIONS = [
  { label: '全部', value: '2' },
  { label: '仅主题贴', value: '1' },
];
const MAX_HISTORY_ITEMS = 10;

/** 原生搜索栏高度（bar 实测 402×108，与主搜索页同值）；控件行从 bar 底开始让位 */
const SEARCH_BAR_HEIGHT = 108;

// ---------- Main Page ----------
export default function ForumSearchPage() {
  const { name, forumId } = useLocalSearchParams<{ name: string; forumId: string }>();
  const insets = useSafeAreaInsets();
  const { colors } = useThemeColors();
  const router = useRouter();

  const [searchQuery, setSearchQuery] = useState('');
  const [sortType, setSortType] = useState('1'); // st: 1=按时间（默认）2=按相关性
  const [filterType, setFilterType] = useState('2'); // tt: 2=全部（默认）1=仅主题贴
  // 自绘排序/筛选下拉（RN 层 zIndex 高于结果列表；SwiftUI Menu 弹出曾被
  // RNHostView 盖住——用户 2026-08-30 反馈选项框在卡片之下）
  const [menuOpen, setMenuOpen] = useState<'sort' | 'filter' | null>(null);
  const [searchedKeyword, setSearchedKeyword] = useState('');
  const [searched, setSearched] = useState(false);
  const [historyExpanded, setHistoryExpanded] = useState(true);

  // 原生 header 搜索栏（UISearchController）引用与当前文字镜像。
  // iOS 不支持 autoFocus / onClose 事件，改用命令式 focus() 实现自动聚焦；
  // 切换 tab 返回时重新聚焦，方便连续搜索。
  const searchBarRef = useRef<SearchBarCommands | null>(null);
  const searchQueryRef = useRef('');
  useEffect(() => {
    searchQueryRef.current = searchQuery;
  }, [searchQuery]);
  const paged = usePagedList<SearchPostResult, { kw: string }>({
    fetcher: async (p, params, signal) => {
      const data = await searchPost(
        params.kw,
        name ?? '',
        p,
        parseInt(sortType, 10),
        parseInt(filterType, 10),
        signal,
      );
      return { items: data.items, hasMore: data.hasMore, nextPage: p + 1 };
    },
    params: { kw: searchedKeyword },
    initialPage: 1,
  });
  const {
    items: results,
    hasMore,
    loading,
    refreshing,
    loadingMore,
    error,
    load,
    refresh,
    loadMore,
  } = paged;

  // 搜索历史状态机收敛到共享 hook（thermo Z5-B：与全站搜索页同源），
  // 吧内维度经 forumId 注入；清空保留触感反馈。
  const { history, save: saveToHistory, clear: clearHistoryBase, remove: removeHistoryItem } =
    useSearchHistory(forumId, MAX_HISTORY_ITEMS);

  const handleClearHistory = useCallback(async () => {
    hapticForScene('press');
    await clearHistoryBase();
  }, [clearHistoryBase]);

  const handleHistoryLongPress = useCallback(
    (kw: string) => {
      Alert.alert('删除搜索历史', `确定删除“${kw}”？`, [
        { text: '取消', style: 'cancel' },
        {
          text: '删除',
          style: 'destructive',
          onPress: () => removeHistoryItem(kw),
        },
      ]);
    },
    [removeHistoryItem],
  );

  // Perform search
  const doSearch = useCallback(
    (kw: string) => {
      if (!kw.trim() || !forumId) return;
      const trimmed = kw.trim();
      setSearchedKeyword(trimmed);
      setSearched(true);
      saveToHistory(trimmed);
      // 统一走首屏加载：usePagedList load(1) 全量替换列表并重置分页。
      // 旧签名 (kw, p, isRefresh) 的 p>1 → loadMore() 分支是死路径——
      // 全部调用点都发新搜索（p=1 / isRefresh=true），已删。
      load(1, { kw: trimmed });
    },
    [forumId, saveToHistory, load],
  );

  // Re-search when sort/filter changes (if already searched)
  useEffect(() => {
    if (searched && searchQuery.trim()) {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- re-run search after sort/filter change; load transitions are managed by usePagedList.
      doSearch(searchQuery);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only sort/filter changes should re-run the search; the latest query is captured by that render's closure.
  }, [sortType, filterType]);

  const handleRefresh = useCallback(async () => {
    await refresh();
    hapticForScene('toggle');
  }, [refresh]);

  const handleLoadMore = useCallback(async () => {
    if (!hasMore || loadingMore || loading) return;
    await loadMore();
  }, [hasMore, loadingMore, loading, loadMore]);

  const handleSubmitSearch = useCallback(
    (text: string) => {
      if (text.trim()) {
        hapticForScene('press');
        doSearch(text);
      }
    },
    [doSearch],
  );

  const handleHistoryTap = useCallback((kw: string) => {
    hapticForScene('toggle');
    setSearchQuery(kw);
    doSearch(kw);
  }, [doSearch]);

  const handleOpenPost = useCallback(
    (item: SearchPostResult) => {
      // mo 搜索结果带 pid/floor 时深链楼中楼定位到该回复，否则退化为进帖
      if (item.postId && item.floor != null) {
        router.push({
          pathname: '/thread/[id]/subposts',
          params: {
            id: item.id,
            postId: item.postId,
            threadId: item.id,
            floor: String(item.floor),
            forumId: forumId || '',
          },
        });
        return;
      }
      router.push({ pathname: '/thread/[id]', params: { id: item.id } });
    },
    [router, forumId],
  );

  // Show loading indicator — 仅在实际发起搜索后显示骨架屏：usePagedList 在无
// seed 时 loading 初始恒 true，但进页并未发起任何请求（searched 前不显示，
// 否则进页即闪骨架屏且永不消失——8-25 真机「一直闪骨架屏」根因）。
  const showLoading = loading && results.length === 0 && searched;

  const searchBarOptions = useMemo(
    () => ({
      ref: searchBarRef,
      placeholder: '搜索吧内帖子...',
      hideWhenScrolling: false,
      placement: 'stacked' as const,
      autoCapitalize: 'none' as const,
      text: searchQuery,
      onChangeText: (e: { nativeEvent: { text: string } }) => setSearchQuery(e.nativeEvent.text),
      onSearchButtonPress: (e: { nativeEvent: { text: string } }) => handleSubmitSearch(e.nativeEvent.text),
      onCancelButtonPress: () => setSearchQuery(''),
    }),
    [searchQuery, handleSubmitSearch],
  );

  return (
    // 页面级 ThemedHost（ignoreSafeArea 让 VStack 从 y=0 起）：RN 内容经
    // RNHostView 从顶部延伸；排序/筛选自绘行在 RN 层内（面板 zIndex 60
    // 高于结果列表，SwiftUI Menu 嵌 RN 树被盖的旧问题不再有）
    <ThemedHost style={{ flex: 1 }} ignoreSafeArea="container">
      <VStack spacing={0} modifiers={[frame({ maxWidth: 10000, maxHeight: 10000 })]}>
        {/* RN 内容（工具行/历史/骨架/错误/空态/结果列表） */}
        <RNHostView>
          <View style={[styles.container, { backgroundColor: colors.background }]}>
            <Stack.Screen options={{ headerSearchBarOptions: searchBarOptions }} />
            {/* 排序/筛选自绘行：从搜索栏底让位（insets.top + 108） */}
            <SortFilterBar
              sortType={sortType}
              filterType={filterType}
              menuOpen={menuOpen}
              onToggle={(kind) => {
                hapticForScene('press');
                setMenuOpen((prev) => (prev === kind ? null : kind));
              }}
              onSelect={(kind, value) => {
                hapticForScene('toggle');
                setMenuOpen(null);
                if (kind === 'sort') setSortType(value);
                else setFilterType(value);
              }}
              top={insets.top + SEARCH_BAR_HEIGHT}
              colors={colors}
            />
            {/* Search History (only before first search)；复用全站搜索页同款区块 */}
            {!searched && (
              <View style={styles.historyWrap}>
              <SearchHistorySection
                suggestions={[]}
                history={history}
                historyExpanded={historyExpanded}
                onToggleExpand={() => setHistoryExpanded((v) => !v)}
                onClearHistory={handleClearHistory}
                onPressKeyword={handleHistoryTap}
                onLongPressKeyword={handleHistoryLongPress}
                colors={colors}
              />
              </View>
            )}
            {/* Loading */}
            {showLoading && (
              <SkeletonList count={6} variant="thread" />
            )}
            {/* Error */}
            {error && results.length === 0 && !showLoading && (
              <ErrorState message={error} onRetry={() => doSearch(searchQuery)} />
            )}
            {/* Empty */}
            {!showLoading && !error && searched && results.length === 0 && (
              <EmptyState
                title="未找到相关内容"
                description="换个关键词试试吧"
                icon={'doc.text.magnifyingglass' as any}
              />
            )}
            {/* Results */}
            {!showLoading && results.length > 0 && (
              <SearchPostList
                items={results}
                colors={colors}
                onPressItem={handleOpenPost}
                onEndReached={handleLoadMore}
                hasMore={hasMore}
                loadingMore={loadingMore}
                refreshing={refreshing}
                onRefresh={handleRefresh}
                contentContainerStyle={[styles.listContent, { paddingBottom: insets.bottom + 16 }]}
              />
            )}
          </View>
        </RNHostView>
      </VStack>
    </ThemedHost>
  );
}

// ---------- 排序/筛选自绘下拉（RN 层 zIndex 高于结果列表；吧页 ForumSortBar 同款） ----------
function SortFilterBar({
  sortType,
  filterType,
  menuOpen,
  onToggle,
  onSelect,
  top,
  colors,
}: {
  sortType: string;
  filterType: string;
  menuOpen: 'sort' | 'filter' | null;
  onToggle: (kind: 'sort' | 'filter') => void;
  onSelect: (kind: 'sort' | 'filter', value: string) => void;
  top: number;
  colors: any;
}) {
  const kind = menuOpen;
  const options = kind === 'sort' ? SORT_OPTIONS : FILTER_OPTIONS;
  const selectedValue = kind === 'sort' ? sortType : filterType;
  return (
    <View style={[styles.toolRow, { paddingTop: top }]}>
      <HdrPressable
        effect="subtle"
        style={({ pressed }) => [styles.toolBtn, { opacity: pressed ? 0.7 : 1 }]}
        hitSlop={8}
        accessibilityRole="button"
        accessibilityLabel="帖子排序"
        onPress={() => onToggle('sort')}
      >
        <SymbolView name="arrow.up.arrow.down" size={14} weight="semibold" tintColor={colors.primary} />
        <Text style={[styles.toolBtnText, { color: colors.primary }]}>
          {SORT_OPTIONS.find((o) => o.value === sortType)?.label ?? '排序'}
        </Text>
        <SymbolView
          name={menuOpen === 'sort' ? 'chevron.up' : 'chevron.down'}
          size={12}
          weight="semibold"
          tintColor={colors.primary}
        />
      </HdrPressable>
      <HdrPressable
        effect="subtle"
        style={({ pressed }) => [styles.toolBtn, { opacity: pressed ? 0.7 : 1 }]}
        hitSlop={8}
        accessibilityRole="button"
        accessibilityLabel="帖子筛选"
        onPress={() => onToggle('filter')}
      >
        <SymbolView name="line.3.horizontal.decrease.circle" size={15} weight="semibold" tintColor={colors.primary} />
        <Text style={[styles.toolBtnText, { color: colors.primary }]}>
          {FILTER_OPTIONS.find((o) => o.value === filterType)?.label ?? '筛选'}
        </Text>
        <SymbolView
          name={menuOpen === 'filter' ? 'chevron.up' : 'chevron.down'}
          size={12}
          weight="semibold"
          tintColor={colors.primary}
        />
      </HdrPressable>
      {kind ? (
        <View
          style={[
            styles.toolMenuWrap,
            { top: 44 },
            kind === 'filter' ? styles.toolMenuWrapRight : null,
          ]}
        >
          <GlassView
            borderRadius={Radius.card}
            glassEffectStyle="regular"
            tintColor={colors.card}
            style={styles.toolMenu}
          >
            {options.map((opt) => {
              const selected = selectedValue === opt.value;
              return (
                <HdrPressable
                  key={opt.value}
                  effect="subtle"
                  style={({ pressed }) => [
                    styles.toolMenuItem,
                    { opacity: pressed ? 0.6 : 1 },
                  ]}
                  accessibilityRole="button"
                  accessibilityLabel={opt.label}
                  onPress={() => onSelect(kind, opt.value)}
                >
                  <Text style={[styles.toolMenuItemText, { color: selected ? colors.primary : colors.text }]}>
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
      ) : null}
    </View>
  );
}

// ---------- Styles ----------
const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  // 排序/筛选工具行与下拉面板（zIndex 高于结果列表，选项框不被卡片盖）
  toolRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    paddingHorizontal: Spacing.lg,
    paddingBottom: Spacing.xs,
  },
  toolBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingVertical: Spacing.xs,
    paddingHorizontal: 10,
    ...RadiusStyle.chip,
  },
  toolBtnText: { fontWeight: '500', fontSize: 13 },
  toolMenuWrap: {
    position: 'absolute',
    left: Spacing.lg,
    zIndex: 60,
  },
  // 筛选钮位置更靠右：面板右对齐到筛选钮附近
  toolMenuWrapRight: {
    left: Spacing.lg + 118,
  },
  toolMenu: {
    minWidth: 148,
    ...RadiusStyle.card,
    overflow: 'hidden',
    paddingVertical: 4,
  },
  toolMenuItem: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    paddingHorizontal: 16,
    paddingVertical: 12,
  },
  toolMenuItemText: { fontWeight: '500', fontSize: 15 },
  historyWrap: {
    paddingHorizontal: Spacing.lg,
    paddingTop: Spacing.sm,
  },
  // Results
  listContent: {
    // 卡片距屏边统一 10pt
    paddingHorizontal: 10,
    paddingTop: Spacing.xs,
  },
});
