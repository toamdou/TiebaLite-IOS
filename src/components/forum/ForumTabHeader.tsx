/**
 * 吧页顶部固定区：吧名片 + 置顶帖（从 app/forum/[name].tsx 的 buildTabHeader
 * 改造为组件拆出）。关注/签到按钮、头像预览、吧详情跳转由页面经回调注入。
 */

import React from 'react';
import { View, StyleSheet, Pressable } from 'react-native';
import { Text } from '../ui/CompatText';

import { Avatar } from '@/components/ui/Avatar';
import { HdrPressable } from '@/components/ui/HdrPressable';
import TweetCard from '@/components/feed/TweetCard';
import {Spacing, RadiusStyle, Radius} from '@/theme';
import { typographyStyles } from '@/theme/typography';
import type { ThreadInfo } from '@/types';

export interface ForumTabHeaderProps {
  name: string;
  colors: any;
  currentForum: any;
  topThreads: ThreadInfo[];
  followBtnLabel: string;
  followBtnActive: boolean | undefined;
  isLoggedIn: boolean;
  onAvatarPreview: (event: any) => void;
  onFollowOrSign: () => void;
  onForumDetail: () => void;
}

export const ForumTabHeader = React.memo(function ForumTabHeader({
  name,
  colors,
  currentForum,
  topThreads,
  followBtnLabel,
  followBtnActive,
  isLoggedIn,
  onAvatarPreview,
  onFollowOrSign,
  onForumDetail,
}: ForumTabHeaderProps) {
  return (
    <View style={styles.headerSection}>
      {/* 无阴影：0.03 软阴影肉眼不可辨，分层由发丝边框 + 卡片/背景色差承担 */}
      <View style={[styles.forumCard, { backgroundColor: colors.card }]}>
        <View style={styles.forumInfoRow}>
          {/* 吧头像 + 名称 (tappable → 吧详情) */}
          <Pressable style={styles.forumInfoPressable} onPress={onForumDetail} accessibilityRole="button">
            {/* 吧头像 */}
            <View>
              <Avatar
                source={currentForum?.avatar || undefined}
                initials={(currentForum?.forumName || name)?.charAt(0)}
                size={72}
                onPress={onAvatarPreview}
              />
            </View>
            <View style={styles.forumTextCol}>
              <Text style={[styles.forumTitle, { color: colors.text }]}>{name}吧</Text>
              {isLoggedIn && currentForum?.isLike && currentForum.levelId != null && currentForum.levelId > 0 && (
                <View style={styles.forumLevelRow}>
                  <View style={[styles.levelBadgeSmall, { backgroundColor: `${colors.primary}26` }]}>
                    <Text style={[styles.levelBadgeSmallText, { color: colors.primary }]}>Lv.{currentForum.levelId}</Text>
                  </View>
                  {currentForum.levelName ? (
                    <Text style={[styles.forumLevelName, { color: colors.textTertiary }]} numberOfLines={1}>
                      {currentForum.levelName}
                    </Text>
                  ) : null}
                </View>
              )}
            </View>
          </Pressable>
          {/* 关注/签到按钮（HDR 高光） */}
          <HdrPressable
            onPress={onFollowOrSign}
            style={[
              styles.followBtn,
              {
                backgroundColor: followBtnActive
                  ? currentForum?.signInInfo?.isSignIn
                    ? colors.surfaceSecondary
                    : colors.primary
                  : colors.primary,
              },
            ]}
            flashRadius={14}
          >
            <Text
              style={[
                styles.followBtnText,
                {
                  color: followBtnActive && currentForum?.signInInfo?.isSignIn
                    ? colors.text
                    : colors.textOnPrimary,
                },
              ]}
            >
              {followBtnLabel}
            </Text>
          </HdrPressable>
        </View>

        {isLoggedIn && currentForum?.isLike && currentForum.levelId != null && currentForum.levelId > 0 && (
          <View style={styles.levelSection}>
            <View style={[styles.levelTrack, { backgroundColor: colors.surfaceSecondary }]}>
              <View
                style={[
                  styles.levelFill,
                  {
                    width: `${
                      currentForum.levelupScore && currentForum.levelupScore > 0
                        ? Math.min(((currentForum.curScore ?? 0) / currentForum.levelupScore) * 100, 100)
                        : 0
                    }%`,
                    backgroundColor: colors.primary,
                  },
                ]}
              />
            </View>
            {currentForum.levelupScore && currentForum.levelupScore > 0 && (
              <Text style={[styles.levelScoreText, { color: colors.textTertiary }]}>
                {Math.min(currentForum.curScore ?? 0, currentForum.levelupScore)}/{currentForum.levelupScore}
              </Text>
            )}
          </View>
        )}
      </View>

      {/* ── 置顶帖：置于「热门|最新|精品」栏之前（TweetCard 对置顶帖渲染横幅） ── */}
      {topThreads.length > 0 && (
        <View style={styles.topSection}>
          {topThreads.map((top) => (
            <TweetCard key={top.id} thread={top} timeType="last" />
          ))}
        </View>
      )}
    </View>
  );
});

const styles = StyleSheet.create({
  headerSection: { paddingTop: 0 },
  topSection: { paddingTop: 0 },
  forumCard: {
    padding: Spacing.xl,
    marginHorizontal: Spacing.lg,
    marginBottom: Spacing.xs,
    ...RadiusStyle.card,
    overflow: 'hidden',
  },
  forumInfoRow: { flexDirection: 'row', alignItems: 'center' },
  forumInfoPressable: { flexDirection: 'row', alignItems: 'center', flex: 1 },
  forumTextCol: { flex: 1, marginLeft: Spacing.lg },
  forumTitle: { fontSize: 20, fontWeight: '700', letterSpacing: 0, marginBottom: Spacing.xs },
  forumLevelRow: { flexDirection: 'row', alignItems: 'center', gap: 6, marginTop: 2 },
  levelBadgeSmall: { paddingHorizontal: 6, paddingVertical: 2, borderRadius: 5 },
  levelBadgeSmallText: { ...typographyStyles.caption2, fontWeight: '800' },
  forumLevelName: { ...typographyStyles.caption1, fontWeight: '500', flexShrink: 1 },
  followBtn: {
    paddingHorizontal: Spacing.xl,
    paddingVertical: 10,
    borderRadius: Radius.capsule,
  },
  followBtnText: { ...typographyStyles.footnote, fontWeight: '700' },
  levelSection: { marginTop: 14, flexDirection: 'row', alignItems: 'center', gap: 10 },
  levelTrack: { height: 6, borderRadius: 3, overflow: 'hidden', flex: 1 },
  levelFill: { height: 6, borderRadius: 3 },
  levelScoreText: { ...typographyStyles.caption2, fontWeight: '600', fontVariant: ['tabular-nums'] },
});
