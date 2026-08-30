/**
 * TweetCard — 推特（X）风格信息流卡片
 *
 * 设计规格（对齐参考图 Twitter timeline，iOS 设计语言）：
 * - 圆角卡片包裹（colors.card + 16pt 圆角 + hairline 描边 + 微阴影），无分割线
 * - 头部：44pt 圆头像（左）→ 一行 显示名(15/600) + @用户名(15 次要) + · 时间(15 次要)
 * - 正文：标题(17/700) + 摘要(15/400) 合并 Text 块，内容列与名字列对齐（缩进 54pt）
 * - 长文：超过 6 行截断 + 底部渐隐 + 「显示更多」按钮原位展开
 * - 媒体：MediaPager（@/components/feed/MediaPager，TweetCard/PostContent 共用）；
 *   单图按宽高比（钳制）；多图为 X 式横向平滑图片带；视频帖显示 poster + 播放角标
 * - 转发帖：originThreadInfo 渲染为推特「引用帖」嵌套小卡
 * - 操作栏（仅 3 个）：回复 → 分享 → 点赞（heart/heart.fill 红色 + 弹簧 pop）
 * - 交互：点击卡片空白/文字区域进帖；头像→用户页、吧名→吧页、按钮各自独立
 *
 * 性能：
 * - React.memo + 父级 useCallback 稳定回调
 * - expo-image recyclingKey + 200px 服务端缩略图（点击再看原图）
 * - 多图带角标：普通 onScroll + 整数序号变化才 setState
 * - thread.id 变化时重置展开状态与分页偏移（行组件复用/recycleKey 安全）
 */

import React, { useCallback, useEffect, useRef } from 'react';
import {
  View,
  Text,
  Pressable,
  StyleSheet,
  Alert,
  useWindowDimensions,
  type GestureResponderEvent,
} from 'react-native';
import { Avatar } from '@/components/ui/Avatar';
import Animated, {
  useSharedValue,
  useAnimatedStyle,
  withSpring,
  withSequence,
} from 'react-native-reanimated';
import { useRouter } from 'expo-router';
import { SymbolView } from '@/components/ui/SymbolView';
import { setThreadSnapshot } from '@/utils/threadSnapshot';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { hapticForScene } from '@/theme/hapticsMap';
import { rtBeginLikeCharge, rtEndLikeCharge } from '@/theme/hapticsRealtime';
import { useThemeColors } from '@/theme/ThemeContext';
import { MOMENTUM } from '@/theme/springs';
import {RadiusStyle, Radius} from '@/theme/spacing';
import { typographyStyles } from '@/theme/typography';
import { useReducedMotion } from '@/hooks/useReducedMotion';
import { useAppPreference } from '@/hooks/useAppPreference';
import { formatCount } from '@/utils';
import { useTimeLabel } from '@/hooks/useTimeLabel';
import { pickViewerImages, pickViewerPreviews } from '@/utils/thumbnail';
import { useRecyclingState } from '@legendapp/list/react-native';
import { stopPropagation } from '@/utils/gesture';
import type { ThreadInfo } from '@/types';
import { MediaPager } from '@/components/feed/MediaPager';
import type { ImagePressHandler } from '@/components/thread/PostImages';
import type { ViewerImageMeta, ImageSourceFrame } from '@/hooks/useImageViewer';

// ── 设计常量（推特 timeline 规格） ──
const AVATAR_SIZE = 44;
const AVATAR_GAP = 10;
/** 内容列缩进：与名字列对齐（推特 timeline 布局） */
const CONTENT_INDENT = AVATAR_SIZE + AVATAR_GAP;
/** 卡片圆角：统一 Radius.card（与 PostCard 卡片容器一致） */
const CARD_RADIUS = Radius.card;
/** 卡片外左右边距（styles.cardWrap.marginHorizontal 的单一来源） */
const CARD_WRAP_MARGIN = 10;
/** 卡片内左右 padding（styles.card.paddingHorizontal 的单一来源) */
const CARD_PADDING_X = 12;
/** 长文截断行数（推特 Show more 阈值） */
const COLLAPSE_LINES = 6;
/** 置顶帖横幅纯文字截断字数（贴吧官方横幅"xx 字后截断"） */
const TOP_TITLE_MAX = 28;
/** 吧名徽章方形头像边长（Kotlin chip 内 avatar 与文字等高，约 20pt） */
const FORUM_CHIP_AVATAR = 20;
/**
 * 长文启发式阈值：CJK 字符记 1、半角记 0.5 的加权长度。内容列约 19 字/行
 * × 6 行 ≈ 114，取 120 留少量余量。用字符预判替代 onTextLayout 实测：
 * 后者让每个长文帖在飞速滑动挂载时必然二次 commit（测量→setState→重渲）。
 * 阈值按阅读字号反比缩放（大字号每行容字更少，更早判定为可截断）。
 */
const LONG_TEXT_WEIGHTED_CHARS = 120;

function weightedTextLength(...parts: (string | undefined)[]): number {
  let n = 0;
  for (const part of parts) {
    if (!part) continue;
    for (const ch of part) n += ch.charCodeAt(0) > 0xff ? 1 : 0.5;
  }
  return n;
}

/** 置顶帖横幅文案按字数截断（超出加省略号） */
function truncateText(text: string, max: number): string {
  if (!text) return '';
  return text.length <= max ? text : `${text.slice(0, max)}…`;
}

export type TweetCardMenuAction = 'dislike' | 'block' | 'copy-title' | 'report';

export interface TweetCardProps {
  thread: ThreadInfo;
  /** 头部时间字段：create = 发帖时间（按发帖时间排序/动态流）；last = 最后回复时间（按回复时间排序） */
  timeType?: 'create' | 'last';
  /**
   * 内容列末尾显示吧名徽章（Kotlin ThreadForumInfo 同位同款：方形吧头像 +
   * "xx吧"文字 chip，位于卡片左下、操作栏之上），点击进对应吧。
   * 吧内列表同吧冗余默认关；跨吧信息流（动态/搜索）开。
   */
  showForumPill?: boolean;
  /** 右上角 × 的菜单项（默认 屏蔽作者/举报；动态流传扩展项保留 不感兴趣/复制标题） */
  closeMenuOptions?: ('dislike' | 'block' | 'copy-title' | 'report')[];
  /** 隐藏底部操作栏（回复/分享/点赞）——收藏列表等非社交场景（2026-08-28） */
  hideActions?: boolean;
  /** 覆盖整卡点击（默认进 /thread/id；收藏页需带 fromFavorites 参数） */
  onOpenThread?: () => void;
  /** 图片长按菜单（X 同款：压暗 + 大图预览 + 保存/复制/分享）。默认关闭 */
  imageContextMenu?: boolean;
  /** 大图查看器回调：images/origins/meta 与下标一一对应。
      签名统一采用 thread/PostImages.ImagePressHandler（全链路唯一声明处），
      与帖内 ImageSegment 完全同构 —— 列表/帖内进查看器行为一致。 */
  onImagePress?: ImagePressHandler;
  onLike?: (thread: ThreadInfo) => void;
  onShare?: (thread: ThreadInfo) => void;
  /** 提供时显示右上角「×」菜单，回传所属帖子 */
  onMenuAction?: (action: TweetCardMenuAction, thread: ThreadInfo) => void;
}

const TweetCard = React.memo(function TweetCard({
  thread,
  timeType = 'create',
  showForumPill = false,
  closeMenuOptions,
  hideActions = false,
  imageContextMenu = false,
  onImagePress,
  onLike,
  onShare,
  onMenuAction,
  onOpenThread,
}: TweetCardProps) {
  const { colors } = useThemeColors();
  const router = useRouter();
  const { width: screenWidth } = useWindowDimensions();
  const hideMedia = useAppPreference('hideMedia');
  // useAppPreference 的 defaultValue 已兜底（store 缺省时返回默认值），
  // 返回值必非 undefined —— TS 无法从签名收窄，这里显式断言（见全量审查 #12）。
  const dataSaverMode = useAppPreference('dataSaverMode', 'high')!;
  // 时间显示格式（相对/绝对，设置→使用习惯→贴子）
  const timeLabel = useTimeLabel();
  // 「显示两个用户名」（设置→习惯）：关闭时只显示昵称、不显示 @原始名。
  // 此前 TweetCard 未消费该偏好（PostCard.tsx:283 同语义已接入）——修复
  // 2026-08-28 用户反馈"关了这个设置没起作用"。
  const showBothUsername = useAppPreference('showBothUsername', false) ?? false;

  // 卡片内容宽度：屏宽 - 卡片外左右边距（CARD_WRAP_MARGIN*2，真实布局
  // marginHorizontal:10，此前误用 16 魔法数） - 卡片内左右 padding
  // （CARD_PADDING_X*2，即 styles.card.paddingHorizontal:12），全部由常量
  // 单一来源推导（见全量审查 #8；对照 explore contentContainerStyle
  // paddingVertical 8 —— 竖向由列表外边距承担，横向两侧各 10pt）。
  const contentWidth = screenWidth - CARD_WRAP_MARGIN * 2 - CARD_PADDING_X * 2;
  // 内容列宽 W_c（媒体区单图可占最大宽度）：内容列位于卡片内（marginLeft =
  // CONTENT_INDENT 54pt）→ 宽度再减去缩进，否则媒体右边界 = 缩进 + 整卡内容宽
  // > 屏宽，右侧（含圆角）被溢出裁掉。
  const mediaWidth = Math.max(0, contentWidth - CONTENT_INDENT);
  // 多图图片带（X 式）：可视视口横跨整卡宽（含左右 padding），左缘贴卡片边框，
  // 滑动时图片带可越入头像列空白区、以卡片边缘为界裁切；视口宽 = 卡片盒宽。
  const stripViewportWidth = contentWidth + CARD_PADDING_X * 2;
  // 图片带初始左缘对齐内容列左界 L0 的位移 = 卡片 padding + CONTENT_INDENT
  const stripLeadInset = CARD_PADDING_X + CONTENT_INDENT;

  // ── 导航 ──
  // 吧名徽章按压窗口守卫：Fabric 嵌套 Pressable 下外层整卡偶发同时触发
  // onPress（capture 声明只解决响应者抢占，release 仍可能双发）——徽章
  // 按下瞬间记录时间戳，整卡 onPress 在窗口内直接短路，确保点吧名只进吧
  //（2026-08-27 真机复现"点吧名进帖子"）。
  const chipPressBlockUntilRef = useRef(0);
  const handleCardPress = useCallback(() => {
    if (Date.now() < chipPressBlockUntilRef.current) return;
    if (__DEV__) console.warn(`[card] card-press id=${thread.id}`);
    hapticForScene('press');
    // 已知数据快照：帖子页首帧用列表数据占位（标题/作者/摘要/首图），
    // 不等帖子首包——iOS 系统应用同款（2026-08-30）
    setThreadSnapshot(thread);
    if (onOpenThread) {
      onOpenThread();
      return;
    }
    router.push(`/thread/${thread.id}`);
  }, [router, thread.id, onOpenThread]);

  const handleAvatarPress = useCallback((e: GestureResponderEvent) => {
    e.stopPropagation?.();
    if (!thread.authorId) return;
    hapticForScene('press');
    router.push(`/user/${thread.authorId}`);
  }, [router, thread.authorId]);

  // ── 长文展开：useRecyclingState 在行被复用到另一条贴子时按初始值重置，
  // 不再有"上一条的展开态带到新贴子"的复用串扰（也不需要手动按 id 重置的
  // effect——那个方案在复用首帧会短暂渲染上一条的展开态）。
  const [expanded, setExpanded] = useRecyclingState(false);

  // 长文判定：字符加权预判（见 LONG_TEXT_WEIGHTED_CHARS 注释），渲染期纯计算、
  // 无 setState 二次 commit。字号越大每行容字越少，阈值按 fontScale 反比缩放。
  const fontScale = useAppPreference('fontScale', 1.0) ?? 1;
  const truncatable =
    weightedTextLength(thread.title, thread.abstract) >
    LONG_TEXT_WEIGHTED_CHARS / Math.max(fontScale, 0.1);

  const handleShowMore = useCallback((e: GestureResponderEvent) => {
    e.stopPropagation?.();
    hapticForScene('toggle');
    setExpanded(true);
  }, []);

  // ── 媒体 ──
  const mediaList = thread.mediaList ?? [];
  const images = mediaList.filter((m) => m.type === 'image' && (m.src || m.originSrc));
  const videoPoster = mediaList.find((m) => m.type === 'video')?.poster;
  const showMedia = !hideMedia && (images.length > 0 || !!videoPoster);

  const handleImagePress = useCallback(
    (index: number, sourceFrame?: ImageSourceFrame | null) => {
      if (!onImagePress || images.length === 0) {
        handleCardPress();
        return;
      }
      if (__DEV__) console.warn(`[card] img-press id=${thread.id} idx=${index} n=${images.length}`);
      hapticForScene('press');
      // origins = 每张图的原图 URL（大图查看器「保存原图」）；contextTitle = 帖子标题
      // meta = 逐图长图/查看原图标记 + 真实宽高：查看器据此对长图默认显示原图档
      // （isLongPic/高度判据）、决定是否出现「查看原图」菜单项——与帖内 ImageSegment
      // 传参同构。此前列表侧缺 meta，查看器 isLongImageOf 恒 false，长图只显 bigPic 档。
      // sourceFrame = 被点击缩略图的屏幕矩形（MediaPager 从按压事件换算）：
      // 查看器退场时"飞回原位"——以往信息流图无源矩形只能飞出屏。
      const viewerMeta: (ViewerImageMeta | undefined)[] = images.map((m) => ({
        isLongPic: m.isLongPic,
        showOriginalBtn: m.showOriginalBtn,
        width: m.width,
        height: m.height,
      }));
      onImagePress(
        pickViewerImages(images, dataSaverMode),
        index,
        sourceFrame ?? undefined,
        images.map((m) => m.originSrc || m.src),
        thread.title,
        viewerMeta,
        pickViewerPreviews(images),
      );
    },
    [onImagePress, images, handleCardPress, dataSaverMode, thread.title],
  );

  // ── 吧名徽章（Kotlin ThreadForumInfo 复刻）──
  const handleForumPressIn = useCallback((e: GestureResponderEvent) => {
    stopPropagation(e);
    chipPressBlockUntilRef.current = Date.now() + 350;
  }, []);
  const handleForumPress = useCallback((e: GestureResponderEvent) => {
    e.stopPropagation?.();
    chipPressBlockUntilRef.current = Date.now() + 350;
    if (!thread.forumName) return;
    if (__DEV__) console.warn(`[card] forum-press id=${thread.id} name=${thread.forumName}`);
    hapticForScene('press');
    router.push(`/forum/${encodeURIComponent(thread.forumName)}`);
  }, [router, thread.forumName]);

  // ── 操作栏 ──
  const handleLikePress = useCallback((e: GestureResponderEvent) => {
    e.stopPropagation?.();
    hapticForScene('like');
    onLike?.(thread);
  }, [onLike, thread]);

  const handleSharePress = useCallback((e: GestureResponderEvent) => {
    e.stopPropagation?.();
    onShare?.(thread);
  }, [onShare, thread]);

  const handleReplyPress = useCallback((e: GestureResponderEvent) => {
    e.stopPropagation?.();
    hapticForScene('press');
    router.push(`/thread/${thread.id}`);
  }, [router, thread.id]);

  // ── 右上角小 ×：按 closeMenuOptions 组装（默认 屏蔽/举报）──
  const handleClosePress = useCallback((e: GestureResponderEvent) => {
  void hapticForScene('press');
    e.stopPropagation?.();
    hapticForScene('press');
    const options = closeMenuOptions ?? ['block', 'report'];
    const items: { title: string; action: TweetCardMenuAction }[] = [];
    if (options.includes('dislike')) items.push({ title: '不感兴趣', action: 'dislike' });
    if (options.includes('block')) items.push({ title: '屏蔽作者', action: 'block' });
    if (options.includes('report')) items.push({ title: '举报', action: 'report' });
    if (options.includes('copy-title')) items.push({ title: '复制标题', action: 'copy-title' });
    Alert.alert(thread.title || '帖子', undefined, [
      ...items.map((it) => ({ text: it.title, onPress: () => onMenuAction?.(it.action, thread) })),
      { text: '取消', style: 'cancel' as const },
    ]);
  }, [thread, onMenuAction, closeMenuOptions]);

  // ── 头部文案 ──
  const displayName = thread.authorNameShow || thread.authorName || '吧友';
  const rawName = thread.authorName || '';
  const showHandle = showBothUsername && !!rawName && rawName !== displayName;
  const timeValue = timeType === 'last' ? thread.lastTime : thread.createTime;
  // 时间随排序语义：按回复时间排序 →「回复于 xx」；按发帖时间 →「发帖于 xx」
  const timeText = timeValue
    ? `${timeType === 'last' ? '回复于' : '发帖于'} ${timeLabel(timeValue)}`
    : '';

  const cardBorderColor = colors.borderCard;

  // ── 置顶帖：一律不显示完整卡片，改横幅（喇叭 + 置顶标 + 截断纯文字）──
  if (thread.isTop) {
    return <TopBanner thread={thread} onPress={handleCardPress} />;
  }

  return (
    <View style={styles.cardWrap}>
      <HdrPressable
        onPress={handleCardPress}
        style={[styles.card, { backgroundColor: colors.card, borderColor: cardBorderColor }]}
        flashRadius={CARD_RADIUS}
        effect="subtle"
        accessibilityRole="button"
        accessibilityLabel={thread.title || '帖子'}
      >
        <View style={styles.headerRow}>
          <HdrPressable onPress={handleAvatarPress} onPressIn={stopPropagation} onPressOut={stopPropagation} hitSlop={4} flashRadius={14} glowOutset={6}>
            <Avatar
              source={thread.authorPortrait || undefined}
              initials={displayName.charAt(0)}
              size={AVATAR_SIZE}
            />
          </HdrPressable>
          <View style={styles.nameCol}>
            <View style={styles.nameRow}>
              <Text style={[styles.displayName, { color: colors.text }]} numberOfLines={1}>
                {displayName}
              </Text>
              {showHandle && (
                <Text style={[styles.handle, { color: colors.textSecondary }]} numberOfLines={1}>
                  @{rawName}
                </Text>
              )}
              {timeText ? (
                <Text style={[styles.time, { color: colors.textSecondary }]} numberOfLines={1}>
                  {timeText}
                </Text>
              ) : null}
            </View>
          </View>
          {onMenuAction ? (
            /* 右上角小 ×（屏蔽/举报，按 closeMenuOptions 扩展） */
            <HdrPressable
              onPress={handleClosePress}
              onPressIn={stopPropagation}
              onPressOut={stopPropagation}
              style={styles.closeButton}
              flashRadius={8}
              glowOutset={5}
              hitSlop={8}
              accessibilityRole="button"
              accessibilityLabel="屏蔽或举报"
            >
              <SymbolView name="xmark" size={13} weight="bold" tintColor={colors.textTertiary} />
            </HdrPressable>
          ) : null}
        </View>

        {/* ── 内容列（与名字列对齐） ── */}
        <View style={styles.contentCol}>
          {/* 正文：标题(粗体) + 摘要 同一块，超行截断 + 显示更多（无背景） */}
          {thread.title || thread.abstract ? (
            <View>
              {thread.title ? (
                <Text
                  style={[styles.bodyTitle, { color: colors.text }]}
                  numberOfLines={truncatable && !expanded ? 2 : undefined}
                >
                  {thread.isTop && <Text style={{ color: colors.error }}>置顶 </Text>}
                  {thread.isGood && <Text style={{ color: colors.warning }}>精品 </Text>}
                  {thread.title}
                </Text>
              ) : null}
              {thread.abstract ? (
                <Text
                  style={[styles.abstract, { color: colors.textSecondary }]}
                  numberOfLines={truncatable && !expanded ? COLLAPSE_LINES - 2 : undefined}
                >
                  {thread.abstract}
                </Text>
              ) : null}
              {truncatable && !expanded ? (
                <HdrPressable
                  onPress={(e) => {
                    void hapticForScene('press');
                    handleShowMore(e);
                  }}
                  onPressIn={stopPropagation}
                  onPressOut={stopPropagation}
                  hitSlop={6}
                  // effect="subtle"：去扫光/白闪/光晕（2026-08-28 用户反馈
                  // 信息流「显示更多」点击有扫过高光特效，与吧页分类菜单项
                  // 同款先例）；纯文字展开行无按压视觉即可。
                  effect="subtle"
                  style={styles.showMoreBtn}
                  flashRadius={8}
                  glowOutset={5}
                >
                  <Text style={[styles.showMore, { color: colors.primary }]}>显示更多</Text>
                </HdrPressable>
              ) : null}
            </View>
          ) : null}

          {/* 媒体区：单图按宽高比 / 多图分页滑动 / 视频 poster + 播放角标 */}
          {showMedia ? (
            <MediaPager
              images={images.map((m) => ({ src: m.src, originSrc: m.originSrc || m.src, smallSrc: m.smallSrc, width: m.width, height: m.height, isGif: m.isGif }))}
              videoPoster={images.length === 0 ? videoPoster : undefined}
              width={mediaWidth}
              viewportWidth={stripViewportWidth}
              leadInset={stripLeadInset}
              recycleKey={thread.id}
              contextMenu={imageContextMenu}
              forumName={thread.forumName}
              onImagePress={handleImagePress}
              onFallbackPress={handleCardPress}
            />
          ) : null}

          {/* 转发帖：引用帖嵌套小卡（推特 quote tweet 样式） */}
          {thread.isShareThread && thread.originThreadInfo ? (
            <View style={[styles.quoteCard, { borderColor: colors.separator }]}>
              {thread.originThreadInfo.forumName ? (
                <Text style={[styles.quoteForum, { color: colors.textSecondary }]} numberOfLines={1}>
                  {thread.originThreadInfo.forumName}吧
                </Text>
              ) : null}
              {thread.originThreadInfo.title ? (
                <Text style={[styles.quoteTitle, { color: colors.text }]} numberOfLines={1}>
                  {thread.originThreadInfo.title}
                </Text>
              ) : null}
              {thread.originThreadInfo.content ? (
                <Text style={[styles.quoteContent, { color: colors.textSecondary }]} numberOfLines={2}>
                  {thread.originThreadInfo.content}
                </Text>
              ) : null}
            </View>
          ) : null}

          {/* 吧名徽章（Kotlin ThreadForumInfo 同位：内容列末尾=卡片左下、
              操作栏之上）。2026-08-27：曾移出整卡做绝对定位兄弟层（当时
              capture 无效疑云），实测绝对定位与长文本/图片重叠；且原
              "点不动"根因其实是头像缺失导致点击落在整卡空白区——头像
              数据修复后文档流内嵌 + capture 即可正常点击。 */}
          {showForumPill && thread.forumName ? (
            <ForumChip
              forumName={thread.forumName}
              forumAvatar={thread.forumAvatar}
              onPress={handleForumPress}
              onPressIn={handleForumPressIn}
            />
          ) : null}

          {/* 操作栏：回复 → 分享 → 点赞（收藏列表 hideActions 隐藏，视觉对齐吧页同时不暴露无意义动作） */}
          {!hideActions && (
          <View style={styles.actionRow}>
            <HdrPressable
              onPress={handleReplyPress}
              onPressIn={stopPropagation}
              onPressOut={stopPropagation}
              style={({ pressed }) => [styles.actionBtn, pressed && styles.actionBtnPressed]}
              hitSlop={6}
              accessibilityRole="button"
              accessibilityLabel="回复"
            >
              <SymbolView name="bubble.left" size={17} tintColor={colors.textTertiary} />
              <Text style={[styles.actionText, { color: colors.textTertiary }]}>
                {formatCount(thread.replyNum)}
              </Text>
            </HdrPressable>
            <HdrPressable
              onPress={handleSharePress}
              onPressIn={stopPropagation}
              onPressOut={stopPropagation}
              style={({ pressed }) => [styles.actionBtn, pressed && styles.actionBtnPressed]}
              hitSlop={6}
              accessibilityRole="button"
              accessibilityLabel="分享"
            >
              <SymbolView name="square.and.arrow.up" size={17} tintColor={colors.textTertiary} />
              <Text style={[styles.actionText, { color: colors.textTertiary }]}>
                {thread.shareNum && thread.shareNum > 0 ? formatCount(thread.shareNum) : '分享'}
              </Text>
            </HdrPressable>
            <LikeButton
              liked={!!thread.hasAgree}
              count={thread.zanNum ?? 0}
              onPress={handleLikePress}
            />
          </View>
          )}
        </View>
      </HdrPressable>
    </View>
  );
});

// ────────────────────────────────────────────────────────────
// ForumChip — 吧名徽章（复刻 Kotlin FeedCard.ThreadForumInfo/ForumInfoChip）
//   chip 底色 + 4dp 圆角、方形吧头像（与文字等高）+ "xx吧" 文字；
//   位于卡片内容列末尾 = 左下角、操作栏之上；点击进对应吧。
// ────────────────────────────────────────────────────────────

const ForumChip = React.memo(function ForumChip({
  forumName,
  forumAvatar,
  onPress,
  onPressIn,
}: {
  forumName: string;
  forumAvatar?: string;
  onPress: (e: GestureResponderEvent) => void;
  onPressIn?: (e: GestureResponderEvent) => void;
}) {
  const { colors } = useThemeColors();
  return (
    <HdrPressable
      onPress={onPress}
      // Fabric 下嵌套 Pressable 偶发被外层整卡抢先声明为响应者（徽章 onPress
      // 被吞、只剩进帖）；capture 阶段先于外层 bubble 声明，强制内层接管。
      onStartShouldSetResponderCapture={() => true}
      onPressIn={onPressIn ?? stopPropagation}
      onPressOut={stopPropagation}
      style={[
        styles.forumChip,
        { backgroundColor: colors.chip },
      ]}
      hitSlop={12}
      accessibilityRole="button"
      accessibilityLabel={`进入${forumName}吧`}
    >
      {/* 吧头像：有图显示圆形图，无图回落首字色块（与首页「最近访问」同款
          Avatar 方案——动态流服务端不下发 forumAvatar，纯 Image 会整格空白） */}
      <Avatar
        source={forumAvatar}
        initials={forumName.replace(/吧$/, '').charAt(0)}
        size={FORUM_CHIP_AVATAR}
      />
      <Text style={[styles.forumChipText, { color: colors.onChip }]} numberOfLines={1}>
        {forumName}吧
      </Text>
    </HdrPressable>
  );
});

// ────────────────────────────────────────────────────────────
// TopBanner — 置顶帖横幅（对齐贴吧官方：喇叭 + 置顶标 + 截断文字）
//   不显示头像/图片/操作栏，纯横幅，点击进帖。
// ────────────────────────────────────────────────────────────
const TopBanner = React.memo(function TopBanner({
  thread,
  onPress,
}: {
  thread: ThreadInfo;
  onPress: () => void;
}) {
  const { colors } = useThemeColors();
  const text = truncateText(thread.title || '置顶帖子', TOP_TITLE_MAX);
  return (
    <Pressable
      onPress={onPress}
      style={[
        styles.topBanner,
        // 无背景（2026-08-26 用户要求"删掉背景"）：深色模式下带底色的
        // surfaceSecondary 横幅难看，只保留顶部分隔线
        { borderTopColor: colors.borderCard },
      ]}
      accessibilityRole="button"
      accessibilityLabel={`置顶 ${thread.title || ''}`}
    >
      {/* 左：喇叭图案 */}
      <SymbolView name="megaphone.fill" size={15} tintColor={colors.primary} />
      {/* 中：置顶标识（带背景） */}
      <View style={[styles.topBadge, { backgroundColor: colors.primary + '1A' }]}>
        <Text style={[styles.topBadgeText, { color: colors.primary }]}>置顶</Text>
      </View>
      {/* 右：纯文字（超长截断） */}
      <Text style={[styles.topBannerText, { color: colors.text }]} numberOfLines={1}>
        {text}
      </Text>
    </Pressable>
  );
});

// ────────────────────────────────────────────────────────────
// LikeButton — heart 弹簧 pop 动画
// ────────────────────────────────────────────────────────────
const LikeButton = React.memo(function LikeButton({
  liked,
  count,
  onPress,
}: {
  liked: boolean;
  count: number;
  onPress: (e: GestureResponderEvent) => void;
}) {
  const { colors } = useThemeColors();
  const { reduceMotion } = useReducedMotion();
  const pop = useSharedValue(1);
  const popStyle = useAnimatedStyle(() => ({
    transform: [{ scale: pop.value }],
  }));
  // 数字跳动：最低开销方案（无 runOnJS / 无翻牌文本动画）——计数变化时
  // 数字整体 scale 弹跳一次（1 → 1.28 → 1），纯 JSI 驱动。
  const numPop = useSharedValue(1);
  const numPopStyle = useAnimatedStyle(() => ({
    transform: [{ scale: numPop.value }],
  }));
  const prevCountRef = useRef(count);
  const settleTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => {
    const prev = prevCountRef.current;
    prevCountRef.current = count;
    if (reduceMotion || count === prev || count <= 0) return;
    numPop.value = withSequence(
      withSpring(1.28, { damping: 11, stiffness: 320, mass: 0.5 }),
      withSpring(1, MOMENTUM),
    );
    // 兜底保险（与 pop 同款问题预防，2026-08-28 吧页真机）：序列第二段
    // 万一被点赞触发的行重渲染打断，计数变化 700ms 后强制弹回 1；
    // 序列正常走完时该写入是幂等 no-op。
    settleTimerRef.current = setTimeout(() => {
      numPop.value = withSpring(1, MOMENTUM);
    }, 700);
    return () => {
      if (settleTimerRef.current) clearTimeout(settleTimerRef.current);
      settleTimerRef.current = null;
    };
  }, [count, reduceMotion, numPop]);

  const handlePressIn = useCallback((e: GestureResponderEvent) => {
    e.stopPropagation?.();
    // 蓄力底噪：按住期间低强度连续震（松手/移出即停），与下方 pop 动画解耦
    rtBeginLikeCharge();
    if (reduceMotion) return;
    // 弹簧 pop：1 → 1.35 → 1（点赞瞬间的推特式心跳）
    pop.value = withSequence(
      withSpring(1.35, { damping: 12, stiffness: 380, mass: 0.6 }),
      withSpring(1, MOMENTUM),
    );
  }, [pop, reduceMotion]);

  const handlePressOut = useCallback((e: GestureResponderEvent) => {
    rtEndLikeCharge();
    stopPropagation(e);
    // 显式弹回 1（2026-08-28 吧页真机「点赞后按钮停在放大态」根修）：
    // 按压序列第二段 withSpring(1, MOMENTUM) 依赖 withSequence 自动衔接，
    // 点赞乐观更新引发的行重渲染期间该衔接偶发不执行，pop 停在 1.35 不回落。
    // 松手时以 MOMENTUM 弹簧强制回归原尺寸（与 PressScale 的按压生命周期
    // 同构——返回值永远由松手写入，不依赖序列自动续跑）；长按场景序列已
    // 自行走完，此处对 value=1 的弹簧写入是幂等 no-op。
    if (!reduceMotion) pop.value = withSpring(1, MOMENTUM);
  }, [pop, reduceMotion]);

  const tintColor = liked ? colors.liked : colors.textTertiary;
  return (
    <HdrPressable
      onPress={onPress}
      onPressIn={handlePressIn}
      onPressOut={handlePressOut}
      style={({ pressed }) => [styles.actionBtn, pressed && styles.actionBtnPressed]}
      hitSlop={6}
      accessibilityRole="button"
      accessibilityLabel={liked ? '取消点赞' : '点赞'}
    >
      <Animated.View style={popStyle}>
        <SymbolView
          name={liked ? 'heart.fill' : 'heart'}
          size={17}
          tintColor={tintColor}
        />
      </Animated.View>
      <Animated.View style={numPopStyle}>
        <Text style={[styles.actionText, { color: tintColor }]}>
          {count > 0 ? formatCount(count) : '赞'}
        </Text>
      </Animated.View>
    </HdrPressable>
  );
});

// ────────────────────────────────────────────────────────────
// Styles
// ────────────────────────────────────────────────────────────
const styles = StyleSheet.create({
  // 外层：列表边距 + 卡片间距（替代分割线）
  cardWrap: {
    marginHorizontal: CARD_WRAP_MARGIN,
    marginVertical: 4,
  },
  card: {
    borderRadius: CARD_RADIUS,
    borderCurve: 'continuous',
    borderWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: CARD_PADDING_X,
    paddingTop: 12,
    paddingBottom: 8,
    overflow: 'hidden',
  },

  // ── 置顶帖横幅 ──
  // 横线分隔（用户要求）：去掉药丸边框盒（borderRadius+borderWidth 四边），
  // 改为顶部一条 hairline 横线 + 浅底；marginVertical 2：相邻置顶横幅间距
  // 4pt、与上方卡片约 6pt，成紧凑置顶组。
  topBanner: {
    marginVertical: 2,
    borderTopWidth: StyleSheet.hairlineWidth,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    paddingHorizontal: 16,
    paddingVertical: 11,
  },
  topBadge: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: 8,
    borderCurve: 'continuous',
  },
  topBadgeText: {
    ...typographyStyles.caption1Bold,
    fontWeight: '700',
  },
  topBannerText: {
    flex: 1,
    ...typographyStyles.footnote,
    fontWeight: '500',
  },

  // ── 头部 ──
  headerRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: AVATAR_GAP,
  },
  nameCol: {
    flex: 1,
    justifyContent: 'center',
    minHeight: AVATAR_SIZE,
    gap: 1,
  },
  nameRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
  },
  displayName: {
    ...typographyStyles.subheadBold,
    flexShrink: 1,
  },
  handle: {
    ...typographyStyles.subhead,
    flexShrink: 1,
  },
  time: {
    ...typographyStyles.subhead,
  },

  // ── 内容列（与名字列对齐） ──
  contentCol: {
    marginLeft: CONTENT_INDENT,
    // -6：头部名字行在 nameCol(44) 内垂直居中，名义 2pt 实际约 14pt 空白；
    // 负 margin 收紧到 ~8pt（2026-08-28 用户「缩小标题与用户名行空白」）。
    marginTop: -6,
    gap: 6,
  },
  /** 摘要（与标题拆块，2026-08-28）：标题/摘要间 4pt 分层留白；行距 22=1.47 与帖内/楼中楼正文统一（21 曾是全 app 唯一偏紧处） */
  abstract: {
    ...typographyStyles.subhead,
    lineHeight: 22,
    marginTop: 4,
  },
  bodyTitle: {
    ...typographyStyles.headline,
    fontWeight: '500',
  },
  showMoreBtn: {
    marginTop: 2,
  },
  showMore: {
    ...typographyStyles.subheadBold,
    paddingVertical: 2,
    alignSelf: 'flex-start',
  },
  closeButton: {
    width: 26,
    height: 26,
    borderRadius: 13,
    borderCurve: 'continuous',
    alignItems: 'center',
    justifyContent: 'center',
  },

  // ── 引用帖（转发） ──
  quoteCard: {
    borderWidth: StyleSheet.hairlineWidth,
    ...RadiusStyle.input,
    padding: 10,
    gap: 3,
  },
  quoteForum: {
    ...typographyStyles.caption1Bold,
  },
  quoteTitle: {
    ...typographyStyles.footnoteBold,
  },
  quoteContent: {
    ...typographyStyles.footnote,
  },

  // ── 吧名徽章（Kotlin ForumInfoChip：chip 底 + 方形吧头像 + "xx吧"）──
  // 圆角与帖子卡片同 token（2026-08-28 用户要求视觉统一，原写死 4）
  forumChip: {
    flexDirection: 'row',
    alignItems: 'center',
    alignSelf: 'flex-start',
    gap: 8,
    padding: 4,
    borderRadius: Radius.card,
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  forumChipText: {
    ...typographyStyles.caption1,
    marginRight: 4,
  },

  // ── 操作栏 ──
  actionRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginTop: 2,
  },
  actionBtn: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
    minHeight: 32,
  },
  actionBtnPressed: {
    opacity: 0.45,
  },
  actionText: {
    ...typographyStyles.footnote,
    fontWeight: '500',
    fontVariant: ['tabular-nums'],
  },
});

export default TweetCard;