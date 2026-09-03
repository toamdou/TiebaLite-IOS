/* eslint-disable react-hooks/immutability -- Reanimated shared values are mutable refs; React Compiler cannot model them. */
/**
 * Thread Detail Page (帖子详情) — Apple News + Twitter/X + iOS 26+ design
 *
 * Layout: Stack header（forum chip）→ ThreadHeader（主贴卡 + 回复工具栏）→
 * Reply cards（PostCard）→ Floating bar（复制/点赞/收藏/更多，滚动自动隐藏）→
 * More sheet（more.tsx formSheet，动作经 DeviceEventEmitter 回本页）→
 * ThreadJumpDialog（跳页）→ RefreshControl。
 *
 * Split（4 抽 1 留，#8）：本文件保留 paged 装配 / renderPost / LegendList /
 * sheet 挂载 / ImageViewer / visited；其余组件见 ThreadHeader.tsx /
 * ThreadFloatingBar.tsx / ThreadJumpDialog.tsx / useThreadPageActions.ts /
 * ThreadStagger.tsx。
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { View, StyleSheet, DeviceEventEmitter, RefreshControl, Text, Dimensions } from 'react-native';
import { ConfirmationDialog, Button as SWButton, Text as SWText } from '@expo/ui/swift-ui';
import { useSharedValue, withTiming } from 'react-native-reanimated';
import { LegendList, type LegendListRef } from '@legendapp/list/react-native';
import { useLocalSearchParams, Stack, router } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Image } from 'expo-image';
import { cacheParentPost } from '@/stores/parentPostCache';
import { Toast, type ToastRef } from '@/components/ui/Toast';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { EmptyState } from '@/components/ui/EmptyState';
import { ErrorState } from '@/components/ui/ErrorState';
import ImageViewer from '@/components/ImageViewer';
import PostCard from '@/components/thread/PostCard';
import { ThreadHeader, ForumAvatarWithHdr } from '@/components/thread/ThreadHeader';
import { ThreadFloatingBar, useFloatingBarAutoHide } from '@/components/thread/ThreadFloatingBar';
import { ThreadJumpDialog } from '@/components/thread/ThreadJumpDialog';
import { StaggerItem } from '@/components/thread/ThreadStagger';
import { LoadMoreFooter } from '@/components/ui/LoadMoreFooter';
import { SkeletonList } from '../../components/ui/Skeleton';
import { Avatar } from '@/components/ui/Avatar';
import { useThemeColors } from '@/theme/ThemeContext';
import { RadiusStyle } from '@/theme';
import { EASE_OUT, DURATION } from '@/theme/springs';
import { hapticForScene } from '@/theme/hapticsMap';
import { useAuthStore } from '@/stores/authStore';
import { useMediaBus } from '@/stores/mediaBusStore';
import { mediaKeysOf } from '@/utils/feedMedia';
import { consumeThreadSnapshot } from '@/utils/threadSnapshot';
import { useBlockFilter } from '@/hooks/useBlockFilter';
import { useAppPreference } from '@/hooks/useAppPreference';
import { useNavDoubleTapToTop } from '@/hooks/useNavDoubleTapToTop';
import { useReducedMotion } from '@/hooks/useReducedMotion';
import { useImageViewer } from '@/hooks/useImageViewer';
import { useSourceRevealConsumer, armSourceReveal, armSourceRevealRow, type RevealTarget } from '@/hooks/useViewerSourceReveal';
import { NAV_BAR_H } from '@/constants/layout';
import { usePagedList } from '@/hooks/usePagedList';
import { useThreadPageActions, type ConfirmRequest, type ThreadExtra } from '@/hooks/useThreadPageActions';
import { recordThreadVisit } from '@/services/storage/visitHistory';
import { pbPage } from '@/services/api/endpoints/thread';
import { flattenStyle } from '@/utils';
import type { PostInfo, ThreadInfo } from '@/types';

/** Hard cap for retained posts in a thread to bound long-thread memory. */
const MAX_POSTS = 400;
const SCREEN_H = Dimensions.get('window').height;

/**
 * 首屏入场级联窗口：入场总时长 = enter + stagger × (窗口-1)。若直接按 posts.length
 * 计算，几百楼的帖子总时长达数分钟，末尾楼层在级联曲线里永远停在低透明度（"越滑
 * 越白"）。限窗口后只对前 N 层级联，其余保持不透明。
 */
const ENTRANCE_ROW_WINDOW = 12;

/** 缺 id 时生成唯一占位键（服务端异常数据防多条 '' 键冲突）—— 本行由 subposts 修复代理改动，仅此一行 */
const replyKeyExtractor = (item: PostInfo, index: number) =>
  item.id || `reply-anon-${index}`;

const PostSeparator = () => <View style={styles.postSep} />;

/** pbPage 请求参数（fetcher / paged / loadPage / 跳页共用） */
type FetchParams = { id: string; postId?: string; seeLz: boolean; reverse: boolean };

export default function ThreadPage() {
  const { id, postId, seeLz: initialSeeLz, fromFavorites } = useLocalSearchParams<{
    id: string; postId?: string; seeLz?: string; fromFavorites?: string;
  }>();
  // 列表→详情已知数据快照：仅首帧消费一次（useMemo 依赖不变不再读），
  // 帖子首包返回后由完整 PostCard 替换；深链/冷启无快照=原整页骨架
  const knownSnapshot = useMemo(() => consumeThreadSnapshot(String(id ?? '')), [id]);
  const insets = useSafeAreaInsets();
  const { colors } = useThemeColors();
  const { reduceMotion } = useReducedMotion();
  const isLoggedIn = useAuthStore((s) => s.isLoggedIn);
  const accountUid = useAuthStore((s) => s.account?.uid);
  const { filterPosts, blockedWords, blockedUsers } = useBlockFilter();
  const hideBlockedContent = useAppPreference('hideBlockedContent', false);
  const collectSeeLz = useAppPreference('collectSeeLz', true);
  const collectDescSort = useAppPreference('collectDescSort', false);
  const incognitoMode = useAppPreference('incognitoMode', false);
  const showShortcutInThread = useAppPreference('showShortcutInThread', true);
  const openFromFavorites = fromFavorites === '1';
  // seeLz/reverse 初值收敛：paged params 与 useState 共用同一来源（低9）
  const seeLzInitial = initialSeeLz === '1' || (openFromFavorites && !!collectSeeLz);
  const reverseInitial = openFromFavorites && !!collectDescSort;

  // fetcher 必须 useCallback 稳定引用：内联箭头每次渲染新身份 → run/load 重建 → 请求风暴（remote 版曾踩）
  const fetchThreadPage = useCallback(
    async (page: number, params: FetchParams, signal?: AbortSignal) => {
      try {
        const data = await pbPage(params.id, page, params.postId, params.seeLz, false, params.reverse ? 1 : 0, signal);
        return {
          items: data.posts,
          hasMore: data.page.hasMore,
          nextPage: data.page.current + 1,
          extra: { thread: data.thread, total: data.page.total, current: data.page.current ?? page },
        };
      } catch (e) {
        if (__DEV__) console.warn('[thread] pbPage ERR page=', page, 'err=', e);
        throw e;
      }
    },
    [],
  );
  const paged = usePagedList<PostInfo, FetchParams, ThreadExtra>({
    fetcher: fetchThreadPage,
    params: { id, postId, seeLz: seeLzInitial, reverse: reverseInitial },
    maxItems: MAX_POSTS,
  });
  const {
    items: posts,
    hasMore,
    loading,
    refreshing,
    loadingMore,
    error,
    extra,
    load,
    refresh: handleRefresh,
    loadMore: handleLoadMore,
    setItems: setPosts,
    setExtra,
  } = paged;
  const totalPages = extra?.total ?? 0;
  // 当前展示页（extra.current；paged.page 是"下一页"语义，直接展示会 +1）
  const threadPageCurrent = Math.max(1, extra?.current ?? 1);
  // 主贴判定：无 postId 定位时 paged 列表 [0] 恒为楼主帖（服务端每页都回吐楼主
  // 楼层），主贴卡固定钉顶、翻页不翻转（旧实现用 threadPageCurrent===1 判定，
  // loadMore 后翻转 → 主贴卡消失 + 楼主楼层重复，isFirstPage 翻转 bug）；
  // 带 postId（通知/收藏跳转）时 posts[0] 是目标回复，不做主贴卡。
  const hasPinnedOp = !postId;

  // ── 主贴独立钉住（高1）+ thread 收敛（中4）：thread/pinnedMainPost 只在
  // initial/jump（整页替换）时更新（loadPage 先置 needsRepinRef；'more' 追加
  // 与 MAX_POSTS 头部驱逐不置 flag → memo 不击穿、visit 不重复；吞错时由
  // pageLoadVersion 兜底消费 flag）
  const [thread, setThread] = useState<ThreadInfo | null>(null);
  const [pinnedMainPost, setPinnedMainPost] = useState<PostInfo | null>(null);
  const needsRepinRef = useRef(false);
  const [pageLoadVersion, setPageLoadVersion] = useState(0);
  const loadPage = useCallback(async (page: number, params: FetchParams, mode: 'initial' | 'jump' = 'initial') => {
    needsRepinRef.current = true;
    await load(page, params, mode);
    setPageLoadVersion((v) => v + 1);
  }, [load]);
  useEffect(() => {
    // pinnedMainPost 仍需 repin 门控（'more' 追加不重钉）；thread 则无条件
    // 跟随 extra——点赞/收藏的 setExtra 翻转（2026-08-28 真机：底栏点赞
    // 「点了没反应」根因=门控把 setExtra 的合法更新挡在门外，thread 永不
    // 同步 → 心形恒旧态 + 服务端恒回「已经点过赞了」）。
    if (needsRepinRef.current && hasPinnedOp && posts.length > 0) {
      // 楼主楼按 floor===1 匹配（倒序时服务端经 pbPage 已并入头部，此处
      // 双保险：列表任何位置都能钉对；list 无楼主楼时退 posts[0]）。
      setPinnedMainPost(posts.find((p) => p.floor === 1) ?? posts[0]);
    }
    needsRepinRef.current = false;
    setThread(extra?.thread ?? null);
  }, [pageLoadVersion, posts, extra, hasPinnedOp]);

  const [seeLz, setSeeLz] = useState<boolean>(seeLzInitial);
  const [reverse, setReverse] = useState<boolean>(reverseInitial);
  // isCollected 初值（中3）：跳转来源已带收藏态（收藏列表进入，fromFavorites='1'）
  const [isCollected, setIsCollected] = useState(openFromFavorites);

  const [confirmState, setConfirmState] = useState<{
    visible: boolean; title: string; message: string; onConfirm: () => void;
  }>({ visible: false, title: '', message: '', onConfirm: () => {} });

  // 主贴卡渲染用引用（高1）：repin effect 尚未消费 flag 的 initial/jump 提交帧
  // 直接取新列表 [0]（防一帧 OP 重复）；'more' 追加/驱逐期间 flag 恒 false，
  // 钉住引用不随 posts 翻转。
  const mainPost = useMemo(() => {
    if (!hasPinnedOp) return null;
    if (needsRepinRef.current) {
      return posts.find((p) => p.floor === 1) ?? (posts.length > 0 ? posts[0] : null);
    }
    return pinnedMainPost;
  }, [hasPinnedOp, posts, pinnedMainPost]);
  // 回复列表 = 剔除主贴后的数组（高1）：楼主楼可能不在 index 0（倒序/并入
  // 首楼后仍在头部，但驱逐/异常位置时 indexOf+1 切片会错切）——恒用
  // 引用剔除（filter），主贴卡引用不随 posts 翻转。
  const replyPosts = useMemo(() => {
    if (!hasPinnedOp || !mainPost) {
      return hideBlockedContent ? filterPosts(posts) : posts;
    }
    const remainder = posts.filter((p) => p !== mainPost);
    return hideBlockedContent ? filterPosts(remainder) : remainder;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [posts, hasPinnedOp, mainPost, hideBlockedContent, blockedWords, blockedUsers]);

  const postListRef = useRef<LegendListRef | null>(null);
  const toastRef = useRef<ToastRef | null>(null);

  // ── 媒体可见性：滚动时向总线报告可视视频/音频 key（离屏暂停用）──
  const viewabilityConfig = useRef({ itemVisiblePercentThreshold: 30 }).current;
  const onViewableItemsChanged = useRef(
    (info: { viewableItems: { item: PostInfo }[] }) => {
      const keys = new Set<string>();
      for (const v of info.viewableItems) {
        if (v.item?.content) {
          for (const k of mediaKeysOf(v.item.content)) keys.add(k);
        }
      }
      useMediaBus.getState().setVisibleKeys(keys);
    },
  ).current;

  // Floating bar auto-hide（shared value 驱动，滚动不触发 re-render，Issue #1）；首屏入场级联
  const { onScroll: scrollHandler, containerStyle: floatingBarStyle } = useFloatingBarAutoHide(reduceMotion);
  const entranceProgress = useSharedValue(0);
  const entryTotalSV = useSharedValue(1);
  const entranceStartedRef = useRef(false);
  // 入场动画开关（设置→个性化→动效）
  const entranceAnimation = useAppPreference('entranceAnimation', true);

  useEffect(() => {
    if (entranceStartedRef.current || loading || posts.length === 0) return;
    entranceStartedRef.current = true;
    const entryWindow = Math.min(Math.max(posts.length, 1), ENTRANCE_ROW_WINDOW);
    entryTotalSV.value = entryWindow;
    entranceProgress.value = reduceMotion || !entranceAnimation
      ? 1
      : withTiming(1, {
          duration: DURATION.enter + DURATION.stagger * Math.max(entryWindow - 1, 0),
          easing: EASE_OUT,
        });
  }, [loading, posts.length, reduceMotion, entranceAnimation, entranceProgress, entryTotalSV]);

  // 双击顶栏回顶（设置-浏览可关）
  const navDoubleTapEnabled = useAppPreference('navBarDoubleTapToTop', true);
  useNavDoubleTapToTop(
    () => postListRef.current?.scrollToOffset({ offset: 0, animated: true }),
    navDoubleTapEnabled ?? true,
  );

  const imageViewer = useImageViewer();

  // ── 主楼遮挡揭示（2026-08-31）：主楼渲染在 ListHeaderComponent（不在
  // LegendList data 内），通用消费者找不到行 → 专属处理：
  // ① 点击主楼图时 arm（post.id + 行几何=ThreadHeader 根，measure 行高）；
  // ② onMiss 时 scrollToOffset 推算滚动量（见 handleHeaderRevealMiss）。
  const threadHeaderRef = useRef<View>(null);
  const handleHeaderImagePress = useCallback(
    (...args: Parameters<typeof imageViewer.handleImagePress>) => {
      const frame = args[2];
      if (frame && mainPost) {
        armSourceReveal(mainPost.id, frame, insets, { bottomCovered: 54 });
        if (threadHeaderRef.current) {
          threadHeaderRef.current.measureInWindow((_x, y, _w, h) => {
            armSourceRevealRow(mainPost.id, y, h);
          });
        }
      }
      imageViewer.handleImagePress(...args);
    },
    [imageViewer, mainPost, insets],
  );
  const handleHeaderRevealMiss = useCallback(
    (target: RevealTarget) => {
      if (!target.rawFrame || !postListRef.current?.scrollToOffset) return;
      const rf = target.rawFrame;
      // 目标线：底部遮挡 → 图底对齐"屏底 − 安全区 − 浮动条(54)"；
      // 顶部遮挡 → 图顶对齐"顶栏下缘"。滚动量 = 帧窗口坐标直接推算
      //（offset 相对列表顶；帧 y 是窗口坐标，含 header 当前位置）。
      const guardTop = insets.top + NAV_BAR_H;
      const guardBottom = SCREEN_H - Math.max(insets.bottom, 16) - 54;
      const targetOffset = target.clipTop
        ? rf.y - guardTop
        : rf.y + rf.height - guardBottom;
      if (targetOffset <= 0) return; // 已可见/无法上滚
      postListRef.current.scrollToOffset({ offset: targetOffset, animated: true });
    },
    [insets],
  );

  // 被遮挡源图揭示（2026-08-31）：帖子正文图/引用图半遮时，打开查看器后
  // 自动滚动楼层列表使该楼层对齐屏缘（主楼走 onMiss → handleHeaderRevealMiss）
  useSourceRevealConsumer(
    postListRef,
    replyPosts,
    (p: unknown) => (p as PostInfo).id,
    handleHeaderRevealMiss,
  );

  // ── 页面动作（useThreadPageActions）：requireLogin + in-flight 守卫 + patchPost/setExtra 注入 ──
  const patchPost = useCallback(
    (postId: string, patch: (post: PostInfo) => Partial<PostInfo>) =>
      setPosts((prev) => prev.map((p) => (p.id === postId ? { ...p, ...patch(p) } : p))),
    [setPosts],
  );
  // 主贴正文快照供收藏图片缓存（渲染期只读 mainPost，快照走 effect）
  const mainPostContentRef = useRef<PostInfo['content'] | undefined>(undefined);
  useEffect(() => {
    mainPostContentRef.current = pinnedMainPost?.content;
  }, [pinnedMainPost?.content]);
  const showConfirm = useCallback((c: ConfirmRequest) => {
    setConfirmState({ visible: true, title: c.title, message: c.message, onConfirm: c.onConfirm });
  }, []);
  const {
    handleToggleCollect,
    handleAgree,
    handleThreadAgree,
    handleDelete,
    handleCopyLink,
    shareAction,
  } = useThreadPageActions({
    id, isLoggedIn, thread, isCollected, setIsCollected,
    patchPost, setExtra, setPosts, mainPostContentRef, showConfirm,
    // 帖级点赞的 post_id：Kotlin AgreeThread 用首楼 id；置顶主贴未加载时
    // 回退列表首项，再回退 threadId（与旧行为一致）。
    firstPostId: pinnedMainPost?.id ?? posts?.[0]?.id ?? id,
  });

  // Initial load + reload when seeLz/reverse changes
  useEffect(() => {
    void loadPage(1, { id, postId, seeLz, reverse });
  }, [seeLz, reverse, id, postId, loadPage]);

  useEffect(() => {
    if (thread?.id && !incognitoMode) {
      recordThreadVisit({
        id,
        type: 'thread' as const,
        title: thread.title ?? '',
        forumName: thread.forumName ?? '',
        authorName: thread.authorName ?? '',
        authorPortrait: thread.authorPortrait ?? undefined,
        timestamp: Date.now(),
      });
    }
  }, [thread?.id, thread?.title, thread?.forumName, thread?.authorName, thread?.authorPortrait, id, incognitoMode]);

  const handleToggleSeeLz = useCallback(() => {
    hapticForScene('toggle');
    setSeeLz((v) => !v);
  }, []);
  const handleToggleSort = useCallback(() => {
    hapticForScene('toggle');
    setReverse((v) => !v);
  }, []);
  const canDelete = accountUid === thread?.authorId;

  // ── Jump-to-page dialog（ThreadJumpDialog：RN Modal；SwiftUI Alert+TextField
  // 在嵌套 matchContents 宿主上 present 失败会白屏，8-25 真机已验证弃用）──
  const [jumpDialogVisible, setJumpDialogVisible] = useState(false);
  const openJumpDialog = useCallback(() => setJumpDialogVisible(true), []);

  // jump 失败补 toast（低9）：run 吞错不 rethrow，无法 try/catch —— 记下目标页，
  // effect 在 threadPageCurrent 更新后回读校验：未达目标页视为失败。
  const [jumpTarget, setJumpTarget] = useState<number | null>(null);
  const handleJumpToPage = useCallback(async (pageNum: number) => {
    setJumpTarget(pageNum);
    await loadPage(pageNum, { id, postId, seeLz, reverse }, 'jump');
  }, [loadPage, id, postId, seeLz, reverse]);
  useEffect(() => {
    if (jumpTarget == null) return;
    if (threadPageCurrent === jumpTarget) {
      postListRef.current?.scrollToOffset({ offset: 0, animated: true });
    } else {
      toastRef.current?.show({ title: '跳转失败', message: '无法跳转到该页，请稍后重试', type: 'error', icon: 'xmark' });
    }
    setJumpTarget(null);
  }, [jumpTarget, threadPageCurrent]);

  // ──「更多」formSheet 页动作回传（thread-more-action）：more.tsx 只发事件，
  // 动作统一在本页执行；复制链接双入口都汇聚到 handleCopyLink 的同一 Toast ──
  useEffect(() => {
    const sub = DeviceEventEmitter.addListener(
      'thread-more-action',
      (e: { action: string; threadId?: string }) => {
        // 延迟等 formSheet 完全收起：iOS 不允许 dismiss 动画中 present 新窗口
        //（Modal/Alert 会被静默拒绝——「跳转页码没弹窗」即此）
        setTimeout(() => {
          switch (e.action) {
            case 'seeLz': handleToggleSeeLz(); break;
            case 'collect': void handleToggleCollect(); break;
            case 'sort': handleToggleSort(); break;
            case 'jump': openJumpDialog(); break;
            case 'share': void shareAction(); break;
            case 'copy': void handleCopyLink(); break;
            case 'delete': handleDelete(); break;
            default: break;
          }
        }, 450);
      },
    );
    return () => sub.remove();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [handleToggleSeeLz, handleToggleCollect, handleToggleSort, openJumpDialog, shareAction, handleCopyLink, handleDelete]);

  // Thread Header (ListHeaderComponent)
  const renderHeader = useMemo(() => {
    if (!thread) return null;

    return (
      <StaggerItem index={0} entrance={entranceProgress} entryTotal={entryTotalSV}>
        <View ref={threadHeaderRef} collapsable={false}>
          <ThreadHeader
            thread={thread}
            mainPost={mainPost}
            seeLz={seeLz}
            reverse={reverse}
            colors={colors}
            pageLabel={totalPages > 0 ? `${threadPageCurrent}/${totalPages}页` : undefined}
            onToggleSeeLz={handleToggleSeeLz}
            onToggleSort={handleToggleSort}
            onImagePress={handleHeaderImagePress}
          />
        </View>
      </StaggerItem>
    );
  }, [thread, mainPost, seeLz, reverse, colors, totalPages, threadPageCurrent, handleToggleSeeLz, handleToggleSort, handleHeaderImagePress, entranceProgress, entryTotalSV]);

  // Render individual post / reply（动作在 more.tsx formSheet 发起，经
  // thread-more-action 回本页执行）
  const threadAuthorId = thread?.authorId;
  const handleSubPostsPress = useCallback((post: PostInfo) => {
    // 楼中楼页要展示"上一级回复"原文：跳转前快照进模块级缓存（富文本不适合走 URL）
    cacheParentPost(post);
    router.push(
      `/thread/${id}/subposts?postId=${post.id}&threadId=${id}&forumId=${thread?.forumId || ''}&floor=${post.floor}&threadAuthorId=${thread?.authorId || ''}&forumName=${encodeURIComponent(thread?.forumName || '')}&threadTitle=${encodeURIComponent(thread?.title || '')}`,
    );
  }, [id, thread?.forumId, thread?.authorId, thread?.forumName, thread?.title]);

  const renderPost = useCallback(({ item, index }: { item: PostInfo; index: number }) => {
    const isReplyLz = item.authorIsLz || (!!threadAuthorId && item.authorId === threadAuthorId);

    const card = (
      <PostCard
        post={item}
        forumName={thread?.forumName}
        isLz={isReplyLz}
        subPosts={item.subPosts}
        onAgree={handleAgree}
        onDelete={accountUid === item.authorId ? handleDelete : undefined}
        onSubPostsPress={handleSubPostsPress}
        onImagePress={imageViewer.handleImagePress}
      />
    );

    return (
      <StaggerItem index={index} entrance={entranceProgress} entryTotal={entryTotalSV}>
        {card}
      </StaggerItem>
    );
  }, [handleAgree, handleDelete, imageViewer.handleImagePress, handleSubPostsPress, accountUid, threadAuthorId, thread?.forumName, entranceProgress, entryTotalSV]);

  const renderFooter = useMemo(() => (
    <LoadMoreFooter
      hasMore={hasMore} loading={loadingMore}
      colors={colors} onLoadMore={handleLoadMore}
    />
  ), [hasMore, loadingMore, colors, handleLoadMore]);

  // Render states
  if (loading && posts.length === 0) {
    return (
      <View style={flattenStyle([styles.container, { backgroundColor: colors.background }])}>
        <Stack.Screen options={{ title: knownSnapshot?.title || thread?.title || '帖子' }} />
        <View style={styles.loadingSkeleton}>
          {knownSnapshot ? <KnownPostHeader thread={knownSnapshot} colors={colors} /> : null}
          <SkeletonList count={5} variant="post" />
        </View>
      </View>
    );
  }

  if (error && posts.length === 0) {
    return (
      <View style={flattenStyle([styles.container, { backgroundColor: colors.background }])}>
        <Stack.Screen options={{ title: '帖子' }} />
        <ErrorState message={error} onRetry={handleRefresh} />
      </View>
    );
  }

  // 完整标题交给原生 Stack header 省略号处理（避免双重缩略）
  const threadTitle = thread?.title || '帖子';

  return (
    <View style={flattenStyle([styles.container, { backgroundColor: colors.background }])}>
      <Stack.Screen
        options={{
          title: threadTitle,
          headerRight: () => (
            <ForumAvatarWithHdr
              forumName={thread?.forumName}
              forumAvatar={thread?.forumAvatar}
            />
          ),
        }}
      />

      <LegendList
        recycleItems
        ref={postListRef}
        data={replyPosts}
        keyExtractor={replyKeyExtractor}
        renderItem={renderPost}
        ListHeaderComponent={renderHeader}
        ListEmptyComponent={
          <EmptyState title="暂无回复" description="还没有人回复这个帖子" icon="bubble.left" />
        }
        contentContainerStyle={[
          styles.listContent,
          // headerTransparent 后内容从 y=0 起：顶部让位导航栏，底部让位浮动胶囊
          //（showShortcutInThread 关闭时压缩到底部默认留白，低9）
          { paddingTop: insets.top + 66, paddingBottom: insets.bottom + (showShortcutInThread ? 80 : 12) },
        ]}
        onEndReached={handleLoadMore}
        onEndReachedThreshold={0.3}
        ListFooterComponent={renderFooter}
        refreshControl={
          <RefreshControl
            refreshing={refreshing}
            onRefresh={() => { void handleRefresh().then(() => hapticForScene('toggle')); }}
            tintColor={colors.primary}
          />
        }
        ItemSeparatorComponent={PostSeparator}
        drawDistance={300}
        viewabilityConfig={viewabilityConfig}
        onViewableItemsChanged={onViewableItemsChanged}
        decelerationRate="normal"
        onScroll={scrollHandler}
        scrollEventThrottle={48}
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}
      />

      {/* Floating Glass Bottom Bar（居中 72% 宽度胶囊，滚动自动隐藏） */}
      {showShortcutInThread && (
        <ThreadFloatingBar
          thread={thread}
          isCollected={isCollected}
          bottom={insets.bottom + 2}
          containerStyle={floatingBarStyle}
          onCopyLink={() => { void handleCopyLink(); }}
          onAgree={() => { void handleThreadAgree(); }}
          onCollect={() => { void handleToggleCollect(); }}
          onMore={() => {
            hapticForScene('sheet-present');
            router.push({
              pathname: '/thread/[id]/more',
              params: {
                id,
                title: thread?.title ?? '',
                forumId: thread?.forumId ?? '',
                forumName: thread?.forumName ?? '',
                canDelete: canDelete ? '1' : '0',
                seeLz: seeLz ? '1' : '0',
                isCollected: isCollected ? '1' : '0',
                reverse: reverse ? '1' : '0',
              },
            });
          }}
        />
      )}

      <ThreadJumpDialog
        visible={jumpDialogVisible}
        currentPage={threadPageCurrent}
        totalPages={totalPages}
        onClose={() => setJumpDialogVisible(false)}
        onJump={handleJumpToPage}
      />

      {/* Confirmation dialog (delete) */}
      <ThemedHost matchContents style={{ position: 'absolute', width: 0, height: 0 }}>
        <ConfirmationDialog
          title={confirmState.title}
          isPresented={confirmState.visible}
          onIsPresentedChange={(v) => setConfirmState((s) => ({ ...s, visible: v }))}
          titleVisibility="visible"
        >
          <ConfirmationDialog.Actions>
            <SWButton label="确定" role="destructive" onPress={() => { confirmState.onConfirm(); setConfirmState((s) => ({ ...s, visible: false })); }} />
            <SWButton label="取消" role="cancel" />
          </ConfirmationDialog.Actions>
          <ConfirmationDialog.Message><SWText>{confirmState.message}</SWText></ConfirmationDialog.Message>
        </ConfirmationDialog>
      </ThemedHost>

      <ImageViewer
        images={imageViewer.imageViewerImages}
        initialIndex={imageViewer.imageViewerIndex}
        visible={imageViewer.imageViewerVisible}
        onClose={imageViewer.closeImageViewer}
        forumName={thread?.forumName}
        sourceFrame={imageViewer.imageViewerSourceFrame}
        imageOrigins={imageViewer.imageViewerOrigins}
        contextTitle={imageViewer.imageViewerContextTitle}
        imageMeta={imageViewer.imageViewerMeta}
        imagePreviews={imageViewer.imageViewerPreviews}
      />

      <Toast ref={toastRef} />
    </View>
  );
}

// Styles

// ── 已知主贴区（initialKnown 快照占位，2026-08-30）──
// 列表→详情携带已知数据（标题/作者/摘要/首图）的首帧渲染：帖子首包返回前
// 不再整页空白/纯骨架；服务端详情返回后由完整 PostCard 整体替换。
const KNOWN_PAGE_W = Dimensions.get('window').width - 32;

function KnownPostHeader({ thread, colors }: { thread: ThreadInfo; colors: any }) {
  const insets = useSafeAreaInsets();
  const firstImage = (thread.mediaList ?? []).find((m) => m.type === 'image');
  let imgHeight = 0;
  if (firstImage && firstImage.width > 0 && firstImage.height > 0) {
    imgHeight = Math.min(Math.max((KNOWN_PAGE_W * firstImage.height) / firstImage.width, 1), 320);
  }
  return (
    <View style={{ paddingTop: insets.top + 66 }}>
      <View style={[styles.knownCard, { backgroundColor: colors.card }]}>
        <Text style={[styles.knownTitle, { color: colors.text }]} numberOfLines={3}>
          {thread.title}
        </Text>
        <View style={styles.knownAuthorRow}>
          <Avatar
            source={thread.authorPortrait || undefined}
            initials={(thread.authorName || '吧').charAt(0)}
            size={36}
          />
          <Text style={[styles.knownAuthorName, { color: colors.textSecondary }]} numberOfLines={1}>
            {thread.authorName}
          </Text>
        </View>
        {thread.abstract ? (
          <Text style={[styles.knownAbstract, { color: colors.textSecondary }]} numberOfLines={2}>
            {thread.abstract}
          </Text>
        ) : null}
        {firstImage && imgHeight > 0 ? (
          <Image
            source={{ uri: firstImage.smallSrc || firstImage.src }}
            style={[styles.knownImage, { height: imgHeight }]}
            contentFit="cover"
            cachePolicy="memory-disk"
            transition={120}
          />
        ) : null}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  listContent: { paddingHorizontal: 0, paddingTop: 8 },
  loadingSkeleton: {
    flex: 1,
    paddingTop: 12,
  },
  knownCard: {
    marginHorizontal: 16,
    padding: 16,
    gap: 12,
    ...RadiusStyle.card,
  },
  knownTitle: {
    fontSize: 17,
    lineHeight: 22,
    fontWeight: '500',
  },
  knownAuthorRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  knownAuthorName: {
    flex: 1,
    fontSize: 13,
    fontWeight: '500',
  },
  knownAbstract: {
    fontSize: 14,
    lineHeight: 20,
  },
  knownImage: {
    width: '100%',
    borderRadius: 10,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(128,128,128,0.15)',
  },
  postSep: { height: 1 },
});