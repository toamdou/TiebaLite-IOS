/**
 * PostCard — iOS 26 reply card
 *
 * Design:
 * - Card shell: colors.card background, borderRadius 16, padding 16, hairline border
 * - Author row: 36pt avatar + name + level badge + 楼主 tag, time/floor/IP meta below
 * - Content: text first, images extracted onto their own lines (PostContent)
 * - 楼中楼: surfaceSecondary rounded block (unchanged)
 * - Action bar: 分享 | 评论 … 点赞, separated from content by a hairline border
 */

import React, { useMemo, useCallback } from 'react';
import {
  View,
  Text,
  Pressable,
  StyleSheet,
  ScrollView,
  Share,
  ActionSheetIOS,
} from 'react-native';
import Reanimated, { LinearTransition } from 'react-native-reanimated';
import { Link } from 'expo-router';
import { Image } from 'expo-image';
import { SymbolView } from '@/components/ui/SymbolView';
import { hapticForScene } from '@/theme/hapticsMap';
import * as Clipboard from 'expo-clipboard';
import { useThemeColors } from '@/theme/ThemeContext';
import { useAppPreference } from '@/hooks/useAppPreference';
import { frameFromPressEvent } from '@/hooks/useImageViewer';
import {RadiusStyle, Radius} from '@/theme/spacing';
import { typographyStyles } from '@/theme/typography';
import { contentToText, formatCount, buildThreadUrl } from '@/utils';
import { useTimeLabel } from '@/hooks/useTimeLabel';
import { useRecyclingState } from '@legendapp/list/react-native';
import { thumbnailUrl, THUMB_CARD, pickViewerImages } from '@/utils/thumbnail';
import { isImageWarm, markImageWarm } from '@/utils/imageWarm';
import { Avatar } from '@/components/ui/Avatar';
import PostContent from './PostContent';
import { RichTextRunsText } from './RichTextRunsText';
import { LineClampPreview } from '@/components/ui/LineClampPreview';
import type { SemanticColors } from '@/theme/colors';
import type { ImagePressHandler } from './PostImages';
import type { PostInfo, PostContent as PostContentType, SubPostInfo } from '@/types';
import { HdrPressable } from '@/components/ui/HdrPressable';

interface PostCardProps {
  post: PostInfo;
  forumName?: string;
  isLz: boolean;
  subPosts?: SubPostInfo[];
  onAgree?: (postId: string, opType: number) => void;
  onDelete?: (postId: string) => void;
  onReport?: (postId: string) => void;
  onSubPostsPress?: (post: PostInfo) => void;
  /** 大图查看器顶栏标题覆盖（主楼传帖子标题；缺省用楼层内容摘要） */
  contextTitle?: string | null;
  /** 统一大图查看器回调签名（见 PostImages.ImagePressHandler）；meta 参数可缺省 */
  onImagePress?: ImagePressHandler;
}

function InlineQuoteContent({
  content,
  colors,
  onImagePress,
}: {
  content: SubPostInfo['content'];
  colors: SemanticColors;
  onImagePress?: ImagePressHandler;
}) {
  const dataSaverMode = useAppPreference('dataSaverMode', 'high') ?? 'high';
  if (!content || content.length === 0) {
    return <Text style={[s.quoteInlineText, { color: colors.textSecondary }]}>[内容已删除]</Text>;
  }
  // 楼中楼图片：收集成可横向滑动的缩略图条（紧凑引用块内 90pt 高）
  const images = content.filter(
    (seg): seg is Extract<PostContentType, { type: 'image' }> =>
      seg.type === 'image' && !!(seg.src || seg.originSrc),
  );
  // 展开态完整富文本（SubQuoteItem 折叠时调用本组件）：@/链接/表情/图片全渲染。
  // thermo Z2-F：段→run 装配与跳转语义收敛到 canonical（richTextRuns +
  // RichTextRunsText），删除此前手写的 seg switch；原生 TiebaRichText 无法
  // 嵌入引用行的嵌套文本流，故此处用 JS Text 版渲染器。
  return (
    <View style={s.quoteInlineFlow}>
      <RichTextRunsText
        content={content}
        baseStyle={[s.quoteInlineText, { color: colors.textSecondary }]}
        linkColor={colors.primary}
      />

      {/* 楼中楼图片：横向滑动查看缩略图，点击看大图 */}
      {images.length > 0 && (
        <ScrollView
          horizontal
          showsHorizontalScrollIndicator={false}
          nestedScrollEnabled
          contentContainerStyle={s.quoteImageStrip}
        >
          {images.map((img, imgIdx) => {
            const ratio = img.width > 0 && img.height > 0 ? img.width / img.height : 1;
            const thumbW = Math.min(Math.max(90 * ratio, 56), 140);
            // src 可能为空串（仅 originSrc 有值）→ 回退 originSrc，避免空 uri
            const src = img.src || img.originSrc || '';
            const uri = thumbnailUrl(src, THUMB_CARD);
            return (
              <Pressable
                key={imgIdx}
                onPress={(e) => {
                  e.stopPropagation();
                  hapticForScene('press');
                  const urls = pickViewerImages(images, dataSaverMode);
                  // thumbnail 尺寸已知（thumbW × 90），连同触点坐标还原屏幕矩形
                  onImagePress?.(urls, imgIdx, frameFromPressEvent(e, { width: thumbW, height: 90 }));
                }}
                style={[
                  s.quoteImageThumb,
                  { backgroundColor: colors.placeholder, width: thumbW, height: 90 },
                ]}
              >
                <Image
                  source={{ uri }}
                  style={s.quoteImageThumbImg}
                  contentFit="cover"
                  transition={isImageWarm(uri) ? 0 : 200}
                  onLoad={() => markImageWarm(uri)}
                  cachePolicy="memory-disk"
                  recyclingKey={src}
                />
              </Pressable>
            );
          })}
        </ScrollView>
      )}
    </View>
  );
}

// ── 楼中楼预览截断（用户反馈：前 3 条预览偶有超长正文，完整铺开会撑很久）──
// 折叠态＝按实测行数钳到 SUB_QUOTE_PREVIEW_LINES 行纯文本 + 行尾「… 更多」；
// 展开后回到完整富文本（@/链接/表情/图片）。测量方式与 subposts 页 ParentReplyCard
// 同款（隐藏测量 Text 读 onTextLayout，不用 numberOfLines——flexWrap 容器内会错误撑高）。
const SUB_QUOTE_PREVIEW_LINES = 2;

function SubQuoteItem({
  sp,
  colors,
  onImagePress,
}: {
  sp: SubPostInfo;
  colors: SemanticColors;
  onImagePress?: ImagePressHandler;
}) {
  const plainText = useMemo(() => contentToText(sp.content) || '[内容已删除]', [sp.content]);
  // useRecyclingState：楼层行开启 recycleItems 后，复用的行实例会把展开态
  // 带到新的引用子项上——按 item 身份在渲染期重置，杜绝串扰。
  const [expanded, setExpanded] = useRecyclingState(false);

  // 根容器必须 flex:1：自身是 subPostRow（row）的子项，若无宽度约束
  // 超长文本会按固有宽度排布不换行，整体溢出卡片右边界（真机实测）。
  return (
    <Reanimated.View layout={LinearTransition} style={s.subQuoteRoot}>
      {expanded ? (
        <InlineQuoteContent content={sp.content} colors={colors} onImagePress={onImagePress} />
      ) : (
        // 折叠态收敛到共享 LineClampPreview（thermo Z2-G）；两段文本均不拦截
        // 触摸（历史行为）：整卡可点区域保持干净，点击落到外层「查看回复」。
        // textStyle 必须带显式颜色：quoteInlineText 无 color，Text 默认纯黑，
        // 深色模式下前三条预览字发黑看不清（真机实测 2026-08-26）。
        <View pointerEvents="box-none">
          <LineClampPreview
            text={plainText}
            maxLines={SUB_QUOTE_PREVIEW_LINES}
            textStyle={[s.quoteInlineText, { color: colors.textSecondary }]}
            readMoreColor={colors.primary}
            onExpand={() => setExpanded(true)}
            readMoreLabel="展开楼中楼回复全文"
            textPointerEvents="none"
          />
        </View>
      )}
    </Reanimated.View>
  );
}

const PostCard = React.memo(function PostCard({
  post,
  forumName,
  isLz,
  subPosts,
  onAgree,
  onDelete,
  onReport,
  onSubPostsPress,
  contextTitle,
  onImagePress,
}: PostCardProps) {
  const { colors } = useThemeColors();
  const showBothUsername = useAppPreference('showBothUsername', false);
  // 时间格式 / IP 属地 / 等级徽标（设置→使用习惯→贴子）
  const timeLabel = useTimeLabel();
  const showIpLocation = useAppPreference('showIpLocation', true);
  const showLevelBadge = useAppPreference('showLevelBadge', true);

  // 复制内容：直接写入剪贴板（原 /copy 自由复制页已删除；
  // 长按正文只走系统原生文本选择，此处为 ⋮ 菜单入口）
  // 大图查看器顶栏标题：回复文字前 30 字（超出省略，避免完全显示楼层内容）
  const floorSummary = useMemo(() => {
    const text = contentToText(post.content).replace(/\s+/g, ' ').trim();
    return text.length > 30 ? `${text.slice(0, 30)}…` : text;
  }, [post.content]);

  const handleCopyPress = useCallback(async () => {
    hapticForScene('press');
    const textContent = contentToText(post.content);
    await Clipboard.setStringAsync(textContent || '[图片/视频/音频]');
    hapticForScene('action-success');
  }, [post.content]);

  const handleCopyLink = useCallback(async () => {
    hapticForScene('press');
    await Clipboard.setStringAsync(buildThreadUrl(post.threadId, post.id));
    hapticForScene('action-success');
  }, [post.threadId, post.id]);

  const handleShare = useCallback(async () => {
    hapticForScene('press');
    try {
      await Share.share({ message: buildThreadUrl(post.threadId, post.id) });
    } catch {
      // user cancelled the share sheet — ignore
    }
  }, [post.threadId, post.id]);

  const handleAgreePress = useCallback(() => {
    hapticForScene('like');
    onAgree?.(post.id, post.isAgree ? 0 : 1);
  }, [onAgree, post.id, post.isAgree]);

  // "..." 菜单改为原生 ActionSheet：此前每张卡挂一个 SwiftUI Menu（ThemedHost
  // + 原生视图树），400 楼快速滚动时创建/销毁开销是掉帧大头；ActionSheet
  // 零常驻视图，点击时才拉起系统面板。
  const handleMorePress = useCallback(() => {
    hapticForScene('press');
    const options = ['复制内容', '分享', '复制链接', '举报', ...(onDelete ? ['删除'] : []), '取消'];
    const cancelButtonIndex = options.length - 1;
    const destructiveButtonIndex = onDelete ? options.length - 2 : undefined;
    ActionSheetIOS.showActionSheetWithOptions(
      {
        options,
        cancelButtonIndex,
        destructiveButtonIndex,
      },
      (buttonIndex) => {
        switch (buttonIndex) {
          case 0: void handleCopyPress(); break;
          case 1: void handleShare(); break;
          case 2: void handleCopyLink(); break;
          case 3: onReport?.(post.id); break;
          case 4: onDelete?.(post.id); break;
        }
      },
    );
  }, [handleCopyPress, handleShare, handleCopyLink, onReport, onDelete, post.id]);

  const authorMeta =
    [
      timeLabel(post.createTime),
      post.floor > 0 ? `${post.floor}楼` : null,
      showIpLocation && post.ipLocation ? `IP属地:${post.ipLocation}` : null,
    ]
      .filter(Boolean)
      .join(' · ');
  // 等级徽标：主题色浅底 15% + 主题色字（2026-08-28 全局跟主题）
  const levelColor = post.authorLevelId > 0
    ? { backgroundColor: `${colors.primary}26`, color: colors.primary }
    : null;
  return (
    <View style={[s.card, { backgroundColor: colors.card, borderColor: colors.borderCard }]}>
      {/* 长按已交还系统原生文本选择（自定义 /copy 弹层已删除），
          卡壳不再拦截手势，仅作布局容器 */}
      <View>
        {/* ── Author Row: avatar + name/badges + meta … more ── */}
        <View style={s.authorRow}>
            <Link href={{ pathname: '/user/[uid]', params: { uid: post.authorId } }} push asChild>
              <Pressable style={s.authorGroup}>
                <Avatar
                  source={post.authorPortrait}
                  initials={post.authorNameShow || post.authorName}
                  size={36}
                />
                <View style={s.authorInfo}>
                  <View style={s.nameRow}>
                    <Text style={[s.name, { color: colors.text }]} numberOfLines={1}>
                      {showBothUsername && post.authorName && post.authorNameShow
                        ? `${post.authorNameShow} @${post.authorName}`
                        : (post.authorNameShow || post.authorName)}
                    </Text>
                    {showLevelBadge && levelColor && (
                      <View style={[s.levelBadge, { backgroundColor: levelColor.backgroundColor }]}>
                        <Text style={[s.levelBadgeText, { color: levelColor.color }]}>Lv.{post.authorLevelId}</Text>
                      </View>
                    )}
                    {isLz && (
                      <View style={[s.lzTag, { backgroundColor: colors.primary + '18' }]}>
                        <Text style={[s.lzTagText, { color: colors.primary }]}>楼主</Text>
                      </View>
                    )}
                  </View>
                  <Text style={[s.authorMeta, { color: colors.textTertiary }]} numberOfLines={1}>
                    {authorMeta}
                  </Text>
                </View>
              </Pressable>
            </Link>
            {/* 右侧操作：三点菜单 + 点赞（同行，共占一行，不单独占行） */}
            <View style={s.authorActions}>
              <HdrPressable
                onPress={() => {
                  void hapticForScene('sheet-present');
                  handleMorePress();
                }}
                hitSlop={10}
                effect="subtle"
                accessibilityRole="button"
                accessibilityLabel="更多操作"
              >
                <SymbolView name="ellipsis" size={18} weight="bold" tintColor={colors.textTertiary} />
              </HdrPressable>
              <HdrPressable onPress={handleAgreePress} hitSlop={8} style={s.likeBtn} flashRadius={8} glowOutset={5}>
                <SymbolView
                  name={post.isAgree ? 'heart.fill' : 'heart'}
                  size={18}
                  tintColor={post.isAgree ? colors.liked : colors.textTertiary}
                />
                {post.agreeNum > 0 && (
                  <Text style={[s.likeCount, { color: post.isAgree ? colors.liked : colors.textTertiary }]}>
                    {formatCount(post.agreeNum)}
                  </Text>
                )}
              </HdrPressable>
            </View>
          </View>

        {/* ── Content: text first, images on their own lines below ── */}
        <PostContent
          content={post.content}
          forumName={forumName}
          contextTitle={contextTitle ?? floorSummary}
          onImagePress={onImagePress}
        />

        {/* ── Sub-Post Quote Section (楼中楼) ──
            重写：与信息流分隔风格统一 —— 去卡片（无底色/圆角），
            上缘与行间用 hairline 横线分隔；文字预览严格限高 2 行
            （maxHeight 兜底 + numberOfLines），长文本不再撑破容器。 */}
        {((subPosts && subPosts.length > 0) || (post.subPostNum > 0)) && (
          <Pressable
            onPress={() => onSubPostsPress?.(post)}
            style={[s.subPostSection, { borderTopColor: colors.divider }]}
          >
            {subPosts && subPosts.length > 0 ? (
              <>
                {subPosts.slice(0, 3).map((sp, idx) => (
                  <React.Fragment key={sp.id}>
                    {idx > 0 && (
                      <View style={[s.subPostDivider, { backgroundColor: colors.divider }]} />
                    )}
                    <View style={s.subPostRow}>
                      <Text style={[s.subPostName, { color: colors.textSecondary }]} numberOfLines={1}>
                        {sp.authorNameShow || sp.authorName}：
                      </Text>
                      <SubQuoteItem sp={sp} colors={colors} onImagePress={onImagePress} />
                    </View>
                  </React.Fragment>
                ))}
                {post.subPostNum > 3 && (
                  <Text style={[s.quoteMore, { color: colors.primary }]}>
                    查看全部 {post.subPostNum} 条回复
                  </Text>
                )}
              </>
            ) : (
              <Text style={[s.quoteMore, { color: colors.primary }]}>
                查看 {post.subPostNum} 条回复
              </Text>
            )}
          </Pressable>
        )}
      </View>
    </View>
  );
});

export default PostCard;
// ── iOS-native styles ──
// Card shell: colors.card / radius 16 / padding 16 / hairline border
// Typography: name=subheadline semibold, meta=caption tertiary, actions=footnote

const s = StyleSheet.create({
  card: {
    marginHorizontal: 10,
    marginVertical: 4,
    ...RadiusStyle.card,
    padding: 16,
    borderWidth: StyleSheet.hairlineWidth,
    // 与吧页 TweetCard 一致：多图 X 式图片带越出内容列时以卡片圆角为界
    // 裁切（吧页信息流同款边缘隐藏）
    overflow: 'hidden',
  },

  // Author row — avatar + name/badges/meta … more
  authorRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 8,
    marginBottom: 12,
  },
  authorGroup: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    flexShrink: 1,
  },
  authorInfo: {
    flexShrink: 1,
    gap: 3,
  },
  nameRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
  },
  name: {
    ...typographyStyles.subheadBold,
    flexShrink: 1,
  },
  levelBadge: {
    paddingHorizontal: 5,
    paddingVertical: 1,
    borderRadius: 4,
    borderCurve: 'continuous',
  },
  levelBadgeText: {
    ...typographyStyles.caption2,
    fontWeight: '700',
    lineHeight: 14,
  },
  lzTag: {
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderRadius: 4,
    borderCurve: 'continuous',
  },
  lzTagText: {
    ...typographyStyles.caption2Bold,
  },
  authorMeta: {
    ...typographyStyles.caption1,
  },

  // Sub-post section (楼中楼) — 无卡片，hairline 横线分隔，文字严格限高
  subPostSection: {
    marginTop: 10,
    borderTopWidth: StyleSheet.hairlineWidth,
    paddingTop: 10,
  },
  subPostDivider: {
    height: StyleSheet.hairlineWidth,
    marginVertical: 8,
  },
  subPostRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: 6,
  },
  subPostName: {
    ...typographyStyles.subheadBold,
    flexShrink: 0,
  },
  // 引用根容器：占满 subPostRow 剩余宽度，内部文本才能正常换行
  subQuoteRoot: {
    flex: 1,
    flexShrink: 1,
  },
  quoteInlineText: {
    ...typographyStyles.subhead,
    flexShrink: 1,
  },
  // 隐藏测量文本：仅用于 onTextLayout 读真实行数，不参与排版
  quoteMeasure: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    opacity: 0,
  },
  // 折叠态行尾内联后缀「… 更多」（与正文同字号，加粗以示可点）
  readMoreInline: {
    fontSize: 15,
    fontWeight: '600',
  },
  quoteInlineFlow: {
    flex: 1,
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'flex-start',
  },
  quoteEmoticon: {
    width: 20,
    height: 20,
    marginHorizontal: 1,
  },
  // 楼中楼图片：横向滑动缩略图条
  quoteImageStrip: {
    flexDirection: 'row',
    gap: 6,
    paddingTop: 6,
    alignItems: 'flex-start',
  },
  quoteImageThumb: {
    borderRadius: Radius.input - 2,
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  quoteImageThumbImg: {
    width: '100%',
    height: '100%',
  },
  quoteMore: {
    ...typographyStyles.footnoteBold,
    marginTop: 8,
  },

  // 右侧操作组：三点菜单 + 点赞 同行（不单独占行）
  authorActions: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    marginLeft: 8,
  },

  // Like button (top-right, plain heart)
  likeBtn: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    paddingHorizontal: 4,
    paddingVertical: 2,
  },
  likeCount: {
    ...typographyStyles.caption1,
    fontWeight: '500',
  },
});
