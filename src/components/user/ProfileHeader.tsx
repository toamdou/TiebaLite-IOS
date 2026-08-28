/**
 * ProfileHeader — user profile card (资料卡).
 *
 * Extracted from the user profile page ([uid].tsx) during the page split.
 * Renders the Kotlin-aligned header: large avatar, stats row (粉丝/关注 are
 * tappable → onOpenSocial), intro, verification badges, chips row and the
 * follow/block/message actions. Owns the avatar full-screen preview
 * (ImageViewer) so the page keeps a fixed 4-callback props contract.
 */

import { useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { Text } from '../ui/CompatText';

import { SymbolView } from '@/components/ui/SymbolView';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { Avatar } from '@/components/ui/Avatar';
import { Button } from '@/components/ui/Button';
import ImageViewer from '@/components/ImageViewer';

import {Spacing, typographyStyles, RadiusStyle} from '@/theme';
import type { SemanticColors } from '@/theme';
import { hapticForScene } from '@/theme/hapticsMap';
import { formatCount, getAvatarUrl } from '@/utils';
import { useAppPreference } from '@/hooks/useAppPreference';
import type { UserInfo } from '@/types';

const DEFAULT_INTRO = '这个人很懒，什么都没留下';

export interface ProfileHeaderProps {
  user: UserInfo;
  colors: SemanticColors;
  isFollowing: boolean;
  isBlocked: boolean;
  isOwnProfile: boolean;
  isLoggedIn: boolean;
  onFollow: () => void;
  onBlock: () => void;
  onCopyUID: () => void;
  /** 统计区「粉丝/关注」点击 → 打开对应模式的粉丝/关注列表 */
  onOpenSocial: (mode: 'fans' | 'follows') => void;
}

export function ProfileHeader({
  user,
  colors,
  isFollowing,
  isBlocked,
  isOwnProfile,
  isLoggedIn,
  onFollow,
  onBlock,
  onCopyUID,
  onOpenSocial,
}: ProfileHeaderProps) {
  const [avatarPreviewVisible, setAvatarPreviewVisible] = useState(false);
  // IP 属地显示开关（设置→使用习惯→贴子）
  const showIpLocation = useAppPreference('showIpLocation', true);

  // Gender chip — iOS 风格：性别色 + 纯文字，不使用 emoji 符号
  let genderLabel: string | null = null;
  let genderColor: string | null = null;
  if (user.sex === 1) {
    genderLabel = '男';
    genderColor = colors.tint;
  } else if (user.sex === 2) {
    genderLabel = '女';
    genderColor = colors.danger;
  }
  const uidText = user.tiebaUid || user.id;

  // Verification flags
  const hasBazhuBadge = !!user.bazhuGrade;
  const bazhuDesc = user.bazhuGrade?.desc || '吧主';
  const hasGodBadge = !!user.newGodData && (user.newGodData?.status ?? 0) !== 0;
  const godFieldName = user.newGodData?.fieldName || '大神认证';
  const hasAnyBadge = hasBazhuBadge || hasGodBadge;

  return (
    <>
      <View style={styles.headerWrap}>
        <View style={[styles.profileCard, { backgroundColor: colors.card }]}>
          {/* ---- Avatar + Name ---- */}
          <View style={styles.avatarSection}>
            <Avatar
              source={user.portrait}
              initials={user.name?.slice(0, 2)}
              size={80}
              onPress={user.portrait ? () => setAvatarPreviewVisible(true) : undefined}
            />
            <View style={styles.nameSection}>
              <Text style={[styles.userName, { color: colors.text }]}>
                {user.nameShow || user.name}
              </Text>
              {/* 关注/拉黑：用户名下方横排，两个按钮均分一行（8-28 改回横排；等级不展示） */}
              {isLoggedIn && !isOwnProfile && (
                <View style={styles.actionRow}>
                  <Button
                    title={isFollowing ? '已关注' : '关注'}
                    variant={isFollowing ? 'plain' : 'filled'}
                    size="small"
                    icon={isFollowing ? 'person.badge.minus' : 'person.badge.plus'}
                    onPress={onFollow}
                    fullWidth
                    style={styles.actionBtn}
                  />
                  <Button
                    title={isBlocked ? '已拉黑' : '拉黑'}
                    variant="plain"
                    size="small"
                    icon="nosign"
                    onPress={onBlock}
                    fullWidth
                    style={styles.actionBtn}
                  />
                </View>
              )}
            </View>
          </View>

          {/* ---- Stats Row (3 items) ---- */}
          <View style={[styles.statsRow, { borderColor: colors.separator }]}>
            {/* 关注 — 点击进入关注列表 */}
            <HdrPressable
              onPress={() => {
                void hapticForScene('press');
                onOpenSocial('follows');
              }}
              style={styles.statItem}
              accessibilityRole="button"
              accessibilityLabel={`关注 ${formatCount(user.concernNum || 0)}，点击查看`}
            >
              <Text style={[styles.statValue, { color: colors.text }]}>
                {formatCount(user.concernNum || 0)}
              </Text>
              <Text style={[styles.statLabel, { color: colors.textTertiary }]}>关注</Text>
            </HdrPressable>
            {/* Divider */}
            <View style={[styles.statDivider, { backgroundColor: colors.separator }]} />
            {/* 粉丝 — 点击进入粉丝列表 */}
            <HdrPressable
              onPress={() => {
                void hapticForScene('press');
                onOpenSocial('fans');
              }}
              style={styles.statItem}
              accessibilityRole="button"
              accessibilityLabel={`粉丝 ${formatCount(user.fansNum || 0)}，点击查看`}
            >
              <Text style={[styles.statValue, { color: colors.text }]}>
                {formatCount(user.fansNum || 0)}
              </Text>
              <Text style={[styles.statLabel, { color: colors.textTertiary }]}>粉丝</Text>
            </HdrPressable>
            {/* Divider */}
            <View style={[styles.statDivider, { backgroundColor: colors.separator }]} />
            {/* 获赞 */}
            <View style={styles.statItem}>
              <Text style={[styles.statValue, { color: colors.text }]}>
                {formatCount(user.totalAgreeNum || 0)}
              </Text>
              <Text style={[styles.statLabel, { color: colors.textTertiary }]}>获赞</Text>
            </View>
          </View>

          {/* ---- Intro ---- */}
          <Text
            style={[styles.intro, { color: colors.textSecondary }]}
            numberOfLines={3}
          >
            {user.intro || DEFAULT_INTRO}
          </Text>

          {/* ---- Verification Badges ---- */}
          {hasAnyBadge && (
            <View style={styles.badgeRow}>
              {hasBazhuBadge && (
                <View style={[styles.verifyBadge, { backgroundColor: colors.primaryLight || colors.primary + '22' }]}>
                  <SymbolView
                    name="checkmark.seal.fill"
                    size={14}
                    tintColor={colors.primary}
                  />
                  <Text style={[styles.verifyBadgeText, { color: colors.primary }]}>
                    {bazhuDesc}
                  </Text>
                </View>
              )}
              {hasGodBadge && (
                <View style={[styles.verifyBadge, { backgroundColor: colors.primaryLight || colors.primary + '22' }]}>
                  <SymbolView
                    name="rosette"
                    size={14}
                    tintColor={colors.primary}
                  />
                  <Text style={[styles.verifyBadgeText, { color: colors.primary }]}>
                    {godFieldName}
                  </Text>
                </View>
              )}
            </View>
          )}

          {/* ---- Chips Row: Gender · UID · IP · Age ---- */}
          <View style={styles.chipsRow}>
            {genderLabel && (
              <View style={[styles.chip, { backgroundColor: (genderColor || colors.primary) + '1A' }]}>
                <Text style={[styles.chipText, { color: genderColor || colors.textSecondary }]}>
                  {genderLabel}
                </Text>
              </View>
            )}

            <HdrPressable
              onPress={onCopyUID}
              style={[styles.chip, { backgroundColor: colors.chip || colors.surfaceSecondary }]}
            >
              <Text style={[styles.chipText, { color: colors.onChip || colors.textSecondary }]}>
                贴吧UID: {uidText}
              </Text>
              <SymbolView
                name="doc.on.doc"
                size={11}
                tintColor={colors.onChip || colors.textTertiary}
                style={{ marginLeft: Spacing.xs }}
              />
            </HdrPressable>

            {showIpLocation && user.ipLocation ? (
              <View style={[styles.chip, { backgroundColor: colors.chip || colors.surfaceSecondary }]}>
                <SymbolView
                  name="location.fill"
                  size={11}
                  tintColor={colors.onChip || colors.textTertiary}
                />
                <Text style={[styles.chipText, { color: colors.onChip || colors.textSecondary, marginLeft: 3 }]}>
                  IP: {user.ipLocation}
                </Text>
              </View>
            ) : null}

            {user.tbAge ? (
              <View style={[styles.chip, { backgroundColor: colors.chip || colors.surfaceSecondary }]}>
                <Text style={[styles.chipText, { color: colors.onChip || colors.textSecondary }]}>
                  吧龄: {user.tbAge}年
                </Text>
              </View>
            ) : null}
          </View>

          {/* 关注/拉黑已上移到用户名下方横排（见 avatarSection） */}
        </View>
        {/* 分段控件已移出列表头：固定于列表上方（与吧页同构），
            资料卡随列表滚动；PlatformView host 不再进 LegendList header。 */}
      </View>

      <ImageViewer
        images={user.portrait ? [getAvatarUrl(user.portrait)] : []}
        visible={avatarPreviewVisible}
        onClose={() => setAvatarPreviewVisible(false)}
      />
    </>
  );
}

// ---------- Styles ----------

const styles = StyleSheet.create({
  // Profile Header：资料卡 + 卡片下沿的 segment
  headerWrap: {
    paddingHorizontal: 10,
    paddingTop: Spacing.sm,
  },
  profileCard: {
    ...RadiusStyle.card,
    padding: Spacing.lg,
  },

  // Avatar + Name
  avatarSection: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: Spacing.lg,
    marginBottom: 16,
  },
  nameSection: {
    gap: Spacing.sm,
    flex: 1,
    // 用户名+操作钮纵排区域：按钮组宽度让按钮内容紧凑
    alignSelf: 'stretch',
  },
  userName: typographyStyles.title2,
  // 关注/拉黑：用户名下方横排（两个按钮均分一行）
  actionRow: {
    flexDirection: 'row',
    alignItems: 'stretch',
    gap: Spacing.sm,
  },
  actionBtn: {
    flex: 1,
  },

  // Stats Row (3 items, 卡片内分组无边框线)
  statsRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-evenly',
    paddingVertical: 12,
    marginBottom: Spacing.md,
  },
  statItem: { alignItems: 'center', gap: 2, flex: 1 },
  statValue: typographyStyles.headline,
  statLabel: { fontSize: 12, fontWeight: '500' },
  statDivider: {
    width: StyleSheet.hairlineWidth,
    height: 24,
  },

  // Intro
  intro: {
    fontSize: 14,
    lineHeight: 20,
    marginBottom: 10,
  },

  // Verification Badges
  badgeRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: Spacing.sm,
    marginBottom: 10,
  },
  verifyBadge: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    paddingHorizontal: 10,
    paddingVertical: 5,
    ...RadiusStyle.input,
  },
  verifyBadgeText: typographyStyles.caption1Bold,

  // Chips Row
  chipsRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 6,
    marginBottom: Spacing.md,
  },
  chip: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingHorizontal: 10,
    paddingVertical: 4,
    ...RadiusStyle.chip,
  },
  chipText: {
    fontSize: 11,
    fontWeight: '500',
  },
});