/**
 * 楼中楼行与父楼卡（从 app/thread/[id]/subposts.tsx 拆出）：
 * - ReplyItem：单条回复行（淡入、⋮ ActionSheet、点赞、缩略图）
 * - ParentReplyCard：上一级回复卡（折叠预览 → 展开富文本）
 * - FallbackParentCard：无快照时的「主楼」回退卡
 * - 内部：extractImages / VoiceBlocks / InlinePostContent
 */

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import {
  View, StyleSheet, Pressable, Text,
  ScrollView, ActionSheetIOS, useWindowDimensions,
} from 'react-native';
import Reanimated, {
  useAnimatedStyle, withTiming, withDelay, useSharedValue,
  LinearTransition,
} from 'react-native-reanimated';
import { Image } from 'expo-image';
import { Link, useRouter } from 'expo-router';
import { SymbolView } from '@/components/ui/SymbolView';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { hapticForScene } from '@/theme/hapticsMap';
import * as Clipboard from 'expo-clipboard';
import { Avatar } from '@/components/ui/Avatar';
import { EASE_OUT, DURATION } from '@/theme/springs';
import {RadiusStyle} from '@/theme';
import { typographyStyles } from '@/theme/typography';
import { useReducedMotion } from '@/hooks/useReducedMotion';
import { contentToText, formatCount, summarizeText } from '@/utils';
import { useTimeLabel } from '@/hooks/useTimeLabel';
import { levelBadgeColor } from '@/constants/rank';
import { useAppPreference } from '@/hooks/useAppPreference';
import { openLink } from '@/utils/linkOpener';
import { frameFromPressEvent, type ImageSourceFrame } from '@/hooks/useImageViewer';
import { LineClampPreview } from '@/components/ui/LineClampPreview';
import { TiebaRichText } from '../../../../modules/tieba-native/src/TiebaRichText';
import { contentToRichTextRuns } from '@/utils/richTextRuns';
import { AudioSegment } from '@/components/thread/AudioSegment';
import { thumbnailUrl, THUMB_CARD } from '@/utils/thumbnail';
import type { SubPostInfo, PostContent } from '@/types';
import type { SemanticColors } from '@/theme/colors';
import type { ParentPostSummary } from '@/stores/parentPostCache';
import PostImageContextMenu from '@/components/feed/PostImageContextMenu';

/** Extract image URLs from sub-post content (normalized to https) */
function extractImages(content: SubPostInfo['content']): string[] {
  if (!content) return [];
  return content
    .filter((c): c is Extract<PostContent, { type: 'image' }> => !!c && c.type === 'image')
    .map((c) => c.src || '')
    .filter(Boolean);
}

/** 楼中楼语音段：与主帖同款 AudioSegment（惰性播放器），逐条渲染 */
function VoiceBlocks({ content }: { content: SubPostInfo['content'] | null }) {
  if (!content) return null;
  const blocks = content.filter(
    (c): c is Extract<PostContent, { type: 'audio' }> => !!c && c.type === 'audio',
  );
  if (blocks.length === 0) return null;
  return (
    <>
      {blocks.map((seg, i: number) => (
        <AudioSegment key={i} src={seg.src} duration={seg.duration} />
      ))}
    </>
  );
}

/** Inline sub-post content with tappable @mentions, links, and topics. */
export function InlinePostContent({
  content,
  colors,
  contentWidth,
}: {
  content: SubPostInfo['content'];
  colors: SemanticColors;
  /** 容器实测宽度（pt）：原生富文本按该宽度换行，避免按整窗宽度排版后文字溢出容器 */
  contentWidth?: number;
}) {
  const router = useRouter();
  const { width } = useWindowDimensions();
  const runs = useMemo(() => contentToRichTextRuns(content), [content]);
  if (!content || content.length === 0) {
    return <Text style={[s.inlineText, { color: colors.textDisabled }]}>[内容已删除]</Text>;
  }
  const effectiveWidth = contentWidth && contentWidth > 0
    ? contentWidth
    : Math.max(0, width - 60);
  return (
    <TiebaRichText
      runs={runs}
      contentWidth={effectiveWidth}
      fontSize={15}
      lineHeight={22}
      textColor={colors.text}
      linkColor={colors.primary}
      onLinkPress={(url) => openLink(url)}
      onUserPress={(uid) => router.push(`/user/${uid}`)}
      onTopicPress={(topicId, topicName) =>
        router.push(`/topic/${topicId}?name=${encodeURIComponent(topicName)}`)
      }
    />
  );
}

// ─── Animated Reply Item ───
export const ReplyItem = React.memo(function ReplyItem({
  item,
  index,
  colors,
  threadAuthorId,
  onAgree,
  animateIn,
  isOwn,
  onDelete,
  onImagePress,
}: {
  item: SubPostInfo;
  index: number;
  colors: SemanticColors;
  threadAuthorId?: string;
  onAgree: (item: SubPostInfo) => void;
  animateIn: boolean;
  isOwn: boolean;
  onDelete: (item: SubPostInfo) => void;
  onImagePress: (images: string[], index: number, sourceFrame?: ImageSourceFrame | null, origins?: (string | undefined)[], contextTitle?: string | null) => void;
}) {
  const router = useRouter();
  const { reduceMotion } = useReducedMotion();
  // 时间格式 / IP 属地 / 等级徽标（设置→使用习惯→贴子）
  const timeLabel = useTimeLabel();
  const showIpLocation = useAppPreference('showIpLocation', true);
  const showLevelBadge = useAppPreference('showLevelBadge', true);
  // 实测量行宽：原生富文本按容器实际宽度换行，长文本不会溢出行的边界
  const [rowWidth, setRowWidth] = useState(0);
  // Reanimated shared value — only the first loaded batch fades in with a
  // stagger; paginated/recycled rows stay opaque (effect self-corrects).
  const fade = useSharedValue(animateIn && !reduceMotion ? 0 : 1);
  const isLz = !!(threadAuthorId && item.authorId === threadAuthorId);
  const hasLevel = (item.authorLevelId ?? 0) > 0;
  // 等级徽标：Kotlin 官方等级多色（getIconColorByLevel+greifyColor 复刻）
  const levelBadge = hasLevel ? levelBadgeColor(item.authorLevelId ?? 0) : null;
  const images = extractImages(item.content);
  // 大图查看器顶栏标题：回复文字前 30 字（超出省略；规则共用 summarizeText，
  // 与 thread/[id].tsx 引用图摘要一致）
  const replySummary = useMemo(() => summarizeText(contentToText(item.content)), [item.content]);

  useEffect(() => {
    if (!animateIn || reduceMotion) {
      fade.value = 1;
      return;
    }
    // animateIn 翻转（首帧后 initialBatchIdsRef 才填充）时先强制归零再延迟淡入：
    // 否则共享值仍为初始 1，from=1→to=1 的 withTiming 是 no-op，首批行永远不淡入。
    fade.value = 0;
    fade.value = withDelay(index * DURATION.stagger, withTiming(1, {
      duration: DURATION.enter,
      easing: EASE_OUT,
    }));
  }, [animateIn, index, fade, reduceMotion]);

  // ── 更多操作（⋮ 菜单，ActionSheetIOS）──
  // 说明：这一行曾用 <MenuView>（expo-ui SwiftUI ContextMenu）整行包裹，
  // 但 SwiftUI 托管层会把可变高度的回复行钳成固定 72pt 容器，多行正文
  // 溢出绘制到下一行 → 文字互相遮挡。故保留 ActionSheet 方案（交互与
  // 旧长按一致，不再钳制布局）；正文长按则完全交还系统原生文本选择。
  const handleMorePress = useCallback(() => {
    hapticForScene('press');
    const options = ['复制内容', '查看用户'];
    if (isOwn) {
      options.push('删除');
    }
    const cancelIndex = options.length;
    // ActionSheetIOS 只有一个 destructive 位：仅本人可见「删除」时以删除为
    // destructive，否则不以任何项为 destructive。
    ActionSheetIOS.showActionSheetWithOptions(
      {
        options: [...options, '取消'],
        cancelButtonIndex: cancelIndex,
        destructiveButtonIndex: isOwn ? 2 : undefined,
      },
      (buttonIndex) => {
        if (buttonIndex === 0) {
          Clipboard.setStringAsync(contentToText(item.content) || '[内容已删除]');
        } else if (buttonIndex === 1) {
          router.push({ pathname: '/user/[uid]', params: { uid: item.authorId } });
        } else if (buttonIndex === 2 && isOwn) {
          onDelete(item);
        }
      },
    );
  }, [item, isOwn, onDelete, router]);

  const animatedStyle = useAnimatedStyle(() => ({
    opacity: fade.value,
    transform: [{ translateY: (1 - fade.value) * 8 }],
  }));

  return (
    <Reanimated.View style={animatedStyle}>
      {/* 行间分隔线用显式 View（borderBottom 放在 Reanimated.View 上在该版本
          下渲染不出来，整页无分隔线）；index>0 的每一行上方都画一条 hairline，
          保证所有回复之间都有分隔。 */}
      {index > 0 && <View style={[s.rowDivider, { backgroundColor: colors.separator }]} />}
      {/* 长按已交还系统原生文本选择（自定义弹层已移除），
          行本身不再拦截手势，仅作布局容器。
          VoiceOver：行合并为单个无障碍元素（用户名/等级/时间/内容/点赞数），
          装饰性子树（头部、回复引用）对读屏隐藏，图片按钮与正文链接保留。 */}
      <View
        style={s.row}
        accessible
        accessibilityLabel={[
          item.authorNameShow || item.authorName,
          showLevelBadge && hasLevel ? `Lv.${item.authorLevelId}` : '',
          timeLabel(item.createTime),
          contentToText(item.content) || '[内容已删除]',
          (item.agreeNum ?? 0) > 0 ? `${item.agreeNum}个赞` : '未点赞',
        ]
          .filter(Boolean)
          .join('，')}
      >
        {/* Main content area */}
        <View style={s.itemContent} onLayout={(e) => setRowWidth(e.nativeEvent.layout.width)}>
          {/* Row 1: Avatar + Name + Badges */}
          <View style={s.headerRow} importantForAccessibility="no-hide-descendants">
            <Link
              href={{ pathname: '/user/[uid]', params: { uid: item.authorId } }}
              push
              asChild
            >
              <Pressable style={s.avatarNameRow}>
                <Avatar
                  source={item.authorPortrait}
                  initials={item.authorName?.slice(0, 2)}
                  size={28}
                />
                <Text style={[s.name, { color: colors.text }]} numberOfLines={1}>
                  {item.authorNameShow || item.authorName}
                </Text>
              </Pressable>
            </Link>

            {showLevelBadge && hasLevel && levelBadge && (
              <View style={[s.levelChip, { backgroundColor: levelBadge.bg }]}>
                <Text style={[s.levelChipText, { color: levelBadge.color }]}>
                  Lv.{item.authorLevelId}
                </Text>
              </View>
            )}
            {isLz && (
              <View style={[s.lzChip, { backgroundColor: colors.primary + '15' }]}>
                <Text style={[s.lzChipText, { color: colors.primary }]}>楼主</Text>
              </View>
            )}

            <View style={s.headerRight}>
              <Text style={[s.meta, { color: colors.textTertiary }]} numberOfLines={1}>
                {timeLabel(item.createTime)}
              </Text>
              {/* ⋮ 更多操作：点赞左侧（复制内容/查看用户/举报/删除，与旧长按一致） */}
              <HdrPressable
                onPress={handleMorePress}
                hitSlop={10}
                flashRadius={9}
                accessibilityRole="button"
                accessibilityLabel="更多操作"
              >
                <SymbolView name="ellipsis" size={18} weight="bold" tintColor={colors.textTertiary} />
              </HdrPressable>
              {/* 点赞：右上角（与帖子回复卡一致） */}
              <HdrPressable
                onPress={() => onAgree(item)}
                style={s.likeBtn}
                flashRadius={9}
                // 触控热区 ≥44×44（视觉 20×15 心形 + 计数，靠 hitSlop 补足）
                hitSlop={{ top: 12, bottom: 12, left: 10, right: 10 }}
                accessibilityRole="button"
                accessibilityLabel={item.isAgree ? '取消点赞' : '点赞'}
              >
                <SymbolView
                  name={item.isAgree ? 'heart.fill' : 'heart'}
                  size={15}
                  tintColor={item.isAgree ? colors.liked : colors.textTertiary}
                />
                {(item.agreeNum ?? 0) > 0 && (
                  <Text style={[s.agreeCount, { color: item.isAgree ? colors.liked : colors.textTertiary }]}>
                    {formatCount(item.agreeNum ?? 0)}
                  </Text>
                )}
              </HdrPressable>
            </View>
          </View>

          {/* Row 1.5: IP 属地独立一栏（2026-09-02 用户：楼中楼详情页 IP 放
              用户名下单独一行——此前夹在 headerRow 同行被点赞/更多按钮挤没） */}
          {showIpLocation && item.ipLocation ? (
            <View style={s.ipRow}>
              <Text style={[s.ipText, { color: colors.textTertiary }]} numberOfLines={1}>
                IP属地：{item.ipLocation}
              </Text>
            </View>
          ) : null}

          {/* Row 2: Reply-to reference (if any) */}
          {item.replyToUserName ? (
            <View
              style={[s.replyChip, { backgroundColor: colors.primary + '08' }]}
              importantForAccessibility="no-hide-descendants"
            >
              <SymbolView name="arrow.turn.up.left" size={11} tintColor={colors.primary} />
              <Text style={[s.replyChipText, { color: colors.primary }]}>
                {item.replyToUserName}
              </Text>
            </View>
          ) : null}

          {/* Row 3: Content */}
          <View style={s.content}>
            <InlinePostContent content={item.content} colors={colors} contentWidth={rowWidth} />
          </View>

          {/* Row 3.25: Voice — 楼中楼语音条（与主帖同款） */}
          <VoiceBlocks content={item.content} />

          {/* Row 3.5: Images — P0: 楼中楼图片接入 ImageViewer 大图查看器。
              收集该楼全部图片 URL，点击任一张（含 +N 徽标）打开大图，
              初始定位到对应下标；分页/回收复用的行也能正常打开。 */}
          {images.length > 0 && (
            <View style={s.imageRow}>
              {/* C8: subpost media caps at 3 thumbnails with a +N chip.
                  80pt 缩略图走服务端 200px 缩略（原图可达数 MB，
                  楼中楼多图时内存/流量浪费严重）。 */}
              {images.slice(0, 3).map((uri, i) => (
                <PostImageContextMenu key={i} full={uri}>
                  <Pressable
                    onPress={(e) =>
                      onImagePress(
                        images,
                        i,
                        // 飞回原位源矩形（2026-08-31）：80pt 缩略图
                        frameFromPressEvent(e, { width: 80, height: 80 }),
                        undefined,
                        replySummary,
                      )
                    }
                    style={({ pressed }) => [
                      s.thumbImage,
                      { opacity: pressed ? 0.75 : 1 },
                    ]}
                    accessibilityRole="button"
                    accessibilityLabel={`查看第${i + 1}张图片`}
                  >
                    <Image
                      source={{ uri: thumbnailUrl(uri, THUMB_CARD) }}
                      style={s.thumbImage}
                      contentFit="cover"
                      cachePolicy="memory-disk"
                      recyclingKey={uri}
                    />
                  </Pressable>
                </PostImageContextMenu>
              ))}
              {images.length > 3 && (
                <Pressable
                  onPress={() => onImagePress(images, 3, undefined, undefined, replySummary)}
                  style={({ pressed }) => [
                    s.thumbImage,
                    s.moreImagesBadge,
                    { opacity: pressed ? 0.75 : 1 },
                  ]}
                  accessibilityRole="button"
                  accessibilityLabel="查看全部图片"
                >
                  <Text style={s.moreImagesText}>+{images.length - 3}</Text>
                </Pressable>
              )}
            </View>
          )}
        </View>
      </View>
    </Reanimated.View>
  );
});

// ─── 上一级回复卡（ListHeader） ───
// 用户从帖子页点「查看更多回复」时被点击的回复会经 parentPostCache 快照过来。
// 这里展示它的完整内容（作者 + 富文本 + 图片），再下面是楼中楼列表。
// 正文默认折叠为 ≤PREVIEW_LINES 行纯文本 + 「查看更多」，展开后回到完整富文本
// 渲染（@/链接/表情可点）。避免超长预览正文把整个页面撑成"占满整屏"。
const PARENT_PREVIEW_LINES = 3;
/** 折叠测量文本的字符上限（降本：超长父楼全文测量纯属浪费，见 measureText 注释） */
const PREVIEW_MEASURE_CHAR_LIMIT = 2000;

export function ParentReplyCard({
  parent,
  colors,
  floor,
  decodedForumName,
  decodedThreadTitle,
  threadId,
  onImagePress,
}: {
  parent: ParentPostSummary;
  colors: SemanticColors;
  floor?: string;
  decodedForumName: string;
  decodedThreadTitle: string;
  threadId?: string;
  onImagePress: (images: string[], index: number, sourceFrame?: ImageSourceFrame | null, origins?: (string | undefined)[], contextTitle?: string | null) => void;
}) {
  const images = extractImages(parent.content);
  const timeLabel = useTimeLabel();
  const showIpLocation = useAppPreference('showIpLocation', true);
  // 大图查看器顶栏标题：被引用回复文字前 30 字（超出省略；规则共用
  // summarizeText，与 thread/[id].tsx 引用图摘要一致）
  const parentSummary = useMemo(() => summarizeText(contentToText(parent.content)), [parent.content]);
  const [expanded, setExpanded] = useState(false);

  return (
    <Reanimated.View
      layout={LinearTransition}
      style={[s.mainPostCard, { backgroundColor: colors.secondarySystemGroupedBackground, borderColor: colors.borderCard }]}
    >
      {/* 作者行：头像 + 昵称 + 楼主徽标 + 时间（顶部不再显示「上一级回复」指示） */}
      <View style={s.headerRow}>
        <Link href={{ pathname: '/user/[uid]', params: { uid: parent.authorId } }} push asChild>
          <Pressable style={s.avatarNameRow}>
            <Avatar
              source={parent.authorPortrait}
              initials={parent.authorName?.slice(0, 2)}
              size={30}
            />
            <Text style={[s.name, { color: colors.text }]} numberOfLines={1}>
              {parent.authorNameShow || parent.authorName}
            </Text>
          </Pressable>
        </Link>
        {!!parent.authorIsLz && (
          <View style={[s.lzChip, { backgroundColor: colors.primary + '15' }]}>
            <Text style={[s.lzChipText, { color: colors.primary }]}>楼主</Text>
          </View>
        )}
        <View style={s.spacer} />
        <Text style={[s.meta, { color: colors.textTertiary }]} numberOfLines={1}>
          {timeLabel(parent.createTime)}
        </Text>
      </View>

      {/* IP 属地独立一栏（2026-09-03：与 ReplyItem 对齐，用户名下单独一行。
          此前夹在时间栏同行，用户实测"显示更多"界面用户名下无属地） */}
      {showIpLocation && parent.ipLocation ? (
        <View style={s.ipRow}>
          <Text style={[s.ipText, { color: colors.textTertiary }]} numberOfLines={1}>
            IP属地：{parent.ipLocation}
          </Text>
        </View>
      ) : null}

      {/* 正文：折叠预览收敛到共享 LineClampPreview（thermo Z4-E，含 2000 字
          测量降本）；展开后回到完整原生富文本 */}
      <View style={s.content}>
        {expanded ? (
          <>
            <InlinePostContent content={parent.content} colors={colors} />
            <VoiceBlocks content={parent.content} />
          </>
        ) : (
          <LineClampPreview
            text={contentToText(parent.content) || '[内容已删除]'}
            maxLines={PARENT_PREVIEW_LINES}
            // 显式颜色：parentPreviewText 无 color，Text 默认纯黑，
            // 深色模式下顶部卡片正文发黑（真机实测 2026-08-26，与
            // PostCard 折叠预览同源同修）
            textStyle={[s.parentPreviewText, { color: colors.text }]}
            readMoreColor={colors.primary}
            onExpand={() => setExpanded(true)}
            measureCharLimit={PREVIEW_MEASURE_CHAR_LIMIT}
          />
        )}
      </View>

      {/* 图片：横向缩略图滑动条 */}
      {images.length > 0 && (
        <ScrollView
          horizontal
          showsHorizontalScrollIndicator={false}
          contentContainerStyle={s.parentImageStrip}
        >
          {images.map((uri, i) => (
            <Pressable
              key={i}
              onPress={(e) =>
                      onImagePress(
                        images,
                        i,
                        // 飞回原位源矩形（2026-08-31）：80pt 缩略图
                        frameFromPressEvent(e, { width: 80, height: 80 }),
                        undefined,
                        parentSummary,
                      )
                    }
              style={({ pressed }) => [s.thumbImage, { opacity: pressed ? 0.75 : 1 }]}
              accessibilityRole="button"
              accessibilityLabel={`查看第${i + 1}张图片`}
            >
              <Image
                source={{ uri: thumbnailUrl(uri, THUMB_CARD) }}
                style={s.thumbImage}
                contentFit="cover"
                cachePolicy="memory-disk"
                recyclingKey={uri}
              />
            </Pressable>
          ))}
        </ScrollView>
      )}

      {/* 底部：帖子标题归属（可点 → 打开原帖；2026-09-03 用户要求去掉
          chevron 箭头，标题本身即跳转入口） */}
      <View style={[s.parentFooter, { borderTopColor: colors.borderCard }]}>
        <Link href={{ pathname: '/thread/[id]', params: { id: threadId ?? '' } }} push asChild>
          <Pressable
            style={({ pressed }) => [s.parentSourceLink, pressed && { opacity: 0.6 }]}
            accessibilityRole="link"
            accessibilityLabel={`打开原帖：${decodedThreadTitle || decodedForumName || '原帖'}`}
          >
            <Text style={[s.parentFloor, { color: colors.textLink }]} numberOfLines={2}>
              {decodedThreadTitle || decodedForumName || '原帖'} · 第{floor || '?'}楼回复
            </Text>
          </Pressable>
        </Link>
      </View>
    </Reanimated.View>
  );
}

// ─── 无快照回退卡：「主楼」标题卡（深链/reload 后直接进入时展示） ───
export function FallbackParentCard({
  colors,
  decodedForumName,
  decodedThreadTitle,
  floor,
  threadId,
}: {
  colors: SemanticColors;
  decodedForumName: string;
  decodedThreadTitle: string;
  floor?: string;
  threadId?: string;
}) {
  return (
    <View style={[s.mainPostCard, { backgroundColor: colors.secondarySystemGroupedBackground, borderColor: colors.borderCard }]}>
      <Text style={[s.mainPostLabel, { color: colors.textTertiary }]}>主楼</Text>
      {/* 标题/元信息区可点 → 打开原帖（原独立「打开原帖」按钮已并入此入口） */}
      <Link href={{ pathname: '/thread/[id]', params: { id: threadId ?? '' } }} push asChild>
        <Pressable
          style={({ pressed }) => [pressed && { opacity: 0.6 }]}
          accessibilityRole="link"
          accessibilityLabel={`打开原帖：${decodedThreadTitle || decodedForumName || '原帖'}`}
        >
          {decodedThreadTitle ? (
            <>
              <Text style={[s.mainPostTitle, { color: colors.text }]} numberOfLines={2}>
                {decodedThreadTitle}
              </Text>
              {decodedForumName ? (
                <Text style={[s.mainPostMeta, { color: colors.textTertiary }]}>
                  {decodedForumName} · 第{floor || '?'}楼回复
                </Text>
              ) : null}
            </>
          ) : (
            <Text style={[s.mainPostTitle, { color: colors.text }]}>
              {decodedForumName || '原帖'} · 第{floor || '?'}楼回复
            </Text>
          )}
        </Pressable>
      </Link>
    </View>
  );
}

// ─── Styles ───
const s = StyleSheet.create({
  // Main-post card at the top of the sub-post page
  mainPostCard: {
    ...RadiusStyle.input,
    borderWidth: StyleSheet.hairlineWidth,
    padding: 14,
    marginBottom: 10,
    gap: 4,
  },
  mainPostLabel: {
    fontSize: 11,
    fontWeight: '700',
  },
  mainPostTitle: {
    fontSize: 16,
    fontWeight: '700',
    lineHeight: 22,
  },
  mainPostMeta: {
    fontSize: 12,
  },
  parentImageStrip: {
    flexDirection: 'row',
    gap: 6,
    marginBottom: 8,
    paddingVertical: 2,
  },
  parentFooter: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 8,
    marginTop: 10,
    paddingTop: 10,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  parentFloor: {
    fontSize: 12,
    flexShrink: 1,
  },
  // 来源行可点（打开原帖）：文本 + 尾部 chevron
  parentSourceLink: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    flexShrink: 1,
  },

  inlineText: {
    fontSize: 15,
    lineHeight: 22,
  },

// 条目容器 — 信息流行分隔风格：无卡片底色/圆角；行间距靠 row padding
  // （分隔线为显式 View，见 rowDivider）
  // marginLeft 14：与顶部主楼卡片头像对齐（listContent 10 + mainPostCard
  // padding 14 = 24pt 左缘），正文首字同时从头像正下方开始；
  // marginRight 14 对称（左右 24pt 等宽，不再右贴屏幕）。
  rowDivider: {
    height: StyleSheet.hairlineWidth,
    // 内缩与文本起始对齐（14 对齐 margion + 28 头像 + 8 gap）
    marginLeft: 50,
  },
  row: {
    marginHorizontal: 14,
    paddingVertical: 14,
  },

  // Content wrapper
  itemContent: {
    flex: 1,
  },

// Header row: avatar + name + badges + time
  headerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    marginBottom: 8,
  },
  // Header 右端：时间 · IP + 点赞（点赞固定右上角）
  headerRight: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    marginLeft: 'auto',
  },
  likeBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    paddingVertical: 2,
  },
  avatarNameRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    flexShrink: 1,
  },
  name: {
    ...typographyStyles.subheadBold,
    flexShrink: 1,
  },
  levelChip: {
    // 尺寸与 PostCard.levelBadge 对齐（2026-08-28 用户反馈统一）
    paddingHorizontal: 5,
    paddingVertical: 1,
    borderRadius: 4,
    borderCurve: 'continuous',
  },
  levelChipText: {
    ...typographyStyles.caption2,
    fontWeight: '700',
    lineHeight: 14,
  },
  lzChip: {
    paddingHorizontal: 5,
    paddingVertical: 1.5,
    borderRadius: 4,
    borderCurve: 'continuous',
  },
  lzChipText: {
    fontSize: 10,
    fontWeight: '700',
  },
  spacer: { flex: 1 },
  meta: {
    ...typographyStyles.caption1,
    flexShrink: 0,
  },
  // IP 属地独立一栏（2026-09-02）：楼中楼详情页用户名下单独一行，
  // 不再挤进 headerRow 同行被操作钮截断
  ipRow: {
    flexDirection: 'row',
    marginBottom: 6,
  },
  ipText: {
    fontSize: 11,
    fontWeight: '400',
  },

// Reply-to chip
  replyChip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    alignSelf: 'flex-start',
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderRadius: 6,
    borderCurve: 'continuous',
    marginBottom: 8,
  },
  replyChipText: {
    fontSize: 12,
    fontWeight: '500',
  },

  // Content text（fontSize/lineHeight 对 View 无效，仅留间距）
  content: {
    marginBottom: 8,
  },

  // 父楼预览正文：折叠态的纯文本（与富文本同字号/行高）
  parentPreviewText: {
    fontSize: 15,
    lineHeight: 22,
  },

  // Image thumbnails
  imageRow: {
    flexDirection: 'row',
    gap: 6,
    marginBottom: 8,
    marginTop: 2,
    flexWrap: 'wrap',
  },
  thumbImage: {
    width: 80,
    height: 80,
    ...RadiusStyle.input,
  },
  moreImagesBadge: {
    backgroundColor: 'rgba(0,0,0,0.5)',
    justifyContent: 'center',
    alignItems: 'center',
  },
  moreImagesText: {
    color: '#FFF',
    fontSize: 14,
    fontWeight: '700',
  },

  // 点赞计数（右上角心形旁）
  agreeCount: {
    fontSize: 12,
    fontWeight: '500',
  },
});
