/**
 * Search Page (搜索页) — 原生外观搜索行 + 分段随结果滚动退出
 *
 * 布局（2026-08-26 用户拍板：原生外观输入行 + 随滚退出）：
 * - 纯 RN 根（吧页/用户主页终局范式），headerShown:false，原生导航栏与
 *   UISearchController 整体退场；
 * - 搜索行（自绘 iOS 原生搜索框外观：圆角胶囊+放大镜+清空钮）+ 原生 segment
 *   （TiebaSegmentedControl）+ 排序行组成共享列表头，作为各结果页 LegendList
 *   的 ListHeaderComponent 随列表原生滚动、滑到顶自然从屏幕顶部退出
 *   （用户主页 UserTabList 同款契约）；三页各自持有滚动位置；
 * - 贴/吧/人 三页 SegmentPager 横滑切换；最左页继续右滑 = 退出搜索页
 *   （原生栈边缘返回手势保持开启（2026-08-28 转场改回原生 push/pop 时恢复）；
 *   非左缘横滑仍由分段翻页接管，两者收尾都是原生 pop）；
 * - segment 用原生 UISegmentedControl：RN 树内 UIKit hit-test 直接命中，
 *   LegendList 头内可点（SwiftUI Host 进 LegendList 的嵌套方案已证伪）；
 * - 排序下拉用纯 RN 玻璃菜单（ForumSortBar 样板；SwiftUI Menu 嵌 RN 树
 *   iOS 26 上点击无响应的教训同源）；
 * - 取消按钮：有文字 → 清空文字保留结果（iOS 取消规范）；无文字 → 退出页面。
 *
 * 状态机（2026-08-25 重构）：结果三桶/分页/竞态闸收敛到 useSearchController；
 * 历史+建议区 JSX 抽到 SearchHistorySection；加载/失败/重试在 Search*List
 * 组件内（header 保持置顶展示）。
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { ReactElement } from 'react';
import {
  View,
  Text,
  Pressable,
  StyleSheet,
  ScrollView,
  Keyboard,
  useWindowDimensions,
} from 'react-native';
import { Stack, useRouter } from 'expo-router';
import { hapticForScene } from '@/theme/hapticsMap';
import { SymbolView } from '@/components/ui/SymbolView';
import { SegmentPager } from '@/components/ui/SegmentPager';
import { TiebaSegmentedControl } from '@/components/ui/TiebaSegmentedControl';
import { TiebaSearchBar } from '@/components/ui/TiebaSearchBar';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { SearchHistorySection } from '@/components/search/SearchHistorySection';
import {
  SearchForumList,
  SearchThreadList,
  SearchUserList,
} from '@/components/search/SearchResultList';
import { useSearchController } from '@/hooks/useSearchController';
import { useFeedCardActions } from '@/hooks/useFeedCardActions';
import { useSearchHistory } from '@/hooks/useSearchHistory';
import type { SearchTab } from '@/hooks/useSearchController';
import { useThemeColors } from '@/theme/ThemeContext';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import {Spacing, typographyStyles, RadiusStyle} from '@/theme';
import { NAV_BAR_H } from '@/constants/layout';
import ImageViewer from '@/components/ImageViewer';
import { useImageViewer } from '@/hooks/useImageViewer';
import { SearchThreadOrder } from '@/types';

// ── 常量 ──
const TABS: { key: SearchTab; label: string }[] = [
  { key: 'thread', label: '贴' },
  { key: 'forum', label: '吧' },
  { key: 'user', label: '人' },
];
const TAB_INDEX: Record<SearchTab, number> = { thread: 0, forum: 1, user: 2 };
const SEARCH_PLACEHOLDER = '搜吧、搜贴、搜人';
/** 排序下拉选项（与原 SwiftUI menu 同集） */
const SORT_OPTIONS: { value: SearchThreadOrder; label: string }[] = [
  { value: SearchThreadOrder.NEW_FIRST, label: '按时间' },
  { value: SearchThreadOrder.RELEVANT, label: '按相关性' },
];

// ── 主页面 ──
export default function SearchPage() {
  const router = useRouter();
  const { colors } = useThemeColors();
  const insets = useSafeAreaInsets();
  const [inputText, setInputText] = useState('');
  const [historyExpanded, setHistoryExpanded] = useState(false);
  const [suggestions, setSuggestions] = useState<string[]>([]);
  const [sortMenuOpen, setSortMenuOpen] = useState(false);
  // 排序菜单锚点（点击瞬间 measureInWindow 实测触发钮位置，页面级浮层
  // 按此定位——菜单在列表头内会随滚+被卡片盖住，浮层提级到页根）
  const [sortMenuAnchor, setSortMenuAnchor] = useState<{ x: number; y: number; w: number; h: number } | null>(null);
  const sortTriggerRef = useRef<View>(null);
  const { width: winW, height: winH } = useWindowDimensions();

  const {
    activeTab,
    sortOrder,
    setSortOrder,
    searchedKeyword,
    hasSearched,
    threads,
    setThreads,
    forums,
    users,
    loading,
    error,
    threadHasMore,
    loadingMore,
    doSearch,
    commitKeyword,
    selectTab,
    loadMoreThreads,
  } = useSearchController();

  const { history, save: saveToHistory, clear: clearHistory, remove: removeHistoryItem } =
    useSearchHistory();
  const imageViewer = useImageViewer();
  // 搜索卡点赞/分享收敛到共享 hook（thermo Z5-D；搜索结果字段是 likeNum，
  // 由本页 applyLike 适配，其余行为与信息流四页完全一致）
  const feedActions = useFeedCardActions({
    applyLike: (id, nextAgree) =>
      setThreads((prev) =>
        prev.map((t) =>
          t.id === id
            ? { ...t, hasAgree: nextAgree, likeNum: Math.max(0, (t.likeNum || 0) + (nextAgree ? 1 : -1)) }
            : t,
        ),
      ),
    getLatestHasAgree: (id) => threads.find((t) => t.id === id)?.hasAgree,
  });

  // ── 建议词：历史前缀匹配（轻量，不另开请求） ──
  useEffect(() => {
    if (!inputText.trim()) {
      setSuggestions([]);
      return;
    }
    const timer = setTimeout(() => {
      setSuggestions(
        history
          .filter((h) => h.keyword.startsWith(inputText.trim()))
          .map((h) => h.keyword)
          .slice(0, 5),
      );
    }, 150);
    return () => clearTimeout(timer);
  }, [inputText, history]);

  /**
 * 提交搜索：记录历史 + 切到搜索态。
 * 必须走 commitKeyword（清三桶 + setHasSearched(true) + 当前 tab 发起）——
 * 直接调 doSearch 不会翻转 hasSearched，页面永远停在历史态、结果出不来
 * （2026-08-27 真机复现：提交后无任何界面变化）。
 */
  const handleSubmit = useCallback(() => {
    const kw = inputText.trim();
    if (!kw) return;
    Keyboard.dismiss();
    void saveToHistory(kw);
    commitKeyword(kw, activeTab);
  }, [inputText, activeTab, saveToHistory, commitKeyword]);

  /** 历史/建议词点击 */
  const handleKeywordTap = useCallback(
    (kw: string) => {
      setInputText(kw);
      void saveToHistory(kw);
      commitKeyword(kw, activeTab);
    },
    [activeTab, saveToHistory, commitKeyword],
  );

  /** iOS 取消语义：有文字清文字（保留结果），无文字退出页面 */
  const handleCancel = useCallback(() => {
    if (inputText.length > 0) {
      setInputText('');
      return;
    }
    router.back();
  }, [inputText, router]);

  const handleSegmentSelect = useCallback(
    (value: string) => {
      hapticForScene('segment');
      setSortMenuOpen(false);
      const tab = TABS.find((t) => t.key === value)?.key ?? activeTab;
      selectTab(tab);
    },
    [activeTab, selectTab],
  );

  const handlePagerChange = useCallback(
    (index: number) => {
      setSortMenuOpen(false);
      const tab = TABS[index]?.key ?? activeTab;
      selectTab(tab);
    },
    [activeTab, selectTab],
  );

  const handleSortChange = useCallback(
    (order: SearchThreadOrder) => {
      setSortMenuOpen(false);
      if (sortOrder === String(order)) return;
      setSortOrder(String(order));
      if (searchedKeyword) doSearch(searchedKeyword, 'thread');
    },
    [sortOrder, setSortOrder, searchedKeyword, doSearch],
  );

  const handleHistoryLongPress = useCallback(
    (kw: string) => {
      void removeHistoryItem(kw);
    },
    [removeHistoryItem],
  );

  const toggleHistoryExpand = useCallback(() => {
    setHistoryExpanded((v) => !v);
  }, []);

  // 打开排序菜单：实测触发钮窗口坐标（列表头内可滚动，必须按点击瞬间
  // 的实际位置锚定），菜单渲染在页面级浮层（不被结果卡片遮挡）。
  const openSortMenu = useCallback(() => {
    hapticForScene('press');
    sortTriggerRef.current?.measureInWindow((x, y, w, h) => {
      setSortMenuAnchor({ x, y, w, h });
      setSortMenuOpen(true);
    });
  }, []);

  /** 排序菜单浮层水平/垂直位置（溢出翻转向上展开） */
  const sortMenuPos = useMemo(() => {
    if (!sortMenuAnchor) return undefined;
    const MENU_W = 148;
    const MENU_H = 96;
    const x = Math.min(sortMenuAnchor.x, winW - MENU_W - 8);
    const below = sortMenuAnchor.y + sortMenuAnchor.h + 4 + MENU_H;
    let top = sortMenuAnchor.y + sortMenuAnchor.h + 4;
    if (below > winH - 8 && sortMenuAnchor.y - MENU_H - 4 >= insets.top + NAV_BAR_H) {
      top = sortMenuAnchor.y - MENU_H - 4; // 下方放不下 → 向上展开
    }
    return { x, top };
  }, [sortMenuAnchor, winW, winH, insets.top]);

  // ══ 搜索行（系统原生 UISearchBar：放大镜/取消钮/键盘全部由系统承担）══
  const searchRow = (
    <View style={styles.searchRow}>
      <TiebaSearchBar
        placeholder={SEARCH_PLACEHOLDER}
        text={inputText}
        showCancel={inputText.length > 0}
        autoFocus={!hasSearched}
        onTextChange={setInputText}
        onSubmit={handleSubmit}
        onCancel={handleCancel}
      />
    </View>
  );

  // ══ 共享列表头（分段 + 排序；随列表滚动退出。搜索行不再在此——固定
  // 在页面根，见根 return：两树切换（搜索前/后）时搜索行保持同一实例
  // 同一位置，不再"搜索过程下移、结果后回原位"（2026-08-31 用户）） ══
  // 按 tab 缓存元素：此前每次渲染现场新建，任何状态变化（输入、加载、
  // 菜单开合…）都令三列表 header 引用全变、LegendList 连带重挂头
  // （2026-09-01 卡顿根因二）。deps 只留真正影响 header 内容的项。
  //
  // 2026-09-01 玻璃根因（与吧页同款，见 forum/[name] 注释）：UIKit 玻璃
  // chrome 离屏/未布局时首挂即永久扁平。本页 segment 同处 PagerView 页面
  // + LegendList 列表头内，首挂落进无效状态；布局完成后重挂一次强制重新
  // 物化（segRemount 进 deps，三 header 拿到新 key 触发重建）。
  const [segRemount, setSegRemount] = useState(0);
  const segRemountDoneRef = useRef(false);
  const handleSegRowLayout = useCallback(() => {
    if (segRemountDoneRef.current) return;
    segRemountDoneRef.current = true;
    requestAnimationFrame(() => setSegRemount((k) => k + 1));
  }, []);

  const listHeaders = useMemo(
    () => {
      const mkHeader = (tab: SearchTab) => (
        <View style={styles.headerBlock}>
          <View style={styles.segmentRow} onLayout={handleSegRowLayout}>
            <TiebaSegmentedControl
              key={`seg-${segRemount}`}
              segments={TABS.map((t) => ({ label: t.label, value: t.key }))}
              selectedIndex={TAB_INDEX[activeTab]}
              onSelect={handleSegmentSelect}
            />
          </View>
          {tab === 'thread' && (
            <View style={[styles.sortRow, { zIndex: 10 }]}>
              <View ref={sortTriggerRef} collapsable={false}>
                <HdrPressable
                  onPress={openSortMenu}
                  hitSlop={8}
                  flashRadius={8}
                  effect="subtle"
                  style={styles.sortTrigger}
                >
                  <Text style={[styles.sortText, { color: colors.textSecondary }]}>
                    {SORT_OPTIONS.find((o) => String(o.value) === sortOrder)?.label ?? '按时间'}
                  </Text>
                  <SymbolView name="chevron.down" size={12} tintColor={colors.textTertiary} />
                </HdrPressable>
              </View>
            </View>
          )}
        </View>
      );
      return {
        thread: mkHeader('thread'),
        forum: mkHeader('forum'),
        user: mkHeader('user'),
      } as Record<SearchTab, ReactElement>;
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps -- sortOrder/colors 已含，回调均 useCallback 稳定
    [activeTab, sortOrder, colors, handleSegmentSelect, openSortMenu, segRemount, handleSegRowLayout],
  );

  return (
    <View style={[styles.container, { backgroundColor: colors.background }]}>
      <Stack.Screen
        options={{
          // 原生顶栏（透明玻璃 + 返回键）：标题 = 已搜索关键词（iOS 搜索
          // 规范：结果显示关键词）；未搜索时显示固定"搜索"。
          // 转场 = 原生 push/pop（2026-08-28）：此前 animation:'fade' 把进入/
          // 返回覆盖成淡入淡出，用户反馈不是 iOS 原生过渡；不指定 animation
          // 即走 native-stack 默认右推入 push、返回 pop（左上返回钮同款）。
          title: searchedKeyword || '搜索',
          // 原生栈边缘右滑返回（iOS 边缘手势，整屏滑动退出）；SegmentPager
          // 不再接管最左退出（2026-08-28 与吧页统一，pager 关 overdrag）
        }}
      />

      {/* 搜索行固定在页面根（搜索前/后同一实例、同一位置——切换零跳动；
          原各树内渲染会导致"搜索过程搜索栏下移、结果显示后回原位"） */}
      <View style={[styles.searchBarFixed, { paddingTop: insets.top + NAV_BAR_H }]}>
        {searchRow}
      </View>

      {!hasSearched ? (
        /* ── 搜索前：历史/建议（滚动区在固定搜索行下方） ── */
        <View style={styles.flex}>
          <ScrollView
            style={styles.flex}
            contentContainerStyle={{
              // 搜索栏与历史区之间留足呼吸（用户反馈"贴在一起"）
              paddingTop: 12,
              paddingBottom: insets.bottom + 24,
            }}
            keyboardShouldPersistTaps="handled"
          >
            <View style={styles.bodyContent}>
              <SearchHistorySection
                suggestions={suggestions}
                history={history}
                historyExpanded={historyExpanded}
                onToggleExpand={toggleHistoryExpand}
                onClearHistory={() => {
                  void hapticForScene('destructive');
                  clearHistory();
                }}
                onPressKeyword={handleKeywordTap}
                onLongPressKeyword={handleHistoryLongPress}
                colors={colors}
              />
            </View>
          </ScrollView>
        </View>
      ) : (
        /* ── 搜索后：三页可横滑；列表头随各自列表滚动退出 ── */
        <View style={styles.flex}>
          <SegmentPager
            pageIndex={TAB_INDEX[activeTab]}
            onPageIndexChange={handlePagerChange}
          >
            {TABS.map((t) => {
              const header = listHeaders[t.key];
              if (t.key === 'thread') {
                return (
                  <View key={t.key} style={styles.page}>
                    <SearchThreadList
                      items={threads}
                      colors={colors}
                      onPressItem={() => {}}
                      header={header}
                      loading={loading}
                      error={error}
                      onRetry={() => doSearch(searchedKeyword, 'thread')}
                      onEndReached={loadMoreThreads}
                      hasMore={threadHasMore}
                      loadingMore={loadingMore}
                      refreshing={loading}
                      onRefresh={() => doSearch(searchedKeyword, 'thread')}
                      onLike={feedActions.like}
                      onShare={feedActions.share}
                      onImagePress={imageViewer.handleImagePress}
                    />
                  </View>
                );
              }
              if (t.key === 'forum') {
                return (
                  <View key={t.key} style={styles.page}>
                    <SearchForumList
                      items={forums}
                      colors={colors}
                      onPressItem={(f) => router.push(`/forum/${encodeURIComponent(f.forumName)}`)}
                      header={header}
                      loading={loading}
                      error={error}
                      onRetry={() => doSearch(searchedKeyword, 'forum')}
                      refreshing={loading}
                      onRefresh={() => doSearch(searchedKeyword, 'forum')}
                    />
                  </View>
                );
              }
              return (
                <View key={t.key} style={styles.page}>
                  <SearchUserList
                    items={users}
                    colors={colors}
                    onPressItem={(u) => router.push(`/user/${u.uid}`)}
                    header={header}
                    loading={loading}
                    error={error}
                    onRetry={() => doSearch(searchedKeyword, 'user')}
                    refreshing={loading}
                    onRefresh={() => doSearch(searchedKeyword, 'user')}
                  />
                </View>
              );
            })}
          </SegmentPager>
        </View>
      )}

      {/* 排序菜单页面级浮层（2026-08-31 提层：此前渲染在列表头内，随列表
          滚动且被结果卡片遮挡）。全屏背板捕获点击关闭；菜单按 measureInWindow
          锚定在触发钮下方，空间不足自动向上展开。 */}
      {sortMenuOpen && sortMenuAnchor && sortMenuPos && (
        <Pressable style={styles.sortBackdrop} onPress={() => setSortMenuOpen(false)}>
          <View
            style={[
              styles.sortMenuFloat,
              { left: sortMenuPos.x, top: sortMenuPos.top, backgroundColor: colors.card, borderColor: colors.borderCard },
            ]}
          >
            {SORT_OPTIONS.map((o) => (
              <HdrPressable
                key={o.value}
                onPress={() => handleSortChange(o.value)}
                style={styles.sortOption}
                flashRadius={8}
                effect="subtle"
              >
                <Text
                  style={[
                    styles.sortOptionText,
                    { color: String(o.value) === sortOrder ? colors.primary : colors.text },
                  ]}
                >
                  {o.label}
                </Text>
              </HdrPressable>
            ))}
          </View>
        </Pressable>
      )}

      {/* 大图查看器（搜索卡图片点击；长按菜单由卡片内原生 ContextMenu 承担） */}
      <ImageViewer
        images={imageViewer.imageViewerImages}
        initialIndex={imageViewer.imageViewerIndex}
        visible={imageViewer.imageViewerVisible}
        onClose={imageViewer.closeImageViewer}
        sourceFrame={imageViewer.imageViewerSourceFrame}
        imageOrigins={imageViewer.imageViewerOrigins}
        contextTitle={imageViewer.imageViewerContextTitle}
        imageMeta={imageViewer.imageViewerMeta}
        imagePreviews={imageViewer.imageViewerPreviews}
      />
    </View>
  );
}

// ── 样式 ──
const styles = StyleSheet.create({
  container: { flex: 1 },
  flex: { flex: 1 },
  // ── 搜索行 ──
  searchRow: {
    paddingHorizontal: Spacing.lg,
    paddingVertical: Spacing.xs,
  },
  // 固定搜索行容器（页面根）：搜索前/后同一实例——顶栏让位走 paddingTop
  //（headerTransparent 原生顶栏悬浮），下方内容（历史/分页列表）在其下
  searchBarFixed: {
    zIndex: 20,
  },
  // ── 分段 ──
  segmentRow: {
    paddingHorizontal: Spacing.lg,
    paddingBottom: Spacing.xs,
  },
  // ── 排序 ──
  sortRow: {
    paddingHorizontal: Spacing.lg,
    paddingBottom: Spacing.xs,
  },
  sortTrigger: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    alignSelf: 'flex-start',
    paddingVertical: 2,
  },
  sortText: {
    fontSize: 13,
  },
  sortOverlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
  },
  sortMenu: {
    position: 'absolute',
    top: 4,
    left: Spacing.lg,
    ...RadiusStyle.card,
    borderWidth: StyleSheet.hairlineWidth,
    paddingVertical: 4,
    minWidth: 140,
  },
  // 页面级浮层（2026-08-31）：全屏背板 + 锚定菜单，zIndex 高于结果列表
  sortBackdrop: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    zIndex: 80,
  },
  sortMenuFloat: {
    position: 'absolute',
    zIndex: 81,
    ...RadiusStyle.card,
    borderWidth: StyleSheet.hairlineWidth,
    paddingVertical: 4,
    minWidth: 148,
  },
  sortOption: {
    paddingHorizontal: Spacing.md,
    paddingVertical: Spacing.sm + 2,
  },
  sortOptionText: {
    fontSize: 14,
  },
  // ── 列表头 ──
  headerBlock: {
    paddingHorizontal: 0,
  },
  // ── 主体 ──
  bodyContent: {
    paddingHorizontal: Spacing.lg,
  },
  page: {
    flex: 1,
  },
  emptyTitle: typographyStyles.subhead,
});