/**
 * 吧页顶部固定区：吧名片卡片 + 置顶帖。
 *
 * 2026-09-09 v4：用户拍板"装进卡片、要 Apple 感"——v3 散排大标题式被否。
 * 吧名片（头像+名字+等级+meta+关注签到+进度+简介）整体装进圆角卡片，
 * 与列表 TweetCard 同款卡片语言（colors.card 底+hairline borderCard+
 * continuous 圆角+左右 10 边距），系统分组样式观感。顶部让位由本头部
 * 承接（insets.top + NAV_BAR_H + 8）。
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
  const levelColor = showLevel ? levelBadgeColor(currentForum?.levelId) : undefined;
  /** 有升级阈值才画进度条；服务端只给等级不给经验数据时退化为"经验 N"。 */
  const hasLevelProgress = showLevel && (currentForum?.levelupScore ?? 0) > 0;
  const curScore = currentForum?.curScore ?? 0;

  return (
    <View style={styles.headerSection}>
      <View style={[styles.content, { paddingTop: insets.top + NAV_BAR_H }]}>
        <View style={[styles.card, { backgroundColor: colors.card, borderColor: colors.borderCard }]}>
          {/* 标题行：头像 | 名字 /（等级 + meta）| 关注签到 */}
          <View style={styles.titleRow}>
            <Avatar
              source={currentForum?.avatar || undefined}
              initials={(currentForum?.forumName || name)?.charAt(0)}
              size={52}
              onPress={onAvatarPreview}
            />
            <Pressable style={styles.titleCol} onPress={onForumDetail} accessibilityRole="button">
              <Text style={[styles.forumTitle, { color: colors.text }]} numberOfLines={1}>
                {name}吧
              </Text>
              {/* meta 行：等级徽标 + 成员/帖子数。等级徽标从标题行挪到这里
                  （2026-09-12）：标题行右侧还要放「已关注 + 签到」两个 chip，
                  375pt 屏上三样抢宽会把 Lv 徽标挤没、吧名也只剩两三个字。
                  徽标 flexShrink:0 + 数字 numberOfLines:1，宽度再紧也不会
                  把等级挤掉。 */}
              <View style={styles.metaRow}>
                {showLevel && (
                  <View
                    style={[
                      styles.levelBadgeSmall,
                      { backgroundColor: levelColor?.bg ?? colors.surfaceSecondary },
                    ]}
                  >
                    <Text
                      style={[styles.levelBadgeSmallText, { color: levelColor?.color ?? colors.textSecondary }]}
                    >
                      Lv.{currentForum.levelId}
                    </Text>
                  </View>
                )}
                <Text style={[styles.metaLine, { color: colors.textTertiary }]} numberOfLines={1}>
                  会员 {formatCount(currentForum?.memberCount || 0)} · 帖子{' '}
                  {formatCount(currentForum?.threadCount || 0)}
                </Text>
              </View>
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

          {/* 等级进度：已关注且有等级即占位（2026-09-12）。有升级阈值画进度条，
              服务端只给等级/经验时退化为一行"经验 N"，避免这块整段消失。 */}
          {showLevel && (
            <View style={styles.levelSection}>
              {hasLevelProgress ? (
                <>
                  <View style={[styles.levelTrack, { backgroundColor: colors.surfaceSecondary }]}>
                    <View
                      style={[
                        styles.levelFill,
                        {
                          width: `${Math.min((curScore / (currentForum.levelupScore || 1)) * 100, 100)}%`,
                          backgroundColor: levelColor?.bg ?? colors.primary,
                        },
                      ]}
                    />
                  </View>
                  <Text style={[styles.levelScoreText, { color: colors.textTertiary }]}>
                    {Math.min(curScore, currentForum.levelupScore)}/{currentForum.levelupScore}
                  </Text>
                </>
              ) : (
                <Text style={[styles.levelScoreText, { color: colors.textTertiary }]}>
                  经验 {curScore}
                </Text>
              )}
            </View>
          )}

          {/* 简介 */}
          {currentForum?.intro ? (
            <Text style={[styles.intro, { color: colors.textSecondary }]} numberOfLines={2}>
              {currentForum.intro}
            </Text>
          ) : null}
        </View>
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
    paddingBottom: 8,
  },
  // 吧名片卡：与 TweetCard 同款卡片语言（左右 10、continuous 圆角、hairline）
  card: {
    marginHorizontal: 10,
    borderRadius: Radius.card,
    borderCurve: 'continuous',
    borderWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: 14,
    paddingTop: 12,
    paddingBottom: 14,
  },

  titleRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
  },
  titleCol: {
    flex: 1,
    gap: 3,
  },
  metaRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
  },
  forumTitle: { ...typographyStyles.title3, fontWeight: '800' },
  // flexShrink:1 保证宽度紧张时截断的是"会员/帖子"这行，不是等级徽标。
  metaLine: { ...typographyStyles.caption1, fontWeight: '500', flexShrink: 1 },

  // 等级徽标不给缩小：标题行右边有「已关注 + 签到」两个 chip，宽度紧张时
  // 牺牲成员数而不是等级（2026-09-12）。
  levelBadgeSmall: { paddingHorizontal: 6, paddingVertical: 2, borderRadius: 5, flexShrink: 0 },
  levelBadgeSmallText: { ...typographyStyles.caption2, fontWeight: '800' },

  btnRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
  },
  btnFilled: {
    paddingHorizontal: 14,
    paddingVertical: 9,
    borderRadius: Radius.capsule,
  },
  btnFilledText: { ...typographyStyles.footnoteBold },
  btnChip: {
    paddingHorizontal: 10,
    paddingVertical: 9,
    borderRadius: Radius.capsule,
  },
  btnChipText: { ...typographyStyles.footnote, fontWeight: '600' },

  levelSection: { marginTop: 12, flexDirection: 'row', alignItems: 'center', gap: 10 },
  levelTrack: { height: 6, borderRadius: 3, overflow: 'hidden', flex: 1 },
  levelFill: { height: 6, borderRadius: 3 },
  levelScoreText: { ...typographyStyles.caption2, fontWeight: '600', fontVariant: ['tabular-nums'] },

  intro: {
    ...typographyStyles.footnote,
    marginTop: 10,
    lineHeight: 18,
  },
});
