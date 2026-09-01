/**
 * Thread Header（帖子详情页头部）— ForumAvatarWithHdr + ThreadHeader（memo）。
 *
 * memoized 保证 loadMore 分页永不重建主贴卡 + 回复工具栏：props 只依赖
 * thread 数据（+ 稳定钉住的主贴引用），不依赖整个 posts 数组。
 * 拆自 src/app/thread/[id].tsx（4 抽 1 留拆分，#8）。
 */

import { memo } from 'react';
import { Pressable, StyleSheet, View } from 'react-native';
import { Text } from '../ui/CompatText';
import { Link, router } from 'expo-router';

import { Avatar } from '@/components/ui/Avatar';
import { HdrPressable } from '@/components/ui/HdrPressable';
import PostContent from '@/components/thread/PostContent';
import type { ImagePressHandler } from '@/components/thread/PostImages';
import { hapticForScene } from '@/theme/hapticsMap';
import {RadiusStyle} from '@/theme';
import { formatCount } from '@/utils';
import { useTimeLabel } from '@/hooks/useTimeLabel';
import { suppressNavDoubleTap } from '@/hooks/useNavDoubleTapToTop';
import { useAppPreference } from '@/hooks/useAppPreference';
import type { SemanticColors } from '@/theme/colors';
import type { PostInfo, ThreadInfo } from '@/types';

/**
 * 吧头像（headerRight）带 App Store 风格 HDR 高光：按下瞬间白色斜向扫光
 * + 整体增亮 + 外扩光晕（HdrPressable 统一效果；亮度峰值扫光 1.0 / 白闪 0.85，
 * 光晕超出按钮 10pt）。导航逻辑不变——仍由 onPress 进入吧页（不用 Link
 * asChild：asChild 注入 onPress 与 onPressIn 的 sweep 手势冲突，会导致点击
 * 无响应 / 不导航）。reduceMotion 时只做静态白闪。
 */
function ForumAvatarWithHdr({
  forumName,
  forumAvatar,
}: {
  forumName?: string;
  forumAvatar?: string;
}) {
  const handlePress = () => {
    hapticForScene('press');
    // 先抑制导航栏双击回顶（原生栏手势覆盖 headerRight）：快速二连击
    // 会被识别成"双击回顶"，旧页 push 动画中回顶照播 → 观感"先回顶再进吧"
    suppressNavDoubleTap();
    router.push({
      pathname: '/forum/[name]',
      params: { name: forumName || '' },
    });
  };

  return (
    <HdrPressable
      effect="hdr"
      style={styles.forumAvatarBtn}
      flashRadius={15}
      glowOutset={10}
      onPress={handlePress}
      accessibilityRole="button"
      accessibilityLabel={`进入${forumName || ''}吧`}
    >
      <Avatar
        source={forumAvatar || undefined}
        initials={(forumName || '吧')?.charAt(0)}
        size={28}
      />
    </HdrPressable>
  );
}

// ────────────────────────────────────────────────────────────

interface ThreadHeaderProps {
  thread: ThreadInfo | null;
  /** 独立钉住的主贴引用（posts[0] 快照；loadMore 驱逐不影响） */
  mainPost: PostInfo | null;
  seeLz: boolean;
  reverse: boolean;
  colors: SemanticColors;
  pageLabel?: string;
  onToggleSeeLz: () => void;
  onToggleSort: () => void;
  onImagePress: ImagePressHandler;
}

const ThreadHeader = memo(function ThreadHeader({
  thread,
  mainPost,
  seeLz,
  reverse,
  colors,
  pageLabel,
  onToggleSeeLz,
  onToggleSort,
  onImagePress,
}: ThreadHeaderProps) {
  // hooks 须在早退 return 之前挂载
  const timeLabel = useTimeLabel();
  const showIpLocation = useAppPreference('showIpLocation', true);
  if (!thread) return null;
  const replyCount = thread.replyNum ?? 0;

  return (
    <View>
      {/* ── Main Post (OP) — visually distinct glass card section ── */}
      {/* ⚠️ 不用 GlassSurface：其 onPress 注册为 bubbling 事件，与内部 Pressable
          的 onPress（direct）冲突 → "Event cannot be both direct and bubbling:
          topPress"，整页崩溃。改用 RN View 模拟玻璃卡片。 */}
      <View
        style={[
          styles.mainPostSection,
          styles.glassCard,
          {
            marginHorizontal: 10,
            marginBottom: 8,
            padding: 16,
            // 与回复楼层卡片同款白卡（原来用 surfaceSecondary 灰底，
            // 在浅色背景下与背景几乎分不开，视觉上像"没有卡片包裹"）
            backgroundColor: colors.card,
            borderColor: colors.borderCard,
          },
        ]}
      >
        {/* Author row */}
        <Link href={{ pathname: '/user/[uid]', params: { uid: thread.authorId } }} push asChild>
          <Pressable style={styles.authorRow}>
            <Avatar
              source={thread.authorPortrait}
              initials={thread.authorNameShow?.slice(0, 2) || thread.authorName?.slice(0, 2)}
              size={40}
              level={thread.authorLevelId > 0 ? thread.authorLevelId : undefined}
            />
            <View style={styles.authorInfo}>
              <View style={styles.authorNameRow}>
                <Text style={[styles.authorDisplayName, { color: colors.text }]} numberOfLines={1}>
                  {thread.authorNameShow || thread.authorName}
                </Text>
                {showIpLocation && mainPost?.ipLocation ? (
                  <Text style={[styles.authorIpText, { color: colors.textTertiary }]} numberOfLines={1}>
                    来自{mainPost.ipLocation}
                  </Text>
                ) : null}
                <View style={[styles.lzBadge, { backgroundColor: colors.primary + '18' }]}>
                  <Text style={[styles.lzBadgeText, { color: colors.primary }]}>楼主</Text>
                </View>
              </View>
              <Text style={[styles.authorMeta, { color: colors.textTertiary }]}>
                {timeLabel(thread.createTime)}
              </Text>
            </View>
          </Pressable>
        </Link>

        {/* Main post content */}
        {mainPost && mainPost.content.length > 0 && (
          <View style={styles.mainPostContent}>
            <PostContent
              content={mainPost.content}
              forumName={thread?.forumName}
              contextTitle={thread?.title}
              onImagePress={onImagePress}
            />
          </View>
        )}
      </View>

      {/* ── Reply Toolbar (below main post) ── */}
      <View
        style={[
          styles.replyToolbar,
          styles.glassCard,
          {
            marginHorizontal: 10,
            marginBottom: 8,
            backgroundColor: colors.surfaceSecondary,
            borderColor: colors.borderCard,
          },
        ]}
      >
        <Text style={[styles.replyCount, { color: colors.text }]}>
          回复 {formatCount(replyCount)}
          {pageLabel ? (
            <Text style={[styles.replyPageLabel, { color: colors.textTertiary }]}> · {pageLabel}</Text>
          ) : null}
        </Text>
        <View style={styles.replyToolbarRight}>
          <Pressable
            onPress={onToggleSeeLz}
            style={({ pressed }) => [
              styles.seeLzPill,
              {
                backgroundColor: seeLz ? colors.primary : colors.surfaceSecondary,
                opacity: pressed ? 0.8 : 1,
                transform: [{ scale: pressed ? 0.95 : 1 }],
              },
            ]}
          >
            <Text style={[styles.seeLzPillText, { color: seeLz ? colors.textOnPrimary : colors.textSecondary }]}>
              只看楼主
            </Text>
          </Pressable>
          <Pressable
            onPress={onToggleSort}
            style={({ pressed }) => [
              styles.sortPill,
              {
                backgroundColor: reverse ? colors.primary : colors.surfaceSecondary,
                opacity: pressed ? 0.8 : 1,
                transform: [{ scale: pressed ? 0.95 : 1 }],
              },
            ]}
          >
            <Text style={[styles.sortPillText, { color: reverse ? colors.textOnPrimary : colors.textSecondary }]}>
              {reverse ? '倒序' : '正序'}
            </Text>
          </Pressable>
        </View>
      </View>
    </View>
  );
});

export { ForumAvatarWithHdr, ThreadHeader };
export type { ThreadHeaderProps };

// ────────────────────────────────────────────────────────────
// Styles
// ────────────────────────────────────────────────────────────

// 模拟玻璃卡片（替代 GlassSurface：onPress 事件与内部 Pressable 冲突会整页崩溃）
const styles = StyleSheet.create({
  glassCard: {
    ...RadiusStyle.card,
    borderWidth: StyleSheet.hairlineWidth,
    overflow: 'hidden',
  },

  mainPostSection: {
    paddingBottom: 12,
    paddingHorizontal: 16,
  },
  mainPostContent: {
    marginTop: 12,
  },

  authorRow: {
    flexDirection: 'row', alignItems: 'center', gap: 10,
    paddingVertical: 4,
  },
  authorInfo: { flex: 1, gap: 2 },
  authorNameRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  authorDisplayName: { fontSize: 16, fontWeight: '600', flexShrink: 1 },
  lzBadge: {
    paddingHorizontal: 6, paddingVertical: 2, borderRadius: 4,
  },
  lzBadgeText: { fontSize: 11, fontWeight: '700', lineHeight: 15 },
  authorMeta: { fontSize: 13, fontWeight: '400' },
  authorIpText: { fontSize: 12, fontWeight: '400' },

  // ── Reply toolbar ──
  replyToolbar: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    paddingVertical: 12, paddingHorizontal: 16,
  },
  replyCount: { fontSize: 16, fontWeight: '700' },
  replyPageLabel: { fontSize: 13, fontWeight: '500' },
  replyToolbarRight: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  seeLzPill: {
    paddingHorizontal: 14, paddingVertical: 7,
    borderRadius: 16,
    borderCurve: 'continuous',
  },
  seeLzPillText: { fontSize: 13, fontWeight: '600' },
  sortPill: {
    paddingHorizontal: 14, paddingVertical: 7,
    borderRadius: 16,
    borderCurve: 'continuous',
  },
  sortPillText: { fontSize: 13, fontWeight: '600' },

  // ── Forum avatar (header right) ──
  // 注意：不能 overflow:'hidden'（光晕需外扩 10pt；头像图片由 Avatar 自裁圆角）
  forumAvatarBtn: {
    width: 30,
    height: 30,
    borderRadius: 15,
    borderCurve: 'continuous',
  },
});