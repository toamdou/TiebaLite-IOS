/**
 * ProfileHeader — user profile header (「个人页同理」与吧页 v3 同语言).
 *
 * 2026-09-09 v3：渐变色带封面废弃（吧页图带/纯带两条路线均被否——素材是
 * 方标/头像时横幅化天然丑），回归 Apple 留白排版：64 头像 + 大标题名字
 * （认证徽章随行）+ @handle，右侧关注/拉黑；bio、Meta 行（性别/UID 复制/
 * IP/吧龄）、行内统计（关注/粉丝可点 → onOpenSocial）依次铺开。
 * 顶部让位由本头部承接（insets.top + NAV_BAR_H + 12，UserTabList 已去
 * paddingTop）。Owns the avatar full-screen preview (ImageViewer) so the
 * page keeps a fixed 4-callback props contract.
 */

import { useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Text } from '../ui/CompatText';
import { SymbolView } from '@/components/ui/SymbolView';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { Avatar } from '@/components/ui/Avatar';
import { Button } from '@/components/ui/Button';
import ImageViewer from '@/components/ImageViewer';

import { Radius, typographyStyles } from '@/theme';
import { hapticForScene } from '@/theme/hapticsMap';
import { formatCount, getAvatarUrl } from '@/utils';
import { useAppPreference } from '@/hooks/useAppPreference';
import { NAV_BAR_H } from '@/constants/layout';
import type { UserInfo } from '@/types';

const DEFAULT_INTRO = '这个人很懒，什么都没留下';

export interface ProfileHeaderProps {
  user: UserInfo;
  colors: any;
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
  const insets = useSafeAreaInsets();

  // Gender — iOS 风格：性别色 + 纯文字，不使用 emoji 符号
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

  // Verification badges（吧主 / 大神认证，挂在名字旁）
  const hasBazhuBadge = !!user.bazhuGrade;
  const bazhuDesc = user.bazhuGrade?.desc || '吧主';
  const hasGodBadge = !!user.newGodData && (user.newGodData?.status ?? 0) !== 0;
  const godFieldName = user.newGodData?.fieldName || '大神认证';

  return (
    <>
      <View style={[styles.content, { paddingTop: insets.top + NAV_BAR_H + 12 }]}>
        {/* 标题行：头像 | 名字+徽章 / @handle | 关注/拉黑 */}
        <View style={styles.titleRow}>
          <Avatar
            source={user.portrait}
            initials={user.name?.slice(0, 2)}
            size={64}
            onPress={user.portrait ? () => setAvatarPreviewVisible(true) : undefined}
          />
          <View style={styles.titleCol}>
            <View style={styles.titleLine}>
              <Text style={[styles.userName, { color: colors.text }]} numberOfLines={1}>
                {user.nameShow || user.name}
              </Text>
              {hasBazhuBadge && (
                <View style={[styles.verifyBadge, { backgroundColor: colors.primaryLight }]}>
                  <SymbolView name="checkmark.seal.fill" size={13} tintColor={colors.primary} />
                  <Text style={[styles.verifyBadgeText, { color: colors.primary }]}>{bazhuDesc}</Text>
                </View>
              )}
              {hasGodBadge && (
                <View style={[styles.verifyBadge, { backgroundColor: colors.primaryLight }]}>
                  <SymbolView name="rosette" size={13} tintColor={colors.primary} />
                  <Text style={[styles.verifyBadgeText, { color: colors.primary }]}>{godFieldName}</Text>
                </View>
              )}
            </View>
            <Text style={[styles.handle, { color: colors.textTertiary }]} numberOfLines={1}>
              {user.name ? `@${user.name}` : `贴吧UID：${uidText}`}
            </Text>
          </View>

          {/* 关注/拉黑（仅登录且非本人主页） */}
          {isLoggedIn && !isOwnProfile && (
            <View style={styles.btnRow}>
              <Button
                title={isFollowing ? '已关注' : '关注'}
                variant={isFollowing ? 'plain' : 'filled'}
                size="small"
                icon={isFollowing ? 'person.badge.minus' : 'person.badge.plus'}
                onPress={onFollow}
              />
              <Button
                title={isBlocked ? '已拉黑' : '拉黑'}
                variant="plain"
                size="small"
                icon="nosign"
                onPress={onBlock}
              />
            </View>
          )}
        </View>

        {/* 简介 */}
        <Text style={[styles.intro, { color: colors.textSecondary }]} numberOfLines={3}>
          {user.intro || DEFAULT_INTRO}
        </Text>

        {/* Meta 行：性别 · UID 复制 · IP 属地 · 吧龄 */}
        <View style={styles.metaRow}>
          {genderLabel && (
            <View style={styles.metaItem}>
              <SymbolView name="person.fill" size={12} tintColor={genderColor || colors.textTertiary} />
              <Text style={[styles.metaText, { color: genderColor || colors.textTertiary }]}>
                {genderLabel}
              </Text>
            </View>
          )}

          <HdrPressable
            onPress={onCopyUID}
            style={styles.metaItem}
            accessibilityRole="button"
            accessibilityLabel={`复制贴吧UID ${uidText}`}
          >
            <SymbolView name="doc.on.doc" size={12} tintColor={colors.textTertiary} />
            <Text style={[styles.metaText, { color: colors.textTertiary }]}>UID {uidText}</Text>
          </HdrPressable>

          {showIpLocation && user.ipLocation ? (
            <View style={styles.metaItem}>
              <SymbolView name="location.fill" size={12} tintColor={colors.textTertiary} />
              <Text style={[styles.metaText, { color: colors.textTertiary }]}>IP {user.ipLocation}</Text>
            </View>
          ) : null}

          {user.tbAge ? (
            <View style={styles.metaItem}>
              <SymbolView name="hourglass" size={12} tintColor={colors.textTertiary} />
              <Text style={[styles.metaText, { color: colors.textTertiary }]}>{user.tbAge}年吧龄</Text>
            </View>
          ) : null}
        </View>

        {/* 行内统计：关注/粉丝可点进对应列表，获赞静态 */}
        <View style={styles.statsRow}>
          <HdrPressable
            onPress={() => {
              void hapticForScene('press');
              onOpenSocial('follows');
            }}
            style={styles.stat}
            accessibilityRole="button"
            accessibilityLabel={`关注 ${formatCount(user.concernNum || 0)}，点击查看`}
          >
            <Text style={[styles.statValue, { color: colors.text }]}>
              {formatCount(user.concernNum || 0)}
            </Text>
            <Text style={[styles.statLabel, { color: colors.textTertiary }]}>关注</Text>
          </HdrPressable>
          <HdrPressable
            onPress={() => {
              void hapticForScene('press');
              onOpenSocial('fans');
            }}
            style={styles.stat}
            accessibilityRole="button"
            accessibilityLabel={`粉丝 ${formatCount(user.fansNum || 0)}，点击查看`}
          >
            <Text style={[styles.statValue, { color: colors.text }]}>
              {formatCount(user.fansNum || 0)}
            </Text>
            <Text style={[styles.statLabel, { color: colors.textTertiary }]}>粉丝</Text>
          </HdrPressable>
          <View style={styles.stat}>
            <Text style={[styles.statValue, { color: colors.text }]}>
              {formatCount(user.totalAgreeNum || 0)}
            </Text>
            <Text style={[styles.statLabel, { color: colors.textTertiary }]}>获赞</Text>
          </View>
        </View>
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
  userName: { ...typographyStyles.title2, fontWeight: '800' },
  handle: { ...typographyStyles.subhead },
  verifyBadge: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderRadius: Radius.chip,
  },
  verifyBadgeText: { ...typographyStyles.caption2Bold },

  btnRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
  },

  intro: {
    ...typographyStyles.subhead,
    lineHeight: 21,
    marginTop: 14,
  },

  metaRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'center',
    gap: 14,
    marginTop: 10,
  },
  metaItem: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
  },
  metaText: {
    fontSize: 13,
    fontWeight: '500',
  },

  statsRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 20,
    marginTop: 14,
  },
  stat: {
    flexDirection: 'row',
    alignItems: 'baseline',
    gap: 4,
  },
  statValue: {
    fontSize: 16,
    fontWeight: '700',
  },
  statLabel: {
    fontSize: 13,
    fontWeight: '500',
  },
});
