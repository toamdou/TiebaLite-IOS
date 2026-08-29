/**
 * CompactFeedRow — 帖信息流紧凑行（浏览历史 / 我的收藏 / 搜索帖子结果共用）
 *
 * 视觉对齐 TweetCard（X/Twitter timeline 风格）：圆角卡 + 44pt 圆头像 +
 * 头部「名 · 时间」行 + 缩进内容列（标题粗体/摘要次要）+ 底部 meta 行。
 *
 * 告别旧「图标色块 + 三层文案 + 竖直居中菜单」的九宫格错位卡：
 * - 头像固定 44pt 圆形，与名字行顶端对齐（同 TweetCard AVATAR/缩进常量）；
 * - 内容列统一缩进 CONTENT_INDENT（54pt），标题/摘要/meta 与头像左缘对齐；
 * - 删除等菜单钮是卡内右上角独立兄弟节点（同 TweetCard 的右上 ×/… 位置），
 *   不嵌套在整卡 Pressable 内 → 点菜单不会触发整卡导航，也不再垂直居中错位。
 *
 * 媒体支持（可选）：传入 images 时在摘要与 meta 之间渲染一行小缩略图
 * （80pt 方形、Radius.image 圆角，expo-image cover 裁切，最多 4 张）。
 * 缩略图点击经 onImagePress(images, index) 回调交给调用方打开大图查看器；
 * 不传 images 时不渲染任何媒体区（浏览历史保持纯文字）。
 */

import React from 'react';
import { View, Pressable, StyleSheet } from 'react-native';
import { Text } from '../ui/CompatText';
import { Image } from 'expo-image';
import { Avatar } from '@/components/ui/Avatar';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { useThemeColors } from '@/theme/ThemeContext';
import {RadiusStyle, Radius} from '@/theme/spacing';
import { typographyStyles } from '@/theme/typography';
import { thumbnailUrl, THUMB_POST } from '@/utils/thumbnail';
import { isImageWarm, markImageWarm } from '@/utils/imageWarm';
import { frameFromPressEvent, type ImageSourceFrame } from '@/hooks/useImageViewer';
import { stopPropagation } from '@/utils/gesture';
import { hapticForScene } from '@/theme/hapticsMap';

// ── 设计常量（与 TweetCard 头部/缩进保持一致） ──
const AVATAR_SIZE = 44;
const AVATAR_GAP = 10;
/** 内容列缩进：与名字列对齐（推特 timeline 布局） */
const CONTENT_INDENT = AVATAR_SIZE + AVATAR_GAP;
const CARD_RADIUS = Radius.card;
/** 缩略图边长：小内联图（72~90pt 区间取 80） */
const MEDIA_THUMB_SIZE = 80;
/** 最多展示的缩略图数量（超出省略，保持卡片紧凑） */
const MEDIA_THUMB_MAX = 4;

export interface CompactFeedRowProps {
  /** 粗体主名（作者 / 吧名） */
  displayName: string;
  /** 头部行内时间文案（如「3 小时前」，可选） */
  headerTime?: string;
  /** 头像图片（缺省回落首字色块） */
  avatarSource?: string | null;
  avatarInitial: string;
  /** 正文标题（粗体，最多 2 行） */
  title?: string;
  /** 正文摘要（次要色，最多 2 行） */
  abstract?: string;
  /** 可选缩略图 URL 列表（如收藏贴配图）；缺省不渲染媒体区 */
  images?: string[];
  /** 点击缩略图回调（供调用方打开大图查看器）；不传则缩略图不可点 */
  onImagePress?: (
    images: string[],
    index: number,
    sourceFrame?: ImageSourceFrame | null,
  ) => void;
  /** 底部 meta 行内容（吧名入口 / 楼层 / 回复数等，由调用方组装） */
  meta?: React.ReactNode;
  /** 头部名字行内、用户名右侧的挂件（吧名药丸等小标签） */
  headerPill?: React.ReactNode;
  /** 头部右上角挂件（删除/更多菜单按钮，独立于整卡按压） */
  headerAccessory?: React.ReactNode;
  onPress: () => void;
}

export function CompactFeedRow({
  displayName,
  headerTime,
  avatarSource,
  avatarInitial,
  title,
  abstract,
  images,
  onImagePress,
  meta,
  headerPill,
  headerAccessory,
  onPress,
}: CompactFeedRowProps) {
  const { colors, isDark } = useThemeColors();
  // 缩略图加载中的占位底色（对齐 TweetCard mediaWrap）
  const placeholderBg = isDark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.04)';
  const mediaList = images?.filter(Boolean) ?? [];

  return (
    <View style={styles.cardWrap}>
      <View
        style={[
          styles.card,
          {
            backgroundColor: colors.card,
            borderColor: colors.borderCard,
            // 无按压动画（用户反馈卡片按压效果太花里胡哨，搜索结果等卡片）；
            // 无阴影：0.03 软阴影肉眼不可辨却让每行触发 CA 离屏计算，
            // 分层由发丝边框 + 卡片/背景色差承担。
          },
        ]}
      >
        <HdrPressable
          onPress={() => {
            void hapticForScene('press');
            onPress();
          }}
          flashRadius={CARD_RADIUS}
          effect="subtle"
          accessibilityRole="button"
        >
          {/* ── 头部：头像 + 名 · 时间 ── */}
          <View style={styles.headerRow}>
            <Avatar source={avatarSource || undefined} initials={avatarInitial} size={AVATAR_SIZE} />
            <View style={[styles.nameCol, headerAccessory ? styles.nameColWithAccessory : undefined]}>
              <View style={styles.nameRow}>
                <Text style={[styles.displayName, { color: colors.text }]} numberOfLines={1}>
                  {displayName}
                </Text>
                {headerPill ? <View style={styles.namePillWrap}>{headerPill}</View> : null}
                {headerTime ? (
                  <Text style={[styles.time, { color: colors.textSecondary }]} numberOfLines={1}>
                    · {headerTime}
                  </Text>
                ) : null}
              </View>
            </View>
          </View>

          {/* ── 内容列（与名字列对齐 / 缩进） ── */}
          {title || abstract || meta || mediaList.length > 0 ? (
            <View style={styles.contentCol}>
              {title ? (
                <Text style={[styles.title, { color: colors.text }]} numberOfLines={2}>
                  {title}
                </Text>
              ) : null}
              {abstract ? (
                <Text style={[styles.abstract, { color: colors.textSecondary }]} numberOfLines={2}>
                  {abstract}
                </Text>
              ) : null}
              {/* ── 缩略图带（可选）：摘要与 meta 之间一行小图 ── */}
              {mediaList.length > 0 ? (
                <View style={styles.mediaStrip}>
                  {mediaList.slice(0, MEDIA_THUMB_MAX).map((uri, i) => {
                    const thumb = thumbnailUrl(uri, THUMB_POST);
                    const img = (
                      <Image
                        source={{ uri: thumb }}
                        style={[styles.mediaThumb, { backgroundColor: placeholderBg }]}
                        contentFit="cover"
                        cachePolicy="memory-disk"
                        transition={isImageWarm(thumb) ? 0 : 200}
                        onLoad={() => markImageWarm(thumb)}
                        recyclingKey={thumb}
                      />
                    );
                    // 未提供 onImagePress 时缩略图不可点（纯展示）
                    if (!onImagePress) {
                      return <View key={`${thumb}-${i}`} style={styles.mediaThumbWrap}>{img}</View>;
                    }
                    return (
                      <Pressable
                        key={`${thumb}-${i}`}
                        onPress={(e) =>
                        onImagePress(
                          mediaList,
                          i,
                          frameFromPressEvent(e, { width: MEDIA_THUMB_SIZE, height: MEDIA_THUMB_SIZE }),
                        )
                      }
                        onPressIn={stopPropagation}
                        onPressOut={stopPropagation}
                        accessibilityRole="imagebutton"
                        accessibilityLabel={`查看第${i + 1}张图片`}
                        style={styles.mediaThumbWrap}
                      >
                        {img}
                      </Pressable>
                    );
                  })}
                </View>
              ) : null}
              {meta ? <View style={styles.metaRow}>{meta}</View> : null}
            </View>
          ) : null}
        </HdrPressable>

        {/* ── 右上角挂件：独立兄弟节点，点它不触发整卡按压 ── */}
        {headerAccessory ? <View style={styles.accessorySlot}>{headerAccessory}</View> : null}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  cardWrap: {
    // 卡片距屏边统一 10pt（与 TweetCard/动态信息流一致）
    marginHorizontal: 10,
    marginVertical: 4,
  },
  card: {
    borderRadius: CARD_RADIUS,
    borderCurve: 'continuous',
    borderWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: 12,
    paddingTop: 12,
    paddingBottom: 8,
    overflow: 'hidden',
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
  // 头部有右上角挂件（绝对定位）时，给名字行预留按钮宽度，避免文字被按钮盖住
  nameColWithAccessory: {
    paddingRight: 28,
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
  // 头部药丸挂件：贴紧用户名右侧（不参与 flexShrink，用户名截断兜底）
  namePillWrap: {
    flexShrink: 0,
  },
  time: {
    ...typographyStyles.subhead,
    flexShrink: 1,
  },
  accessorySlot: {
    position: 'absolute',
    top: 6,
    right: 2,
  },
  // ── 内容列 ──
  contentCol: {
    marginLeft: CONTENT_INDENT,
    marginTop: 2,
    gap: 2,
  },
  title: {
    ...typographyStyles.headline,
    fontWeight: '700',
  },
  abstract: {
    ...typographyStyles.subhead,
    lineHeight: 21,
  },
  // ── 缩略图带 ──
  mediaStrip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    marginTop: 8,
  },
  mediaThumbWrap: {
    width: MEDIA_THUMB_SIZE,
    height: MEDIA_THUMB_SIZE,
    ...RadiusStyle.image,
    overflow: 'hidden',
  },
  mediaThumb: {
    width: MEDIA_THUMB_SIZE,
    height: MEDIA_THUMB_SIZE,
  },
  metaRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
    marginTop: 6,
  },
});

export default CompactFeedRow;
