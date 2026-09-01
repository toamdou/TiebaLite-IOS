/* eslint-disable react-hooks/immutability -- Reanimated shared values are mutable refs; React Compiler cannot model them. */
/**
 * Forum Page (吧页面) — iOS-native design · 对齐 Kotlin ForumPage
 *
 * Kotlin ForumPage 布局:
 *   ForumToolbar (back + title + search + more)
 *   ForumHeader (avatar + name + level progress + follow/sign btn)
 *   ScrollableTabRow (热门 | 最新 | 精品 | 自定义Tab...)
 *   HorizontalPager → ForumThreadListPage (per-tab LegendList)
 *   FAB (refresh/back_to_top/post)
 *
 * iOS 布局（2026-08-25 重做，用户反馈"segment 在吧卡片上方/卡片距顶栏大片空白"）：
 * - 纯 RN View 根（页面级 SwiftUI 宿主会干扰顶栏玻璃链路，嵌套 Host 三连否决）；
 * - 吧名片 + 置顶帖固定于 segment 之上（对齐 Kotlin ForumHeader 顺序：
 *   卡片 → 置顶 → 热门|最新|精品 → 帖子列表），随列表头原生滚动滑出屏顶；
 * - segment/排序/分类行在列表头内（移出 LegendList header 的方案已废弃——
 *   PlatformView host 在虚拟化 header 里会偏移 ~100pt，是"1 秒后错位"的根因；
 *   现列表头整体为 RN 树，segment 用原生 UISegmentedControl 无此问题）；
 * - 热门/最新/精品 = SegmentPager 三页横滑切换（对齐 Kotlin HorizontalPager），
 *   每 tab 独立 LegendList 独立滚动位置；最左页继续右滑退出吧页
 *   （原生栈返回手势已关，横滑不再误触返回）。
 *
 * 组件拆分（thermo >1000 行拆分）：列表页 → components/forum/ForumTabList、
 * 名片+置顶 → ForumTabHeader、排序/分类行 → ForumSortBar、
 * 精品分类 sheet → ClassifyPickerSheet。
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  View,
  StyleSheet,
  Alert,
  Share,
  useWindowDimensions,
} from 'react-native';
import Animated, {
  useSharedValue, useAnimatedStyle, withSpring, withTiming, withSequence,
} from 'react-native-reanimated';

import { useLocalSearchParams, Stack, Link, useRouter, useIsFocused } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Menu, Button as SWButton } from '@expo/ui/swift-ui';
import { labelStyle, buttonStyle, frame, contentShape, shapes } from '@expo/ui/swift-ui/modifiers';
import { SegmentPager } from '@/components/ui/SegmentPager';
import { TiebaSegmentedControl } from '@/components/ui/TiebaSegmentedControl';
import { SymbolView } from '@/components/ui/SymbolView';
import { HdrPressable } from '@/components/ui/HdrPressable';
import * as Clipboard from 'expo-clipboard';
import { hapticForScene } from '@/theme/hapticsMap';
import { ErrorState } from '@/components/ui/ErrorState';
import ImageViewer from '@/components/ImageViewer';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { NAV_BAR_H } from '@/constants/layout';

import { useThemeColors } from '@/theme/ThemeContext';
import { GlassView } from '@/components/ui/GlassView';
import {CHROME_HIDE, DURATION, MOMENTUM, PRESS_ENTER, Spacing, Radius} from '@/theme';
import { useAppPreference } from '@/hooks/useAppPreference';
import { useNavDoubleTapToTop } from '@/hooks/useNavDoubleTapToTop';
import { useFeedCardActions } from '@/hooks/useFeedCardActions';
import { useImageViewer, frameFromPressEvent } from '@/hooks/useImageViewer';
import { useReducedMotion } from '@/hooks/useReducedMotion';
import { useForumStore } from '@/stores/forumStore';
import { useAuthStore } from '@/stores/authStore';
import { sign as signAPI } from '@/services/api/endpoints/forum';
import { isAdThreadInfo } from '@/services/api/endpoints/helpers';
import { flattenStyle, getAvatarUrl, buildForumUrl, formatCount } from '@/utils';
import { showToast } from '@/components/ui/Toast';
import { recordForumVisit } from '@/services/storage/visitHistory';
import { ForumSortType } from '@/types';
import type { ThreadInfo } from '@/types';
import { SkeletonList } from '@/components/ui/Skeleton';
import { ForumTabList } from '@/components/forum/ForumTabList';
import { ForumTabHeader } from '@/components/forum/ForumTabHeader';
import { ForumSortBar } from '@/components/forum/ForumSortBar';
import { ClassifyPickerSheet } from '@/components/forum/ClassifyPickerSheet';

/** Tab segments for the native segmented control (对齐 Kotlin: 热门 | 最新 | 精品) */
const TAB_SEGMENTS = [
  { label: '热门', value: '0' },
  { label: '最新', value: '1' },
  { label: '精品', value: '2' },
];

/**
 * FAB 刷新"滚回顶部"的兜底等待时长（ms）。正常路径由 onScroll 到达 offset 0
 *（或 onMomentumScrollEnd）结束等待；此值仅在两路事件都异常缺失时兜底放行，
 * 防止刷新流程被卡死。
 */
const SCROLL_TO_TOP_FALLBACK_MS = 600;

/** 悬浮按钮随滚动下滑出屏幕的距离（pt）；贴底 FAB 高度 52 + 底部留白 */
const FAB_HIDE_OFFSET = 120;

/** 单 tab 的语义参数（排序/是否精品/时间字段） */
function tabSemantics(tab: number, forumSortType: ForumSortType) {
  return {
    sort: tab === 0 ? ForumSortType.REPLY_TIME : forumSortType,
    isGood: tab === 2,
    // 热门固定按最后回复时间；最新/精品随用户所选排序
    timeType: tab === 0 ? 'last' : forumSortType === ForumSortType.SEND_TIME ? 'create' : 'last',
  } as const;
}

export default function ForumPage() {
  const { name } = useLocalSearchParams<{ name: string }>();
  const insets = useSafeAreaInsets();
  const { colors, isDark } = useThemeColors();
  const isLoggedIn = useAuthStore((s) => s.isLoggedIn);
  const router = useRouter();

  const currentForum = useForumStore((s) => s.currentForum);
  const isLoadingForums = useForumStore((s) => s.isLoadingForums);
  const forumSortType = useForumStore((s) => s.forumSortType);
  const latestThreads = useForumStore((s) => s.latestThreads);
  const goodThreads = useForumStore((s) => s.goodThreads);
  const newestThreads = useForumStore((s) => s.newestThreads);
  const currentTab = useForumStore((s) => s.currentTab);
  const setCurrentTab = useForumStore((s) => s.setCurrentTab);
  const goodClassify = useForumStore((s) => s.goodClassify);
  const goodClassifyId = useForumStore((s) => s.goodClassifyId);
  const setGoodClassifyId = useForumStore((s) => s.setGoodClassifyId);
  const loadForumData = useForumStore((s) => s.loadForumData);
  const followForum = useForumStore((s) => s.followForum);
  const unfollowForum = useForumStore((s) => s.unfollowForum);
  const markForumSigned = useForumStore((s) => s.markForumSigned);

  const incognitoMode = useAppPreference('incognitoMode', false);
  const filterAdThreads = useAppPreference('filterAdThreads', true);

  // 置顶帖：跨分桶按 id 去重（热门/最新/精品都可能携带同一批置顶），单独取出
  // 渲染在每个 tab 列表头部，并从列表数据流中过滤，避免与列表重复出现。
  const topThreads = useMemo(() => {
    const seen = new Map<string, ThreadInfo>();
    [newestThreads, latestThreads, goodThreads].forEach((list) => {
      (list ?? []).forEach((t) => {
        if (t.isTop && !(filterAdThreads && isAdThreadInfo(t)) && !seen.has(t.id)) seen.set(t.id, t);
      });
    });
    return Array.from(seen.values());
  }, [newestThreads, latestThreads, goodThreads, filterAdThreads]);

  const [refreshing, setRefreshing] = useState(false);
  const refreshingRef = useRef(false);
  const loadingMoreRef = useRef(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const lastScrollYRef = useRef(0);
  const [error, setError] = useState<string | null>(null);
  const [loaded, setLoaded] = useState(false);
  const forumFabFunction = useAppPreference('forumFabFunction', 'refresh');
  const fabHiddenBySetting = forumFabFunction === 'hide';
  // 底部锚定修复（8-25 真机二分实测）：同内容 FAB 在 top:300 可见、bottom:46
  // 不可见——page 级 ThemedHost（RNHostView/SwiftUI 宿主）真机容器高度大于屏高，
  // `bottom` 锚定会把按钮放到可视区外（帖内页无页面级宿主、纯 RN 容器，底栏
  // bottom 锚定正常）。改为按窗口高度从顶部换算：离底 = 安全区 + 12，视觉位置不变。
  const { height: screenH } = useWindowDimensions();
  const fabTop = screenH - insets.bottom - Spacing.md - 52;
  const [showClassifyPicker, setShowClassifyPicker] = useState(false);
  const [sortMenuOpen, setSortMenuOpen] = useState(false);
  const sortMenuOpenAtRef = useRef(0);

  // 悬浮按钮随滚动下滑出屏幕的距离（pt）。顶部锚定下 FAB 底边距屏底
  // = 安全区 + 12 ≈ 46pt，位移 120 足够整颗推出屏外（46 + 52 < 120）。
  const fabScale = useSharedValue(1);
  const fabTranslateY = useSharedValue(0);
  // JS 侧镜像：onScroll 是普通函数（JS 线程），直读 sharedValue 会每次事件
  // 跨 JS↔UI 同步阻塞（reanimated 官方性能警告）； fabTranslateY 本身保留
  // shared（600 行 useAnimatedStyle worklet 读），镜像只跟随时写入方向。
  const fabHiddenRef = useRef(false);

  const isFocused = useIsFocused();
  const { reduceMotion } = useReducedMotion();

  // 滚动回顶等待（FAB 刷新）：由任一 tab 列表的 onScroll 到达顶部触发放行
  const scrollToTopResolveRef = useRef<(() => void) | null>(null);
  const scrollToTopTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const settleScrollToTop = useCallback(() => {
    if (scrollToTopTimerRef.current != null) {
      clearTimeout(scrollToTopTimerRef.current);
      scrollToTopTimerRef.current = null;
    }
    const resolve = scrollToTopResolveRef.current;
    scrollToTopResolveRef.current = null;
    resolve?.();
  }, []);

  // 三个 tab 列表的 LegendList ref（FAB 回顶用当前 tab 的）
  const tabListRefs = useRef<(any | null)[]>([null, null, null]);

  // ── 数据加载（按 tab） ──
  const doLoadForTab = useCallback(
    async (tab: number, p: number) => {
      const { sort, isGood } = tabSemantics(tab, forumSortType);
      await loadForumData(name, p, sort, isGood, tab);
    },
    [name, forumSortType, loadForumData],
  );
  const doLoadForTabRef = useRef(doLoadForTab);
  useEffect(() => {
    doLoadForTabRef.current = doLoadForTab;
  }, [doLoadForTab]);

  // 首屏加载（tab 0 热门）：一次 per forum。出错了进页面级 ErrorState。
  const initialLoadKeyRef = useRef<string | null>(null);
  useEffect(() => {
    if (!name) return;
    if (initialLoadKeyRef.current !== name) {
      initialLoadKeyRef.current = name;
      // 进入新吧：清空上一吧的分桶/分类/当前 tab（对齐 Kotlin ForumPage 新会话）。
      // loadForumData 成功前不清桶——残留数据会跳过骨架态（`latestThreads.length===0`
      // 条件失效）并先渲染上一吧陈旧帖子；此处清了，进吧即显示骨架屏 + 各 tab 懒拉。
      useForumStore.getState().resetForumData();
      (async () => {
        try {
          await doLoadForTabRef.current(0, 1);
          setError(null);
          setLoaded(true);
        } catch (e: any) {
          setError(e?.message || '加载失败');
        }
      })();
    }
    if (!incognitoMode) {
      recordForumVisit({
        id: name,
        type: 'forum',
        forumId: currentForum?.forumId ?? '',
        forumName: name,
        avatar: currentForum?.avatar ?? '',
        title: `${name}吧`,
        timestamp: Date.now(),
      });
    }
  }, [name, incognitoMode, currentForum?.forumId, currentForum?.avatar]);

  // 精品分类变化 → 重拉精品 tab
  useEffect(() => {
    if (name && loaded && currentTab === 2 && goodClassifyId !== null) {
      doLoadForTabRef.current(2, 1).catch(() => {});
    }
  }, [goodClassifyId, currentTab, loaded, name]);

  // tab 懒加载：切到即拉（不依赖 PagerView 子页挂载时序——8-25 真机：
  // 切"最新"首次切入空白、手动下拉才出数据）。forum 数据已加载后，
  // 首次进入的 tab 立刻发请求；sortRow/classifyRow 变化另有 effect 兜底。
  const tabVisitRef = useRef<Set<number>>(new Set([0]));
  useEffect(() => {
    if (!loaded || !name) return;
    if (tabVisitRef.current.has(currentTab)) return;
    tabVisitRef.current.add(currentTab);
    // 等切换动画先走（pager setPage 动画期间发请求无副作用）
    setTimeout(() => {
      doLoadForTabRef.current(currentTab, 1).catch(() => {});
    }, 50);
  }, [currentTab, loaded, name, forumSortType]);

  // 最新 tab 排序切换：清列表后重拉（setForumSortType 已清最新桶）
  const handleSortChange = useCallback((sort: ForumSortType) => {
    if (sort === forumSortType) return;
    hapticForScene('toggle');
    useForumStore.getState().setForumSortType(sort);
    doLoadForTabRef.current(1, 1).catch(() => {});
  }, [forumSortType]);

  // Mark the first data render as staggered
  const hasStaggeredInitialRef = useRef(false);
  useEffect(() => {
    if (loaded && (latestThreads.length + newestThreads.length + goodThreads.length) > 0) {
      hasStaggeredInitialRef.current = true;
    }
  }, [loaded, latestThreads.length, newestThreads.length, goodThreads.length]);

  // ── 刷新与加载更多（按当前 tab） ──
  const refreshTab = useCallback(async (tab: number) => {
    if (refreshingRef.current) return;
    refreshingRef.current = true;
    setRefreshing(true);
    try {
      await doLoadForTabRef.current(tab, 1);
    } finally {
      refreshingRef.current = false;
      setRefreshing(false);
    }
    hapticForScene('toggle');
  }, []);

  const loadMoreTab = useCallback(
    async (tab: number) => {
      if (loadingMoreRef.current) return;
      const st = useForumStore.getState();
      const hasMore = tab === 0 ? st.latestHasMore : tab === 1 ? st.newestHasMore : st.goodHasMore;
      const page = tab === 0 ? st.latestPage : tab === 1 ? st.newestPage : st.goodPage;
      const count = tab === 0 ? st.latestThreads.length : tab === 1 ? st.newestThreads.length : st.goodThreads.length;
      if (!hasMore || count === 0) return;
      loadingMoreRef.current = true;
      setLoadingMore(true);
      try {
        await doLoadForTabRef.current(tab, page + 1);
      } finally {
        loadingMoreRef.current = false;
        setLoadingMore(false);
      }
    },
    [],
  );

  const handleFabRefresh = useCallback(async () => {
    if (refreshingRef.current) return;
    refreshingRef.current = true;
    try {
      const list = tabListRefs.current[currentTab];
      if (lastScrollYRef.current > 1 && list) {
        list.scrollToOffset({ offset: 0, animated: true });
        await new Promise<void>((resolve) => {
          scrollToTopResolveRef.current = resolve;
          scrollToTopTimerRef.current = setTimeout(settleScrollToTop, SCROLL_TO_TOP_FALLBACK_MS);
        });
      }
      setRefreshing(true);
      await doLoadForTabRef.current(currentTab, 1);
    } finally {
      refreshingRef.current = false;
      setRefreshing(false);
    }
    hapticForScene('toggle');
  }, [currentTab, settleScrollToTop]);

  // ── FAB ──
  const animateFab = useCallback(() => {
    fabScale.value = withSequence(withSpring(0.85, PRESS_ENTER), withSpring(1, PRESS_ENTER));
  }, [fabScale]);

  const handleFabPress = useCallback(() => {
    hapticForScene('press');
    animateFab();
    switch (forumFabFunction) {
      case 'back_to_top':
        fabHiddenRef.current = false;
        fabTranslateY.value = withSpring(0, CHROME_HIDE);
        tabListRefs.current[currentTab]?.scrollToOffset({ offset: 0, animated: true });
        break;
      case 'refresh':
      default:
        void handleFabRefresh();
        break;
    }
  }, [forumFabFunction, handleFabRefresh, animateFab, fabTranslateY, currentTab]);

  // 双击顶栏回顶（设置-浏览可关）：与 FAB 回顶同款——列表回顶并恢复被隐藏的 FAB
  const navDoubleTapEnabled = useAppPreference('navBarDoubleTapToTop', true);
  useNavDoubleTapToTop(
    () => {
      fabHiddenRef.current = false;
      fabTranslateY.value = withSpring(0, CHROME_HIDE);
      tabListRefs.current[currentTab]?.scrollToOffset({ offset: 0, animated: true });
    },
    navDoubleTapEnabled ?? true,
  );

  // ── Follow / Sign / Share / Copy / Unfollow ──
  const handleToggleFollow = useCallback(async () => {
    if (!currentForum) return;
    hapticForScene('favorite');
    try {
      if (currentForum.isLike) {
        await unfollowForum(currentForum.forumId, name);
        showToast('取消关注成功');
      } else {
        const result = await followForum(currentForum.forumId, name);
        showToast(
          result.memberSum != null && result.memberSum > 0
            ? `关注成功，本吧会员${formatCount(result.memberSum)}人`
            : '关注成功',
        );
      }
    } catch (e: any) {
      if (__DEV__) console.warn('[forum] follow ERR:', e?.message ?? String(e));
      showToast(e?.message || '网络错误，请稍后重试');
    }
  }, [currentForum, name, followForum, unfollowForum]);

  const handleSign = useCallback(async () => {
    if (!isLoggedIn) { Alert.alert('提示', '请先登录'); return; }
    if (!currentForum) return;
    if (currentForum.signInInfo?.isSignIn) {
      showToast('今天已经签到过了');
      return;
    }
    hapticForScene('action-success');
    try {
      const tbs = currentForum.tbs || '';
      const result = await signAPI(name, tbs, currentForum.forumId);
      if (result.isSuccess) {
        markForumSigned(currentForum.forumId, result.exp ?? 0);
        showToast(result.exp != null ? `签到成功，经验+${result.exp}` : '签到成功');
      } else if (result.errorCode === 1101) {
        markForumSigned(currentForum.forumId, result.exp ?? 0);
        showToast('今天已经签到过了');
      } else {
        showToast(result.errorMsg || '签到失败，请稍后重试');
      }
    } catch (e) {
      // 开发期诊断：签名/主机错误的响应体进 Metro 日志（TiebaApiError 带 rawData）
      if (__DEV__) console.warn('[sign] 失败:', e instanceof Error ? `${e.name}: ${e.message}` : String(e));
      showToast('签到失败，请稍后重试');
    }
  }, [isLoggedIn, name, currentForum, markForumSigned]);

  const handleFollowOrSign = useCallback(() => {
    if (!isLoggedIn) { Alert.alert('提示', '请先登录后再操作'); return; }
    if (!currentForum) return;
    if (currentForum.isLike) {
      if (currentForum.signInInfo?.isSignIn) return;
      handleSign();
    } else {
      handleToggleFollow();
    }
  }, [isLoggedIn, currentForum, handleSign, handleToggleFollow]);

  const handleShareForum = useCallback(async () => {
    await Share.share({ message: `${name}吧\n${buildForumUrl(name)}` });
  }, [name]);

  const handleCopyForumLink = useCallback(async () => {
    await Clipboard.setStringAsync(buildForumUrl(name));
    hapticForScene('action-success');
    Alert.alert('已复制', '吧链接已复制到剪贴板');
  }, [name]);

  const headerRight = useMemo(() => function HeaderRight() {
    return (
      <View style={styles.headerButtons}>
        {/* 签到入口已移除：吧页右上角不再显示签到 */}
        <Link href={`/forum/${encodeURIComponent(name)}/search?forumId=${currentForum?.forumId || ''}`} asChild>
          <HdrPressable style={styles.headerButton} hitSlop={8} flashRadius={10}>
            <SymbolView name="magnifyingglass" size={20} tintColor={colors.primary} />
          </HdrPressable>
        </Link>
        {/* 更多菜单：固定 44×44 方形宿主（不用 matchContents——真机导航栏内
            测量循环会把胶囊压缩，图标溢出外壳「药丸没包住更多按钮」）。
            Menu 本体 frame 撑满 44×44 + contentShape 矩形命中：默认只认
            ellipsis 字形本身，热区过小导致连点（连点又误触双击回顶）。 */}
        <ThemedHost style={styles.headerMenuSlot}>
          <Menu
            label=""
            systemImage="ellipsis"
            modifiers={[labelStyle('iconOnly'), buttonStyle('plain'), frame({ width: 44, height: 44 }), contentShape(shapes.rectangle())]}
          >
            <SWButton label="分享" systemImage="square.and.arrow.up" onPress={handleShareForum} />
            <SWButton label="复制链接" systemImage="link" onPress={handleCopyForumLink} />
            {isLoggedIn && currentForum?.isLike && (
              <SWButton label="取消关注" systemImage="person.badge.minus" role="destructive" onPress={handleToggleFollow} />
            )}
          </Menu>
        </ThemedHost>
      </View>
    );
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isLoggedIn, name, currentForum?.forumId, currentForum?.isLike, colors.primary, handleShareForum, handleCopyForumLink]);

  // ── Tab 切换 ──
  const handleSegmentChange = useCallback((value: string) => {
    hapticForScene('toggle');
    setSortMenuOpen(false);
    const tab = parseInt(value, 10);
    if (!isNaN(tab)) setCurrentTab(tab);
  }, [setCurrentTab]);

  const handlePagerChange = useCallback((index: number) => {
    setSortMenuOpen(false);
    if (index !== currentTab) setCurrentTab(index);
  }, [currentTab, setCurrentTab]);

  // 列表滚动共用处理：排序下拉随真实滚动收起、FAB 随滚动方向收放。
  // 顶部板块（卡片+置顶+segment）已在 LegendList 头内，天然跟手滚动，
  // 无需额外收起动画。底栏收纳由 NativeTabs minimizeBehavior 原生驱动。
  const handleListScroll = useCallback(
    (e: any) => {
      const y = e?.nativeEvent?.contentOffset?.y ?? 0;
      if (scrollToTopResolveRef.current && y <= 1) {
        settleScrollToTop();
      }
      // 回顶即恢复 FAB（同帖内底栏「贴顶立即显示」）：防 offset 跳变把 FAB 留在隐藏位
      if (y <= 1 && fabHiddenRef.current) {
        fabHiddenRef.current = false;
        fabTranslateY.value = withSpring(0, CHROME_HIDE);
      }
      const delta = y - lastScrollYRef.current;
      lastScrollYRef.current = y;

      if (Math.abs(delta) > 8) {
        if (sortMenuOpen && Date.now() - sortMenuOpenAtRef.current > 350) {
          setSortMenuOpen(false);
        }
        if (!fabHiddenBySetting) {
          if (delta > 0) {
            if (!fabHiddenRef.current) {
              fabHiddenRef.current = true;
              fabTranslateY.value = withSpring(FAB_HIDE_OFFSET, CHROME_HIDE);
            }
          } else if (fabHiddenRef.current) {
            fabHiddenRef.current = false;
            fabTranslateY.value = withSpring(0, CHROME_HIDE);
          }
        }
      }
    },
    [settleScrollToTop, sortMenuOpen, fabHiddenBySetting, fabTranslateY],
  );

  // ── 卡片操作 ──
  const imageViewer = useImageViewer();

  const avatar = currentForum?.avatar;
  const handleAvatarPreview = useCallback((event: any) => {
    event.stopPropagation?.();
    if (!avatar) return;
    hapticForScene('press');
    imageViewer.handleImagePress(
      [getAvatarUrl(avatar)],
      0,
      frameFromPressEvent(event, { width: 72, height: 72 }),
    );
  }, [avatar, imageViewer]);

  const handleForumDetail = useCallback(() => {
    router.push(
      `/forum/${encodeURIComponent(name)}/detail?forumId=${currentForum?.forumId || ''}`,
    );
  }, [router, name, currentForum?.forumId]);

  // 卡片动作四件套收敛到共享 hook（thermo Z3-B）：乐观点赞 + 失败回滚，
  // 未登录统一跳登录页（旧实现是 Alert）。三桶写入走 store.updateAllBuckets。
  const feedActions = useFeedCardActions({
    applyLike: (id, nextAgree) =>
      useForumStore.getState().updateAllBuckets((list) =>
        list.map((t) =>
          t.id === id
            ? { ...t, hasAgree: nextAgree, zanNum: Math.max(0, (t.zanNum || 0) + (nextAgree ? 1 : -1)) }
            : t,
        ),
      ),
    removeByAuthor: (authorId) =>
      useForumStore.getState().updateAllBuckets(
        (list) => list.filter((t) => t.authorId !== authorId),
      ),
    getLatestHasAgree: (id) => {
      const st = useForumStore.getState();
      return (
        st.latestThreads.find((t) => t.id === id)?.hasAgree ??
        st.newestThreads.find((t) => t.id === id)?.hasAgree ??
        st.goodThreads.find((t) => t.id === id)?.hasAgree
      );
    },
  });

  const handleForumMenuAction = useCallback((action: string, item: ThreadInfo) => {
    if (action === 'block') void feedActions.blockAuthor(item);
    else if (action === 'report') void feedActions.report(item);
  }, [feedActions]);

  // ── Follow button label ──
  const followBtnLabel = !isLoggedIn
    ? '关注'
    : !currentForum?.isLike
      ? '关注'
      : currentForum?.signInInfo?.isSignIn
        ? `已签到${currentForum.signInInfo.contSignNum > 0 ? ` ${currentForum.signInInfo.contSignNum}天` : ''}`
        : '签到';

  const followBtnActive = isLoggedIn && currentForum?.isLike;

  // ── 精品分类标签 ──
  const selectedClassifyLabel = goodClassifyId
    ? goodClassify.find((c) => c.classId === goodClassifyId)?.className
    : undefined;

  // 列表入场（仅首屏）
  const listEntranceOpacity = useSharedValue(0);
  const listEntranceY = useSharedValue(16);
  const listAnimatedStyle = useAnimatedStyle(() => ({
    opacity: listEntranceOpacity.value,
    transform: [{ translateY: listEntranceY.value }],
  }));
  useEffect(() => {
    if (loaded && currentForum) {
      if (reduceMotion) {
        listEntranceOpacity.value = 1;
        listEntranceY.value = 0;
        return;
      }
      listEntranceOpacity.value = withTiming(1, { duration: DURATION.enter });
      listEntranceY.value = withSpring(0, MOMENTUM);
    }
  }, [loaded, currentForum, reduceMotion, listEntranceOpacity, listEntranceY]);

  const fabAnimatedStyle = useAnimatedStyle(() => ({
    transform: [{ scale: fabScale.value }, { translateY: fabTranslateY.value }],
  }));

  // 共享列表回调（每 tab 一份，函数稳定）
  const refreshCb = useCallback(() => void refreshTab(currentTab), [refreshTab, currentTab]);
  const loadMoreCb = useCallback(() => void loadMoreTab(currentTab), [loadMoreTab, currentTab]);
  const setListRef = useCallback(
    (tab: number) => (ref: any) => {
      tabListRefs.current[tab] = ref;
    },
    [],
  );
  const loadTabCb = useCallback(
    (tab: number) => () => doLoadForTabRef.current(tab, 1),
    [],
  );

  // 顶部固定区（吧名片 + 置顶帖）：位于 segment 栏之上、不随列表滚动
  // 用户要求顺序：吧卡片 → 置顶帖 → segment → 帖子列表（对齐 Kotlin ForumHeader）
  const tabHeader = useMemo(
    () => (
      <ForumTabHeader
        name={name}
        colors={colors}
        currentForum={currentForum}
        topThreads={topThreads}
        followBtnLabel={followBtnLabel}
        followBtnActive={followBtnActive}
        isLoggedIn={isLoggedIn}
        onAvatarPreview={handleAvatarPreview}
        onFollowOrSign={handleFollowOrSign}
        onForumDetail={handleForumDetail}
      />
    ),
    [name, colors, currentForum, topThreads, followBtnLabel, followBtnActive, isLoggedIn, handleAvatarPreview, handleFollowOrSign, handleForumDetail],
  );

  // 排序（最新 tab）/ 分类（精品 tab）行：菜单开合状态在本页持有
  const fixedBar = useMemo(
    () => (
      <ForumSortBar
        currentTab={currentTab}
        sortType={forumSortType}
        sortMenuOpen={sortMenuOpen}
        onToggleSortMenu={() => {
          hapticForScene('press');
          setSortMenuOpen((v) => {
            const next = !v;
            sortMenuOpenAtRef.current = next ? Date.now() : 0;
            return next;
          });
        }}
        onCloseSortMenu={() => setSortMenuOpen(false)}
        onSortChange={handleSortChange}
        classifyLabel={selectedClassifyLabel}
        hasClassifies={goodClassify.length > 0}
        onClearClassify={() => setGoodClassifyId(null)}
        onOpenClassifyPicker={() => {
          hapticForScene('press');
          setShowClassifyPicker(true);
        }}
        colors={colors}
      />
    ),
    [currentTab, forumSortType, sortMenuOpen, colors, goodClassify.length, selectedClassifyLabel, handleSortChange],
  );

  // segment 槽位单独 memo：切 tab 时只有这里（以及分类/排序行）需要重建，
  // tabHeader（吧卡片+置顶）与列表头外壳的 memo 引用保持稳定——此前
  // topBlock 直接依赖 currentTab，切 tab 整个列表头重建、三列表 header
  // 引用全变，LegendList 连带重挂头（2026-09-01 卡顿根因一）。
  //
  // 2026-09-01 玻璃根因（深度调查定案）：UIKit 玻璃 chrome 必须在 alpha=1、
  // 在屏、已布局、有真实背板内容状态下物化；离屏/未布局时首挂一次即永久
  // 扁平（UIVisualEffectView 文档规则，legend-list#482 / liquid-glass#27 同证）。
  // 本页 segment 在 PagerView 的 SwiftUI TabView 页面 + LegendList 虚拟化容器
  // （POSITION_OUT_OF_VIEW=-1e7 停放）内，首挂落进无效状态 → 永久无玻璃。
  // 修法=布局完成（在屏有效）后重挂一次强制重新物化；segRemount 状态加进
  // deps 使 topBlock 引用更新、三列表 header 拿到新元素触发重挂。
  const [segRemount, setSegRemount] = useState(0);
  const segRemountDoneRef = useRef(false);
  const handleSegSlotLayout = useCallback(() => {
    if (segRemountDoneRef.current) return;
    segRemountDoneRef.current = true;
    requestAnimationFrame(() => setSegRemount((k) => k + 1));
  }, []);

  const segmentSlot = useMemo(
    () => (
      <View style={styles.segmentSlot} onLayout={handleSegSlotLayout}>
        <TiebaSegmentedControl
          key={`seg-${segRemount}`}
          segments={TAB_SEGMENTS}
          selectedIndex={currentTab}
          onSelect={handleSegmentChange}
        />
      </View>
    ),
    [currentTab, handleSegmentChange, handleSegSlotLayout, segRemount],
  );

  // 顶部板块（吧卡片 + 置顶 + segment + 排序/分类）：作为列表头元素传给
  // 三个 tab 的 LegendList（随列表原生滚动、完全跟手、滑到顶自然退出）。
  // segment 用原生 TiebaSegmentedControl（UIKit UISegmentedControl）：
  // 列表头内嵌套 SwiftUI Host（@expo/ui Picker）实物三连否决——嵌套断链点不到、
  // LegendList 滚动回收后 Host 渲染失败消失、二级 Host 干扰 iOS 27 顶栏材质链路。
  // UIKit 组件同源视觉、RN 树内可点。
  const topBlock = useMemo(
    () => (
      <>
        {/* headerTransparent 下内容从 y=0 起：顶部板块（列表头）显式让位
            顶栏（insets.top + NAV_BAR_H）。8-28 显式化——此前让位放在列表
            contentContainerStyle 的 paddingTop，语义依赖 LegendList 容器
            行为且随页面往返/insets 时序出现"顶栏包裹不足/足够"反复；
            移入列表头自身后任何渲染路径都从顶栏下沿开始，滚动跟手滑出不变。 */}
        <View style={{ paddingTop: insets.top + NAV_BAR_H }}>
          {tabHeader}
          {segmentSlot}
          {fixedBar}
        </View>
      </>
    ),
    [insets.top, tabHeader, segmentSlot, fixedBar],
  );

  // ── Loading state ──
  // 根节点=纯 RN View（帖子页同款）。页面级 ThemedHost 是旧 segment 方案
  // （SwiftUI Picker 需 Host 直后代）的遗留物——segment 已换原生
  // UISegmentedControl，而整页套 SwiftUI 宿主会干扰顶栏玻璃链路（嵌套
  // Host 三连否决结论、"帖子页透明为证"），滚动时顶栏不出液态玻璃。
  if ((isLoadingForums || (!loaded && !error)) && latestThreads.length === 0) {
    return (
      <View style={flattenStyle([styles.container, { backgroundColor: colors.background }, { paddingTop: insets.top + NAV_BAR_H }])}>
        <Stack.Screen options={{ title: `${name}吧`, headerRight, headerTransparent: true }} />
        <SkeletonList count={6} variant="thread" />
      </View>
    );
  }

  // ── Error state ──
  if (error && latestThreads.length === 0) {
    return (
      <View style={flattenStyle([styles.container, { backgroundColor: colors.background }, { paddingTop: insets.top + NAV_BAR_H }])}>
        <Stack.Screen options={{ title: `${name}吧`, headerRight, headerTransparent: true }} />
        <ErrorState message={error} onRetry={() => void refreshTab(0)} />
      </View>
    );
  }

  return (
    <View style={flattenStyle([styles.container, { backgroundColor: colors.background }])}>
        <Stack.Screen
          options={{
            title: `${name}吧`,
            headerLargeTitle: false,
            headerRight,
            // 最左侧右滑交给原生栈返回手势（整屏滑动退出，2026-08-28 用户反馈：
            // pager 橡皮筋让组件先位移再退出的观感很差）。页间横滑由 PagerView
            // 处理（SegmentPager 不传 canExit → overdrag 关，不再让内容位移）
            // 透明模糊顶栏（用户要求的玻璃效果）：内容从 y=0 延伸
            headerTransparent: true,
          }}
        />

        {/* 顶部板块（吧卡片+置顶+segment+排序/分类）作为列表头元素：随列表
            原生滚动、完全跟手，滑到顶自然退出（用户明确要求的行为）。
            JS 联动方案（absolute 覆盖层 + translateY=-min(y,H)）已回退：
            滚动信号走 JS onScroll（~15Hz）追不上原生 120Hz 滚动 → 板块相对
            帖子顿挫；且平移上限只抵自身高度、未计起始让位 → 永远停在顶栏
            下沿滑不出去。 */}
        <Animated.View style={[{ flex: 1 }, listAnimatedStyle]}>
          <SegmentPager
            pageIndex={currentTab}
            onPageIndexChange={handlePagerChange}
          >
            {TAB_SEGMENTS.map((s, i) => {
              const sem = tabSemantics(i, forumSortType);
              return (
                <View key={s.value} style={styles.pagerPage}>
                  <ForumTabList
                    tab={i}
                    timeType={sem.timeType}
                    colors={colors}
                    insets={insets}
                    isFocused={isFocused}
                    loaded={loaded}
                    header={topBlock}
                    refreshing={refreshing}
                    loadingMore={loadingMore}
                    animateEntry={!hasStaggeredInitialRef.current}
                    onRefresh={refreshCb}
                    onLoadMore={loadMoreCb}
                    onScroll={handleListScroll}
                    onAgree={feedActions.like}
                    onShare={feedActions.share}
                    onMenuAction={handleForumMenuAction}
                    onImagePress={imageViewer.handleImagePress}
                    setListRef={setListRef(i)}
                    loadTab={loadTabCb(i)}
                  />
                </View>
              );
            })}
          </SegmentPager>
        </Animated.View>

        {/* ── FAB（液态玻璃胶囊；位置走 fabTop 顶部锚定——page 级宿主底边不可信） ── */}
        {!fabHiddenBySetting && (
          <Animated.View style={[styles.fabContainer, { top: fabTop }, fabAnimatedStyle]}>
            <GlassView
              borderRadius={Radius.capsule}
              glassEffectStyle="clear"
              tintColor={isDark ? 'rgba(28,28,30,0.18)' : 'rgba(255,255,255,0.18)'}
              style={styles.fab}
            >
              <HdrPressable
                effect="hdr"
                onPress={handleFabPress}
                style={styles.fabPressable}
                flashRadius={Radius.capsule}
                accessibilityRole="button"
                accessibilityLabel={forumFabFunction === 'back_to_top' ? '回到顶部' : '刷新'}
              >
                <SymbolView
                  name={forumFabFunction === 'back_to_top' ? 'arrow.up' : 'arrow.clockwise'}
                  size={22}
                  tintColor={colors.text}
                  weight="semibold"
                />
              </HdrPressable>
            </GlassView>
          </Animated.View>
        )}

        {/* ── Image Viewer ── */}
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

        {/* ── Good Classify Picker Modal ── */}
        <ClassifyPickerSheet
          visible={showClassifyPicker}
          onClose={() => setShowClassifyPicker(false)}
          goodClassify={goodClassify}
          goodClassifyId={goodClassifyId}
          setGoodClassifyId={setGoodClassifyId}
          colors={colors}
        />
    </View>
  );
}

// ────────────────────────────────────────────────────────────
// Styles
// ────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: { flex: 1 },
  // pager 单页容器
  pagerPage: { flex: 1 },

  // ── 顶部板块列表头容器（卡片+置顶+segment+排序），随列表滚动 ──
  // 分段控件槽位：原生 UIKit 控件（TiebaSegmentedControl），横向入边距
  // 对齐卡片；44pt 点击区（控件本身 ~32pt 居中）
  segmentSlot: {
    width: '100%',
    paddingHorizontal: Spacing.lg,
  },

  fabContainer: {
    position: 'absolute',
    right: Spacing.xl,
    // 盖过顶板块覆盖层（zIndex 50）与列表；显式 52×52 防宿主测量异常塌缩成
    // 0×0（FAB「真机不显示」保底）
    zIndex: 999,
    width: 52,
    height: 52,
  },
  fab: {
    width: 52,
    height: 52,
    borderRadius: Radius.capsule,
    justifyContent: 'center',
    alignItems: 'center',
  },
  fabPressable: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },

  // ── Header buttons ──
  headerButtons: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  headerButton: { padding: Spacing.sm },
  // 更多菜单宿主：固定 44×44 包住系统胶囊（不用 matchContents，防真机压缩）
  headerMenuSlot: { width: 44, height: 44 },
});
