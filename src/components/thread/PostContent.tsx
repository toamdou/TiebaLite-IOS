/**
 * PostContent Renderer
 * Renders tieba post content: text, emoji, images, video, audio, links, @mentions, topics.
 * Migrated from PbContentRender.kt
 *
 * Layout strategy (iOS 26 card style):
 *  1. All inline segments (text / emoji / emoticon / @ / topic / link / linebreak)
 *     flow together in one wrapping text block — rendered FIRST.
 *  2. Block-level media (video / audio) render below the text.
 *  3. ALL images are extracted from the content array and rendered as a single
 *     grid block at the bottom — images always sit on their own lines,
 *     never inline after text.
 *
 * 第二轮拆分后模块职责：
 *  - 本文件 = 布局组合层 + block 媒体装配（video/audio） + 图片抽取
 *  - run 装配（表情文本拆包 + 内容屏蔽过滤 + topic 字重）→ utils/richTextRuns.ts
 *    canonical（contentToRichTextRuns），subposts 页同源
 *  - 图片块（ImageSegment）→ ./PostImages.tsx；视频块 → ./PostVideo.tsx
 *  - 样式 → ./postContentStyles.ts
 *  - PollSegment 已删除：全仓 grep 无 poll producer（mapProtoContent 不产出
 *    poll 段；贴吧端无投票写 API，旧交互 UI 为死代码）
 */

import React, { useMemo } from 'react';
import { View, useWindowDimensions } from 'react-native';
import { Text } from '../ui/CompatText';
import { useRouter } from 'expo-router';
import { SymbolView } from '@/components/ui/SymbolView';
import { AudioSegment } from './AudioSegment';
import { openLink } from '@/utils/linkOpener';
import { useThemeColors } from '@/theme/ThemeContext';
import { useAppPreference } from '@/hooks/useAppPreference';
import { useBlockFilter } from '@/hooks/useBlockFilter';
import { useAuthStore } from '@/stores/authStore';
import { contentToRichTextRuns } from '@/utils/richTextRuns';
import { resolveWatermarkText } from '@/utils/watermark';
import { TiebaRichText } from '../../../modules/tieba-native/src/TiebaRichText';
import { ImageSegment, type ImagePressHandler } from './PostImages';
import { VideoSegment } from './PostVideo';
import { styles } from './postContentStyles';
import type { PostContent as PostContentType } from '@/types';

/**
 * 帖内内容列相对屏幕宽的水平缩进：
 * PostCard 卡壳 marginHorizontal 10×2 + 卡内 padding 16×2 = 52。
 * （旧值 64 多算了 12pt 不存在的外缘，与真实卡片几何对齐后收窄。）
 * 注意 MediaPager 的 viewportWidth / leadInset 不在此列——由 ImageSegment
 * 另行计算，leadInset 保持「卡片内 padding」语义 = 16。
 */
const CONTENT_HORIZONTAL_INSET = 52;

// ---------- Props ----------

interface PostContentProps {
  content: PostContentType[];
  forumName?: string;
  /** 大图查看器顶栏标题：帖子图片=帖子标题；回复图片=回复内容前 30 字 */
  contextTitle?: string | null;
  onImagePress?: ImagePressHandler;
  /** 揭示移位的行 key（PostCard 传 post.id；图片块与横滑带移位共用） */
  revealKey?: string | number;
  onLinkPress?: (url: string) => void;
  onUserPress?: (uid: string) => void;
  onTopicPress?: (topicId: string, topicName: string) => void;
}

// ---------- Main Renderer ----------

/**
 * Renders an array of PostContent segments into a rich text view.
 * Text-level segments flow together first; images are extracted from
 * the whole array and rendered as one grid block below the text.
 */
function PostContent({
  content,
  forumName,
  contextTitle,
  revealKey,
  onImagePress,
  onLinkPress,
  onUserPress,
  onTopicPress,
}: PostContentProps) {
  const router = useRouter();
  const { colors, isDark } = useThemeColors();
  const hideMedia = useAppPreference('hideMedia', false);
  const blockVideo = useAppPreference('blockVideo', false);
  const hideBlockedContent = useAppPreference('hideBlockedContent', false);
  // 阅读字号：显示设置 -fontScale 倍率，作用于正文 / 引用 / @ / 话题。
  // 注：`?? 1` 为类型收窄所需——useAppPreference 签名返回 `T | undefined`，
  // 运行时经 store selector 缺省已兜底（第二轮扫描曾误判冗余，实码为准保留）。
  const fontScale = useAppPreference('fontScale', 1.0) ?? 1;
  const { isContentBlocked } = useBlockFilter();
  const imageDarkenWhenNight = useAppPreference('imageDarkenWhenNight', false);
  const dimImages = isDark && imageDarkenWhenNight;
  const imageWatermarkEnabled = useAppPreference('imageWatermarkEnabled', false);
  const imageWatermark = useAppPreference('imageWatermark', 'none');
  const account = useAuthStore((s) => s.account);
  const watermarkText = imageWatermarkEnabled
    ? resolveWatermarkText(imageWatermark ?? 'none', account?.name, forumName)
    : '';

  // Stable cell sizing: derive the content width from the window and the
  // fixed card/list insets instead of re-measuring on every layout pass.
  const { width: screenWidth } = useWindowDimensions();
  const contentWidth = Math.max(0, screenWidth - CONTENT_HORIZONTAL_INSET);

  // ── 段拆分：canonical run 装配 + block 媒体 + 图片抽取 ──
  const { inlineRuns, blockTips, blockNodes, extractedImages } = useMemo(() => {
    const blockTips: React.ReactNode[] = [];
    const blockNodes: React.ReactNode[] = [];
    const extractedImages: {
      src: string;
      width: number;
      height: number;
      originSrc?: string;
      isLongPic?: boolean;
      showOriginalBtn?: boolean;
      isGif?: boolean;
    }[] = [];
    let blockedKey = 0;

    // BlockTip — matches Kotlin Block.kt BlockTip composable
    // textSecondary 是 rgba() 字符串，不能直接拼 alpha 后缀（会得非法色值），
    // 底色统一走 colors.groupFill（与 ThreadMoreSheet groupBg 同源）。
    const renderBlockTip = (k: number) => (
      <View key={`blocked-${k}`} style={[styles.blockTip, { backgroundColor: colors.groupFill }]}>
        <SymbolView name="eye.slash" size={12} tintColor={colors.textSecondary} />
        <Text style={[styles.blockTipText, { color: colors.textSecondary }]}>内容已屏蔽</Text>
      </View>
    );

    // 文本级段 → canonical 装配（表情文本拆包 + 屏蔽过滤在 richTextRuns.ts 内）。
    // 屏蔽命中经 onBlocked 回调产出「内容已屏蔽」提示条；hideBlockedContent 开时
    // 静默过滤（Kotlin BlockManager 同语义）。
    // 注：表情拆包缓存已随 canonical 收敛删除——拆包是纯函数（只依赖段文本），
    // 且本 memo 以 `content` 为 key，无重复计算窗口。
    const inlineRuns = contentToRichTextRuns(content, {
      splitEmoticonText: true,
      fontWeight: '500',
      isBlocked: (segment) => isContentBlocked(segment),
      onBlocked: () => {
        if (!hideBlockedContent) {
          const k = blockedKey;
          blockedKey += 1;
          blockTips.push(renderBlockTip(k));
        }
      },
    });

    // Block 级段 → 媒体块 / 图片抽取（key 用段下标，显式、无自增副作用）
    content.forEach((segment, segIndex) => {
      switch (segment.type) {
        case 'image':
          // Extracted — rendered as one grid block after all text content
          extractedImages.push({
            src: segment.src,
            width: segment.width,
            height: segment.height,
            originSrc: segment.originSrc,
            // 服务端长图 / 查看原图标记：PostContent 类型未声明，mapProtoContent
            // 在运行时装配（Kotlin Media.is_long_pic / show_original_btn）。
            // smallSrc 已删：mapProtoContent 从不产出（见第二轮扫描）。
            isLongPic: (segment as { isLongPic?: boolean }).isLongPic,
            showOriginalBtn: (segment as { showOriginalBtn?: boolean }).showOriginalBtn,
            isGif: (segment as { isGif?: boolean }).isGif,
          });
          break;

        case 'video':
          if (hideMedia) {
            blockNodes.push(
              <View key={`video-${segIndex}`} style={[styles.mediaPlaceholder, { backgroundColor: colors.chip, borderColor: colors.divider }]}>
                <SymbolView name="video" size={14} tintColor={colors.textSecondary} />
                <Text style={[styles.mediaPlaceholderText, { color: colors.textSecondary }]}>[视频]</Text>
              </View>
            );
          } else if (blockVideo) {
            blockNodes.push(
              <View key={`video-${segIndex}`} style={[styles.mediaPlaceholder, { backgroundColor: colors.chip, borderColor: colors.divider }]}>
                <SymbolView name="video.slash" size={14} tintColor={colors.textSecondary} />
                <Text style={[styles.mediaPlaceholderText, { color: colors.textSecondary }]}>[视频已屏蔽]</Text>
              </View>
            );
          } else {
            blockNodes.push(
              <VideoSegment
                key={`video-${segIndex}`}
                src={segment.src}
                poster={segment.poster}
                width={segment.width}
                height={segment.height}
                contentWidth={contentWidth}
              />
            );
          }
          break;

        case 'audio':
          // Kotlin PbContentRender 对照：音频段不受 hideMedia / blockVideo
          // 门控（两开关语义只针对图片/视频流量），照常渲染 AudioSegment。
          blockNodes.push(
            <AudioSegment
              key={`audio-${segIndex}`}
              src={segment.src}
              duration={segment.duration}
            />
          );
          break;

        // poll 已删：全仓无 producer + 无投票写 API（第二轮扫描确认）
      }
    });

    return { inlineRuns, blockTips, blockNodes, extractedImages };
  }, [content, colors, hideMedia, blockVideo, hideBlockedContent, isContentBlocked, contentWidth]);

  // 兜底：content 缺省 / 全空 → 内容已删除占位。实际调用方（PostCard /
  // 主楼）都会传非空数组并先做长度判断，此分支恒不触发（保留防御）。
  if (!content || content.length === 0) {
    return (
      <Text style={[styles.emptyText, { color: colors.textDisabled }]}>
        [内容已删除]
      </Text>
    );
  }

  const hasTextBlock = inlineRuns.length > 0 || blockTips.length > 0;
  const hasPrecedingContent = hasTextBlock || blockNodes.length > 0;
  const hasImages = extractedImages.length > 0;
  const totalNodes = inlineRuns.length + blockTips.length + blockNodes.length + extractedImages.length;

  return (
    <View style={styles.container}>
      {totalNodes === 0 ? (
        <Text style={[styles.emptyText, { color: colors.textDisabled }]}>
          [内容已删除]
        </Text>
      ) : (
        <>
          {/* 1 — Text content flows first (emoticons stay inline) */}
          {hasTextBlock && (
            <View style={styles.textFlow}>
              {blockTips}
              {inlineRuns.length > 0 && (
                <TiebaRichText
                  runs={inlineRuns}
                  contentWidth={contentWidth}
                  fontSize={15 * fontScale}
                  lineHeight={22 * fontScale}
                  textColor={colors.text}
                  linkColor={colors.primary}
                  onLinkPress={(url) => {
                    if (onLinkPress) onLinkPress(url);
                    else openLink(url);
                  }}
                  onUserPress={(uid) => {
                    if (onUserPress) onUserPress(uid);
                    else router.push(`/user/${uid}`);
                  }}
                  onTopicPress={(topicId, topicName) => {
                    if (onTopicPress) onTopicPress(topicId, topicName);
                    else router.push(`/topic/${topicId}?name=${encodeURIComponent(topicName)}`);
                  }}
                />
              )}
            </View>
          )}

          {/* 2 — Block-level media (video / audio) */}
          {blockNodes}

          {/* 3 — ALL images on their own lines, below the text */}
          {hasImages &&
            (hideMedia ? (
              <View style={[styles.imageBlock, hasPrecedingContent && styles.imageBlockSpaced]}>
                {extractedImages.map((_img, i) => (
                  <View
                    key={`img-ph-${i}`}
                    style={[
                      styles.mediaPlaceholder,
                      { backgroundColor: colors.chip, borderColor: colors.divider, marginTop: 0 },
                    ]}
                  >
                    <SymbolView name="photo" size={14} tintColor={colors.textSecondary} />
                    <Text style={[styles.mediaPlaceholderText, { color: colors.textSecondary }]}>[图片]</Text>
                  </View>
                ))}
              </View>
            ) : (
              <ImageSegment
                images={extractedImages}
                contentWidth={contentWidth}
                watermarkText={watermarkText}
                forumName={forumName}
                contextTitle={contextTitle}
                revealKey={revealKey}
                onPress={onImagePress}
                dimmed={dimImages}
                style={hasPrecedingContent ? styles.imageBlockSpaced : undefined}
              />
            ))}
        </>
      )}
    </View>
  );
}

// Memoized so parent re-renders (e.g. list recycling, theme-independent state
// changes) don't force a full re-render when the content prop is unchanged.
export default React.memo(PostContent);