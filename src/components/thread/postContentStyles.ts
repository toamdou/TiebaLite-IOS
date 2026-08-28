/**
 * postContentStyles — 帖内内容渲染共享样式表（第二轮拆分自 PostContent.tsx）
 *
 * PostContent（布局组合层）/ PostImages（图片块）/ PostVideo（视频块）共用。
 * 已随第二轮清理删除：PollSegment 全部样式、死样式键
 * paragraphText/emoji/emoticon/linebreak/linkWrapper/linkText/atText/topicText
 * /imagePagerWrap/pageBadge/pageBadgeText（run 级文本样式由原生 TiebaRichText
 * 负责，页面样式表早已无人引用）。
 */

import { StyleSheet } from 'react-native';
import {RadiusStyle, Radius} from '@/theme/spacing';

/** Gap between images in the extracted image grid */
const IMAGE_GAP = 8;
/** Corner radius for every image cell */
const IMAGE_RADIUS = Radius.input;

export const styles = StyleSheet.create({
  // ── PostContent.tsx 布局组合层 ──
  container: {
    flexDirection: 'column',
  },
  emptyText: {
    fontSize: 15,
    lineHeight: 22,
  },
  // Wrapping flow for text-level segments (text / emoji / emoticon / @ / link…)
  textFlow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'flex-start',
  },
  // Extracted image grid block — always below the text, never inline
  imageBlock: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: IMAGE_GAP,
  },
  imageBlockSpaced: {
    marginTop: 14,
  },
  mediaPlaceholder: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 12,
    paddingVertical: 8,
    ...RadiusStyle.chip,
    borderWidth: 1,
    marginTop: 10,
    gap: 6,
  },
  mediaPlaceholderText: {
    fontSize: 13,
  },
  blockTip: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 6,
    borderCurve: 'continuous',
    marginTop: 2,
    marginBottom: 2,
    gap: 6,
  },
  blockTipText: {
    fontSize: 12,
  },

  // ── PostImages.tsx 图片块 ──
  imageGrid: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: IMAGE_GAP,
  },
  /* 长图徽标：右下角深色胶囊（对齐 Kotlin 长图右下角标识） */
  longBadge: {
    position: 'absolute',
    right: 8,
    bottom: 8,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 3,
    paddingHorizontal: 7,
    paddingVertical: 3,
    borderRadius: 10,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(0,0,0,0.55)',
  },
  longBadgeText: {
    color: '#FFFFFF',
    fontSize: 11,
    fontWeight: '600',
  },
  imageWrapper: {
    borderRadius: IMAGE_RADIUS,
    borderCurve: 'continuous',
    overflow: 'hidden',
    position: 'relative',
  },
  image: {
    width: '100%',
    height: '100%',
  },
  imageOverlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: 'rgba(0,0,0,0.5)',
    justifyContent: 'center',
    alignItems: 'center',
  },
  imageOverlayText: {
    color: '#FFF',
    fontSize: 24,
    fontWeight: '700',
  },
  imagePlaceholder: {
    borderRadius: IMAGE_RADIUS,
    borderCurve: 'continuous',
    borderWidth: 1,
    justifyContent: 'center',
    alignItems: 'center',
    position: 'relative',
  },

  // ── PostVideo.tsx 视频块 ──
  videoWrapper: {
    borderRadius: IMAGE_RADIUS,
    borderCurve: 'continuous',
    overflow: 'hidden',
    marginTop: 10,
    position: 'relative',
  },
  videoPoster: {
    width: '100%',
    height: '100%',
  },
  videoPlayer: {
    width: '100%',
    height: '100%',
  },
  playButton: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    justifyContent: 'center',
    alignItems: 'center',
  },
  videoBadge: {
    position: 'absolute',
    bottom: 6,
    right: 6,
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.6)',
    paddingHorizontal: 6,
    paddingVertical: 2,
    borderRadius: 4,
    borderCurve: 'continuous',
    gap: 2,
  },
  videoBadgeText: {
    color: '#FFF',
    fontSize: 10,
    fontWeight: '600',
  },
  expandButton: {
    position: 'absolute',
    top: 6,
    right: 6,
    width: 28,
    height: 28,
    borderRadius: 14,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(0,0,0,0.5)',
    justifyContent: 'center',
    alignItems: 'center',
  },
});
