// ============================================================
// TiebaLite React Native - Browsing History Page
// Date-grouped sections with segments for threads/forums,
// matching com.huanchengfly.tieba.post.ui.page.HistoryPage
//
// 视觉：帖记录与 explore/搜索同款 TweetCard（X 式卡片，2026-08-28
// 用户要求同步信息流布局与功能：作者行 + 多图横带 + 吧名药丸 +
// 操作栏 + 图片长按菜单 + ImageViewer 大图）；吧记录非帖数据
// （无 thread 概念）保留 CompactFeedRow。删除交互为 iOS 原生
// 左滑出现红色「删除」按钮。
// 顶栏：分段控件 + 清除全部同一行、无底衬背景、两侧留边不贴屏。
// ============================================================

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  View,
  StyleSheet,
  Text,
    Alert,
  RefreshControl,
} from 'react-native';
import { LegendList } from '@legendapp/list/react-native';
import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import Animated, { useAnimatedStyle } from 'react-native-reanimated';
import type { SharedValue } from 'react-native-reanimated';
import ReanimatedSwipeable from 'react-native-gesture-handler/ReanimatedSwipeable';
import type { SwipeableMethods } from 'react-native-gesture-handler/ReanimatedSwipeable';
import { SymbolView } from '@/components/ui/SymbolView';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { hapticForScene } from '@/theme/hapticsMap';

import { Picker, Text as SWText, HStack, VStack, RNHostView } from '@expo/ui/swift-ui';
import { pickerStyle, tag, frame, padding } from '@expo/ui/swift-ui/modifiers';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { EmptyState } from '@/components/ui/EmptyState';
import { ErrorState } from '@/components/ui/ErrorState';
import { SkeletonList } from '@/components/ui/Skeleton';
import { CompactFeedRow } from '@/components/feed/CompactFeedRow';
import TweetCard from '@/components/feed/TweetCard';
import ImageViewer from '@/components/ImageViewer';
import { NAV_BAR_H } from '@/constants/layout';
import { useThemeColors } from '@/theme/ThemeContext';
import {Spacing, typographyStyles, Radius} from '@/theme';
import type { GroupedRow } from '@/utils/forumUsers';
import type { HistoryItem, MediaInfo, ThreadInfo } from '@/types';
import { pbPage } from '@/services/api/endpoints/thread';
import { useImageViewer } from '@/hooks/useImageViewer';
import { useForumAvatarStore, forumAvatarKey } from '@/stores/forumAvatarCache';
import { useFeedCardActions } from '@/hooks/useFeedCardActions';
import { GlassView } from '@/components/ui/GlassView';
import {
  getVisitHistory,
  removeVisit,
  clearVisitHistory,
  updateThreadAuthorInfo,
} from '@/services/storage/visitHistory';

const TABS = [
  { label: '贴子记录', value: 'thread' },
  { label: '经过贴吧', value: 'forum' },
];

type HistoryRow = GroupedRow<HistoryItem>;

const historyKeyExtractor = (row: HistoryRow) => row.key;

/** pbPage 懒回填的帖级补充数据（不落库，仅内存态供渲染合并） */
interface BackfillExtra {
  mediaList?: MediaInfo[];
  forumAvatar?: string;
}

/**
 * 历史帖记录 → 信息流 ThreadInfo 轻量投影（对齐收藏页 favoriteToThreadInfo）：
 * 历史只落库标题/作者/时间，计数与点赞态全缺 —— replyNum/zanNum/shareNum
 * 置 0（操作栏保留 X 式形态；历史无 agreeNum/opAgree 数据路径，点赞不接
 * 乐观更新，点击仅卡片内建触感反馈）；authorId 缺失 → 头像点击安全短路。
 * 媒体（多图横带/ImageViewer 大图）来自 backfill 的 pbPage 缓存；访问时间
 * 就近充当 createTime 展示相对时间（历史无发帖时间字段）。
 */
function historyThreadToThreadInfo(item: HistoryItem, extra?: BackfillExtra, forumAvatar = ''): ThreadInfo {
  const media = extra?.mediaList ?? [];
  return {
    id: item.threadId || item.id,
    title: item.title || '',
    forumId: item.forumId || '',
    forumName: item.forumName || '',
    forumAvatar: extra?.forumAvatar || forumAvatar,
    authorId: '',
    authorName: item.authorName || '',
    authorNameShow: '',
    authorPortrait: item.authorPortrait || '',
    authorLevelId: 0,
    replyNum: 0,
    viewNum: 0,
    lastTime: item.timestamp,
    createTime: item.timestamp,
    isTop: false,
    isGood: false,
    isVideo: media.some((m) => m.type === 'video'),
    mediaList: media,
    abstract: '',
    firstPostContent: [],
    zanNum: 0,
    shareNum: 0,
    hasAgree: false,
  };
}

/** iOS 原生红色删除钮的宽度（左滑露出的动作条） */
const DELETE_BTN_WIDTH = 88;
/** 顶栏行内边距/间距（与列表卡片边距一致） */
const HEADER_H_PAD = Spacing.lg;
const HEADER_GAP = 10;

export default function HistoryPage() {
  const { tab: initialTab } = useLocalSearchParams<{ tab?: string }>();
  const insets = useSafeAreaInsets();
  const router = useRouter();
  const { colors } = useThemeColors();
  const [activeTab, setActiveTab] = useState(initialTab === 'forum' ? 'forum' : 'thread');
  const [history, setHistory] = useState<HistoryItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [refreshing, setRefreshing] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // tab 切换竞态守卫（usePagedList 同款 seq 模式）：快速切换「贴子记录/
  // 经过贴吧」时，旧 tab 的 in-flight 读取返回后不得覆盖新 tab 的数据。
  const loadSeqRef = useRef(0);
  const loadHistory = useCallback(async () => {
    const seq = ++loadSeqRef.current;
    setError(null);
    try {
      const result = await getVisitHistory(activeTab as 'thread' | 'forum');
      if (seq !== loadSeqRef.current) return;
      setHistory(result);
      // 吧头像补齐（全站统一缓存）：帖/吧记录走同一个 store——已关注吧
      // 零网络直查，未关注吧按名实时拉；缺失期间保持灰底/DB 兜底。
      useForumAvatarStore.getState().ensureAvatars(result);
    } catch (e) {
      if (seq !== loadSeqRef.current) return;
      setHistory([]);
      // 之前只 setHistory([]) 从不 setError，死代码分支；补上错误态让重试可触发。
      setError(e instanceof Error ? e.message : '加载失败');
    } finally {
      if (seq !== loadSeqRef.current) return;
      setLoading(false);
      setRefreshing(false);
    }
  }, [activeTab]);
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- tab switch resets list state before loading the new history tab.
    setLoading(true);
    setHistory([]);
    loadHistory();
  }, [loadHistory]);
  const handleRefresh = useCallback(async () => {
    setRefreshing(true);
    await loadHistory();
    hapticForScene('toggle');
  }, [loadHistory]);
  // 错误态重试走独立入口：置 loading=true 走骨架屏。handleRefresh 只置
  // refreshing——错误态下列表区若直接复用它会先闪一帧空态（EmptyState）
  // 再出数据（loading 未置 true，error 又被清掉）。
  const handleRetry = useCallback(async () => {
    setLoading(true);
    await loadHistory();
  }, [loadHistory]);
  const imageViewer = useImageViewer();
  // 吧头像统一缓存订阅（ensure 在 loadHistory 出口；渲染期逐条合并）
  const avatarMap = useForumAvatarStore((s) => s.avatars);
  // 只消费 share（历史帖用 threadId 拼分享 URL）；历史无点赞数据路径
  // （无 agreeNum/opAgree），like 不接入本页，applyLike 占位不会被调用。
  const feedActions = useFeedCardActions({ applyLike: () => {} });
  const handleClearAll = useCallback(() => {
    void hapticForScene('destructive');
    Alert.alert('清空记录', '确定要清空所有浏览记录吗？此操作不可恢复。', [
      { text: '取消', style: 'cancel' },
      {
        text: '清空',
        style: 'destructive',
        onPress: async () => {
          try {
            await clearVisitHistory(activeTab as 'thread' | 'forum');
            setHistory([]);
            hapticForScene('action-success');
          } catch {
            Alert.alert('错误', '清空失败');
          }
        },
      },
    ]);
  }, [activeTab]);
  // Group items by date: 今天 / 昨天 / 更早
  const sections = useMemo(() => {
    const now = new Date();
    const todayStart = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
    const yesterdayStart = todayStart - 86400000;
    const grouped: Record<string, HistoryItem[]> = {
      '今天': [],
      '昨天': [],
      '更早': [],
    };
    history.forEach((item) => {
      const ts = item.timestamp;
      if (ts >= todayStart) {
        grouped['今天'].push(item);
      } else if (ts >= yesterdayStart) {
        grouped['昨天'].push(item);
      } else {
        grouped['更早'].push(item);
      }
    });
    return Object.entries(grouped)
      .filter(([, items]) => items.length > 0)
      .map(([title, data]) => ({ title, data }));
  }, [history]);
  // 分组展平：header 的 LegendList key 直接用节标题（今天/昨天/更早天然
  // 唯一），不再内嵌组下标——分组增减时 header key 保持不变，LegendList
  // key 稳定（flattenGroupRows 的 `h-<prefix>-<gi>` 下标 key 会随节位移抖动）。
  const historyRows = useMemo<HistoryRow[]>(() => {
    const rows: HistoryRow[] = [];
    sections.forEach((section) => {
      rows.push({
        kind: 'header',
        key: `h-${section.title}`,
        title: section.title,
        count: section.data.length,
      });
      section.data.forEach((item) => {
        rows.push({
          kind: 'item',
          key: `${item.type}-${item.threadId || item.forumName || ''}-${item.timestamp}`,
          item,
        });
      });
    });
    return rows;
  }, [sections]);

  const performDelete = useCallback(async (item: HistoryItem) => {
    try {
      const filtered = await removeVisit(
        (h) =>
          h.type === item.type &&
          h.timestamp === item.timestamp &&
          h.threadId === item.threadId &&
          h.forumName === item.forumName,
      );
      setHistory(filtered);
      hapticForScene('action-success');
    } catch {
      Alert.alert('错误', '删除失败');
    }
  }, []);

  // ── 老记录作者信息 + 媒体回填 ──
  // 历史只存档标题+作者名/头像（老记录连作者名都没有）。对可见帖记录，按
  // threadId 懒拉取 pbPage(threadId,1) 的 ThreadInfo：作者名/头像/吧名写回
  // DB（updateThreadAuthorInfo，只补空字段），mediaList/forumAvatar 仅存
  // 内存缓存（DB 无媒体列，不加 schema）供 TweetCard 渲染多图横带。缓存
  // 命中即不再请求；backfillBusyRef 防并发重复请求；失败进 30s 冷却，之后
  // 滚到/重进页面再试。缓存写入靠 setHistory 新引用触发重渲染（ref 变化
  // 不驱动 React），由 map 恒返回新数组承担。
  const backfillBusyRef = useRef<Set<string>>(new Set());
  const backfillFailedAtRef = useRef<Map<string, number>>(new Map());
  const backfillExtraRef = useRef<Map<string, BackfillExtra>>(new Map());
  const backfillAuthorInfo = useCallback(async (item: HistoryItem) => {
    if (item.type !== 'thread' || !item.threadId) return;
    if (backfillExtraRef.current.has(item.threadId)) return;
    if (backfillBusyRef.current.has(item.threadId)) return;
    const lastFail = backfillFailedAtRef.current.get(item.threadId) ?? 0;
    if (Date.now() - lastFail < 30000) return;
    backfillBusyRef.current.add(item.threadId);
    try {
      const { thread } = await pbPage(item.threadId, 1);
      const authorName = thread?.authorName ?? '';
      const authorPortrait = thread?.authorPortrait ?? '';
      const forumName = thread?.forumName ?? '';
      backfillExtraRef.current.set(item.threadId, {
        mediaList: thread?.mediaList,
        forumAvatar: thread?.forumAvatar,
      });
      if (authorName || authorPortrait || forumName) {
        try {
          await updateThreadAuthorInfo(item.threadId, { authorName, authorPortrait, forumName });
        } catch {
          // 写库失败不阻塞渲染合并（缓存已生效）；下次进入会再走一次回填
        }
      }
      setHistory((prev) =>
        prev.map((h) =>
          h.type === 'thread' && h.threadId === item.threadId
            ? {
                ...h,
                authorName: h.authorName || authorName || undefined,
                authorPortrait: h.authorPortrait || authorPortrait || undefined,
                forumName: h.forumName || forumName || undefined,
              }
            : h,
        ),
      );
      backfillFailedAtRef.current.delete(item.threadId);
    } catch {
      // 失败（网络/帖子已删）保留占位；冷却后下次渲染重试
      backfillFailedAtRef.current.set(item.threadId, Date.now());
    } finally {
      backfillBusyRef.current.delete(item.threadId);
    }
  }, []);

  const renderHistoryItem = useCallback(
    (item: HistoryItem) => {
      const isThread = item.type === 'thread';
      if (isThread && item.threadId) {
        // 懒回填：作者名/头像/吧名写回 DB，媒体/吧头像进内存缓存（见上）
        backfillAuthorInfo(item);
      }

      // 帖记录：与 explore/搜索同款 TweetCard（X 式卡片：作者行 + 多图横带 +
      // 吧名药丸 + 操作栏 + 图片长按菜单 + ImageViewer 大图）。历史跨吧，
      // showForumPill 开启；timeType="create" 以访问时间充当相对时间展示。
      if (isThread) {
        const avatarKey = forumAvatarKey(item);
        const storeAvatar = avatarKey ? avatarMap[avatarKey]?.avatar ?? '' : '';
        const thread = historyThreadToThreadInfo(
          item,
          backfillExtraRef.current.get(item.threadId || item.id),
          storeAvatar,
        );
        return (
          <SwipeToDeleteRow
            onDelete={() => performDelete(item)}
            accessibilityLabel="删除这条记录"
          >
            <TweetCard
              thread={thread}
              timeType="create"
              showForumPill
              imageContextMenu
              onImagePress={imageViewer.handleImagePress}
              onShare={feedActions.share}
            />
          </SwipeToDeleteRow>
        );
      }

      // 吧记录：非帖数据（无 thread 概念），保留 CompactFeedRow 展示
      // 吧头像 + 吧名 +「浏览过这个吧」；头像优先 DB 落库值，缺的走
      // 统一缓存（老记录 avatar 列为空时补齐）
      const primaryName = item.forumName || '未知';
      const forumAvatarKeyOf = forumAvatarKey(item);
      const cachedAvatar = forumAvatarKeyOf ? avatarMap[forumAvatarKeyOf]?.avatar : undefined;
      return (
        <SwipeToDeleteRow
          onDelete={() => performDelete(item)}
          accessibilityLabel="删除这条记录"
        >
          <CompactFeedRow
            displayName={primaryName}
            avatarSource={item.avatar || cachedAvatar || null}
            avatarInitial={primaryName.charAt(0)}
            abstract="浏览过这个吧"
            onPress={() => {
              hapticForScene('press');
              router.push(`/forum/${encodeURIComponent(item.forumName || '')}`);
            }}
          />
        </SwipeToDeleteRow>
      );
    },
    [router, performDelete, backfillAuthorInfo, imageViewer.handleImagePress, feedActions.share, avatarMap],
  );

  const renderRow = useCallback(
    ({ item }: { item: HistoryRow }) => {
      if (item.kind === 'header') {
        return (
          <View style={[styles.sectionHeader, { backgroundColor: colors.background }]}>
            <Text style={[styles.sectionTitle, { color: colors.textSecondary }]}>
              {item.title}
            </Text>
          </View>
        );
      }
      if (item.kind !== 'item') return null;
      return renderHistoryItem(item.item);
    },
    [colors, renderHistoryItem],
  );

  // 顶栏（HStack 直接后代）必须始终挂载：此前切 tab 时 setLoading(true)
  // 让整个组件提前 return 骨架屏，SwiftUI 分段控件也随之卸载；数据回来整页
  // 重挂时控件带着默认入场动画从角落"飞入"→ 用户看到的"先歪到右上角再回来"。
  // 现在 loading/error 只切换列表区域，顶栏不再卸载重挂。
  return (
    // 页面级 ThemedHost（ignoreSafeArea 让 VStack 从 y=0 起）：分段控件必须是
    // Host 直接后代才能全宽渲染 + 触摸可点（iOS 26/27 嵌套 _UIHostingView
    // 触摸断链，explore 同款 VStack/HStack 范式）；控件位置由 SwiftUI 布局
    // 决定，列表渲染不再引起"1 秒后错位"。
    <ThemedHost style={{ flex: 1 }} ignoreSafeArea="container">
      <VStack spacing={0} modifiers={[frame({ maxWidth: 10000, maxHeight: 10000 })]}>
        {/* 顶栏：分段控件 + 清除全部同一行（HStack 直接后代；清除按钮经
            RNHostView 嵌入 SwiftUI，行对齐由 SwiftUI 布局保证） */}
        <HStack
          spacing={HEADER_GAP}
          modifiers={[
            padding({ horizontal: HEADER_H_PAD, top: insets.top + NAV_BAR_H, bottom: 6 }),
            frame({ maxWidth: 10000, alignment: 'leading' }),
          ]}
        >
          <Picker
            selection={activeTab}
            onSelectionChange={(value: string) => {
              hapticForScene('toggle');
              setActiveTab(value);
            }}
            modifiers={[pickerStyle('segmented')]}
          >
            {TABS.map((t) => (
              <SWText key={t.value} modifiers={[tag(t.value)]}>{t.label}</SWText>
            ))}
          </Picker>
          {/* matchContents 必须开：RNHostView 默认撑满（maxWidth/maxHeight
              .infinity），会把 HStack 撑到整屏高——segment 顶到顶部、按钮
              巨大化、列表被推到底部（8-25 真机大片空白根因） */}
          <RNHostView matchContents>
            <HdrPressable
              onPress={handleClearAll}
              style={styles.clearBtn}
              accessibilityRole="button"
              accessibilityLabel="清除全部记录"
              hitSlop={6}
            >
              <GlassView
                glassEffectStyle="regular"
                isInteractive
                borderRadius={Radius.chip}
                style={styles.clearBtnGlass}
              >
                <View style={styles.clearBtnInner}>
                  <SymbolView name="trash" size={13} weight="medium" tintColor={colors.textSecondary} />
                  <Text style={[styles.clearBtnText, { color: colors.textSecondary }]}>
                    清除全部
                  </Text>
                </View>
              </GlassView>
            </HdrPressable>
          </RNHostView>
        </HStack>

        {/* RN 内容（列表/骨架/错误） */}
        <RNHostView>
          <View style={[styles.container, { backgroundColor: colors.background }]}>
            {/* 透明顶栏（系统玻璃）：内容从 y=0 延伸，顶部由顶栏 HStack 的
                padding 让位，不再叠 RN 层 paddingTop */}
            <Stack.Screen options={{ headerTransparent: true }} />
      {/* 顶栏（HStack 直接后代）已在 SwiftUI 层渲染；这里只有列表/骨架/错误 */}
      {loading && history.length === 0 ? (
        <View style={styles.skeletonWrap}>
          <SkeletonList variant="thread" count={6} />
        </View>
      ) : error && history.length === 0 ? (
        <ErrorState message={error} onRetry={handleRetry} />
      ) : (
        <LegendList
          data={historyRows}
          keyExtractor={historyKeyExtractor}
          renderItem={renderRow}
          getItemType={(row) => row.kind}
          decelerationRate="normal"
          drawDistance={250}
          ListEmptyComponent={
            <EmptyState
              title="暂无记录"
              description={
                activeTab === 'thread'
                  ? '还没有浏览过贴子'
                  : '还没有浏览过贴吧'
              }
              icon="clock.arrow.circlepath"
            />
          }
          contentContainerStyle={[
            styles.listContent,
            { paddingBottom: insets.bottom + Spacing.lg },
            history.length === 0 && styles.emptyList,
          ]}
          refreshControl={
            <RefreshControl
              refreshing={refreshing}
              onRefresh={handleRefresh}
              tintColor={colors.primary}
            />
          }
        />
      )}
      {/* 大图查看器（帖卡媒体点击；图片长按菜单由 TweetCard 内 MediaPager 承担） */}
      <ImageViewer
        images={imageViewer.imageViewerImages}
        initialIndex={imageViewer.imageViewerIndex}
        visible={imageViewer.imageViewerVisible}
        onClose={imageViewer.closeImageViewer}
      />
          </View>
        </RNHostView>
      </VStack>
    </ThemedHost>
  );
}

// ── 内嵌小组件 ──

/**
 * iOS 原生左滑删除：滑动露出右侧固定宽红色「删除」钮，按钮随滑出
 * 渐显/放大（progress 驱动），点击删除并闭合；松手过阈值弹簧展开、
 * 未过则回弹。动画与视觉效果对齐系统邮件/列表的 swipe action。
 */
function SwipeToDeleteRow({
  children,
  onDelete,
  accessibilityLabel,
}: {
  children: React.ReactNode;
  onDelete: () => void;
  accessibilityLabel?: string;
}) {
  const ref = useRef<SwipeableMethods>(null);
  // RNGH 在渲染时把 progress（滑动进度 SharedValue）注入 render prop；
  // 用 ref 存引用，动画样式在组件顶层定义（避免在 render prop 内调用 hook）。
  const progressRef = useRef<SharedValue<number> | null>(null);
  const actionStyle = useAnimatedStyle(() => {
    const p = progressRef.current?.value ?? 1;
    return {
      opacity: 0.35 + p * 0.65,
      transform: [{ scale: 0.6 + p * 0.4 }],
    };
  });

  const renderRightActions = (progress: SharedValue<number>) => {
    progressRef.current = progress;
    return (
      <Animated.View style={[styles.deleteAction, actionStyle]}>
        <HdrPressable
          style={styles.deleteBtn}
          onPress={() => {
            ref.current?.close();
            void hapticForScene('destructive');
            onDelete();
          }}
          accessibilityRole="button"
          accessibilityLabel={accessibilityLabel ?? '删除'}
        >
          <SymbolView name="trash" size={17} weight="semibold" tintColor="#FFFFFF" />
          <Text style={styles.deleteText}>删除</Text>
        </HdrPressable>
      </Animated.View>
    );
  };

  return (
    <ReanimatedSwipeable
      ref={ref}
      renderRightActions={renderRightActions}
      friction={2}
      rightThreshold={40}
      overshootRight={false}
      enableTrackpadTwoFingerGesture
    >
      {children}
    </ReanimatedSwipeable>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  skeletonWrap: { paddingHorizontal: Spacing.md, paddingTop: Spacing.md },
  // 液态玻璃「清除全部」胶囊（clear 玻璃 + 原生交互；realTime=false 显式
  // 静态：小按钮不值得占每屏实时玻璃预算）
  // alignSelf flex-start：宿主内 RN 视图直挂屏幕根节点（默认 alignItems
  // stretch → 按整屏宽测量），matchContents 会把整屏宽回写给按钮——
  // HStack 里 Picker 被挤成 0 宽不可见、按钮独占一行（8-25 真机实测）
  clearBtn: {
    alignSelf: 'flex-start',
  },
  clearBtnGlass: {
    paddingHorizontal: Spacing.xs,
    paddingVertical: 2,
  },
  clearBtnInner: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 5,
    paddingHorizontal: 8,
    paddingVertical: 4,
  },
  clearBtnText: {
    fontSize: 13,
    fontWeight: '500',
  },
  listContent: { paddingTop: 2 },
  emptyList: { flex: 1 },
  // Section Header（紧贴顶栏，去掉中间大片空白；左缘与卡片对齐 10pt 屏边距）
  sectionHeader: {
    paddingTop: 6,
    paddingBottom: 4,
    paddingHorizontal: 10,
  },
  sectionTitle: typographyStyles.footnoteBold,
  // iOS 原生左滑删除按钮
  deleteAction: {
    width: DELETE_BTN_WIDTH,
    marginVertical: 4,
    marginRight: 16,
    borderRadius: 16,
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  deleteBtn: {
    flex: 1,
    backgroundColor: '#FF3B30',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
  },
  deleteText: { ...typographyStyles.footnoteBold, color: '#FFFFFF' },
});
