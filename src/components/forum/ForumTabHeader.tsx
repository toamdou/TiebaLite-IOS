/**
 * 吧页顶部固定区：Apple 大标题式头部 + 置顶帖。
 *
 * 2026-09-09 v3：图带封面废弃——吧头像多为带文字的方标（如 QUALCOMM），
 * 模糊放大后整带变成巨大糊字（真机截图实锤），纯色渐变/图带两条路线均被
 * 用户否决。回归 Apple 留白排版：56 圆角头像 + 大标题「xx吧」+ 合并 meta
 * 行（会员 · 帖子）+ 关注/签到按钮右侧一行解决；等级进度与简介随后铺开。
 * 颜色只出现在按钮与等级徽章，留白即设计。顶部让位由本头部承接
 * （insets.top + NAV_BAR_H + 12）。
 */

import React from 'react';
import { View, StyleSheet, Pressable } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Text } from '../ui/CompatText';
import { levelBadgeColor } from '@/constants/rank';

import { Avatar } from '@/components/ui/Avatar';
import TweetCard from '@/components/feed/TweetCard';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { Radius } from '@/theme';
import { typographyStyles } from '@/theme/typography';
import { formatCount } from '@/utils';
import { NAV_BAR_H } from '@/constants/layout';
import type { ThreadInfo } from '@/types';

export interface ForumTabHeaderProps {
  name: string;
  colors: any;
  currentForum: any;
  topThreads: ThreadInfo[];
  isLoggedIn: boolean;
  onAvatarPreview: (event: any) => void;
  /** 未关注态「关注」按钮：内部自带未登录拦截（页面 handleFollowOrSign） */
  onFollowPress: () => void;
  /** 已关注态「签到」按钮（页面 handleSign，自带登录/重复签到拦截） */
  onSignPress: () => void;
  onForumDetail: () => void;
}

export const ForumTabHeader = React.memo(function ForumTabHeader({
  name,
  colors,
  currentForum,
  topThreads,
  isLoggedIn,
  onAvatarPreview,
  onFollowPress,
  onSignPress,
  onForumDetail,
}: ForumTabHeaderProps) {
  const insets = useSafeAreaInsets();

  const isFollowed = isLoggedIn && !!currentForum?.isLike;
  const isSigned = !!currentForum?.signInInfo?.isSignIn;
  const contSignNum = currentForum?.signInInfo?.contSignNum ?? 0;
  const showLevel =
    isFollowed && currentForum?.levelId != null && currentForum.levelId > 0;

  return (
    <View style={styles.headerSection}>
      <View style={[styles.content, { paddingTop: insets.top + NAV_BAR_H + 12 }]}>
        {/* 标题行：头像 | 名字+等级 / meta | 关注签到 */}
        <View style={styles.titleRow}>
          <Avatar
            source={currentForum?.avatar || undefined}
            initials={(currentForum?.forumName || name)?.charAt(0)}
            size={56}
            onPress={onAvatarPreview}
          />
          <Pressable style={styles.titleCol} onPress={onForumDetail} accessibilityRole="button">
            <View style={styles.titleLine}>
              <Text style={[styles.forumTitle, { color: colors.text }]} numberOfLines={1}>
                {name}吧
              </Text>
              {showLevel && (
                <View
                  style={[
                    styles.levelBadgeSmall,
                    { backgroundColor: levelBadgeColor(currentForum.levelId)?.bg },
                  ]}
                >
                  <Text
                    style={[styles.levelBadgeSmallText, { color: levelBadgeColor(currentForum.levelId)?.color }]}
                  >
                    Lv.{currentForum.levelId}
                  </Text>
                </View>
              )}
            </View>
            <Text style={[styles.metaLine, { color: colors.textTertiary }]} numberOfLines={1}>
              会员 {formatCount(currentForum?.memberCount || 0)} · 帖子{' '}
              {formatCount(currentForum?.threadCount || 0)}
            </Text>
          </Pressable>

          {/* 关注/签到：状态与动作拆开。未关注/未登录只显示「关注」；
              关注后 = 「已关注」状态 chip（不承接点击，取关在右上角菜单）
              + 「签到」动作（签完变「已签到 N 天」状态 chip） */}
          <View style={styles.btnRow}>
            {!isFollowed ? (
              <HdrPressable
                onPress={onFollowPress}
                style={[styles.btnFilled, { backgroundColor: colors.primary }]}
                flashRadius={Radius.capsule}
                accessibilityRole="button"
                accessibilityLabel={`关注${name}吧`}
              >
                <Text style={[styles.btnFilledText, { color: colors.textOnPrimary }]}>关注</Text>
              </HdrPressable>
            ) : (
              <>
                <View style={[styles.btnChip, { backgroundColor: colors.surfaceSecondary }]}>
                  <Text style={[styles.btnChipText, { color: colors.textSecondary }]}>已关注</Text>
                </View>
                {isSigned ? (
                  <View style={[styles.btnChip, { backgroundColor: colors.surfaceSecondary }]}>
                    <Text style={[styles.btnChipText, { color: colors.textSecondary }]}>
                      已签到{contSignNum > 0 ? ` ${contSignNum}天` : ''}
                    </Text>
                  </View>
                ) : (
                  <HdrPressable
                    onPress={onSignPress}
                    style={[styles.btnFilled, { backgroundColor: colors.primary }]}
                    flashRadius={Radius.capsule}
                    accessibilityRole="button"
                    accessibilityLabel={`签到${name}吧`}
                  >
                    <Text style={[styles.btnFilledText, { color: colors.textOnPrimary }]}>签到</Text>
                  </HdrPressable>
                )}
              </>
            )}
          </View>
        </View>

        {/* 等级进度（已关注且有升级数据时显示） */}
        {showLevel && !!currentForum?.levelupScore && currentForum.levelupScore > 0 && (
          <View style={styles.levelSection}>
            <View style={[styles.levelTrack, { backgroundColor: colors.surfaceSecondary }]}>
              <View
                style={[
                  styles.levelFill,
                  {
                    width: `${Math.min(((currentForum.curScore ?? 0) / currentForum.levelupScore) * 100, 100)}%`,
                    backgroundColor: colors.primary,
                  },
                ]}
              />
            </View>
            <Text style={[styles.levelScoreText, { color: colors.textTertiary }]}>
              {Math.min(currentForum.curScore ?? 0, currentForum.levelupScore)}/{currentForum.levelupScore}
            </Text>
          </View>
        )}

        {/* 简介 */}
        {currentForum?.intro ? (
          <Text style={[styles.intro, { color: colors.textSecondary }]} numberOfLines={2}>
            {currentForum.intro}
          </Text>
        ) : null}
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
  topSection: { paddingTop: 4 },

  content: {
    paddingHorizontal: 16,
    paddingBottom: 12,
  },

  titleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 14,
  },
  titleCol: {
    flex: 1,
    gap: 4,
  },
  titleLine: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  forumTitle: { ...typographyStyles.title2, fontWeight: '800' },
  metaLine: { ...typographyStyles.caption1, fontWeight: '500' },

  levelBadgeSmall: { paddingHorizontal: 6, paddingVertical: 2, borderRadius: 5 },
  levelBadgeSmallText: { ...typographyStyles.caption2, fontWeight: '800' },

  btnRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  btnFilled: {
    paddingHorizontal: 18,
    paddingVertical: 10,
    borderRadius: Radius.capsule,
  },
  btnFilledText: { ...typographyStyles.footnoteBold },
  btnChip: {
    paddingHorizontal: 14,
    paddingVertical: 10,
    borderRadius: Radius.capsule,
  },
  btnChipText: { ...typographyStyles.footnote, fontWeight: '600' },

  levelSection: { marginTop: 14, flexDirection: 'row', alignItems: 'center', gap: 10 },
  levelTrack: { height: 6, borderRadius: 3, overflow: 'hidden', flex: 1 },
  levelFill: { height: 6, borderRadius: 3 },
  levelScoreText: { ...typographyStyles.caption2, fontWeight: '600', fontVariant: ['tabular-nums'] },

  intro: {
    ...typographyStyles.subhead,
    marginTop: 12,
  },
});
