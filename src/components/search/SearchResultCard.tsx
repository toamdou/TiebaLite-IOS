/**
 * Shared search result cards for global search and in-forum search.
 *
 * These preserve the previous per-page card layouts so both search flows
 * keep the same visual density and navigation behavior.
 */

import React from 'react';
import { Pressable, StyleSheet, View } from 'react-native';
import { Text } from '../ui/CompatText';

import { Avatar } from '@/components/ui/Avatar';
import { SymbolView } from '@/components/ui/SymbolView';
import { htmlToText } from '@/utils/htmlSummary';
import { formatCount } from '@/utils';
import { useTimeLabel } from '@/hooks/useTimeLabel';
import {typographyStyles, RadiusStyle} from '@/theme';
import type { SemanticColors } from '@/theme';
import type {
  SearchForumResult,
  SearchPostResult,
  SearchUserResult,
} from '@/types';

const isValidUid = (uid: string): boolean => /^[1-9]\d{0,18}$/.test(String(uid));

// 「贴」结果卡已升级为 TweetCard 推特流（见 SearchResultList.searchThreadToThreadInfo），
// 旧 CompactFeedRow 版 SearchThreadCard 已删除。

export const SearchForumCard = React.memo(function SearchForumCard({
  item,
  colors,
  onPressItem,
}: {
  item: SearchForumResult;
  colors: SemanticColors;
  onPressItem: (item: SearchForumResult) => void;
}) {
  return (
    <Pressable
      style={[styles.forumCard, { backgroundColor: colors.card, borderColor: colors.separator }]}
      onPress={() => onPressItem(item)}
    >
      <Avatar source={item.avatar} initials={item.forumName[0]} size={44} />
      <View style={styles.forumInfo}>
        <Text style={[styles.forumName, { color: colors.text }]} numberOfLines={1}>
          {item.forumName}吧
        </Text>
        <Text style={[styles.forumMeta, { color: colors.textTertiary }]} numberOfLines={1}>
          {formatCount(item.memberCount)} 关注 · {formatCount(item.threadCount)} 贴子
        </Text>
      </View>
      {item.isLike && (
        <View style={[styles.likedBadge, { backgroundColor: colors.primaryLight }]}>
          <Text style={[styles.likedText, { color: colors.primary }]}>已关注</Text>
        </View>
      )}
      <SymbolView name="chevron.right" size={14} tintColor={colors.textDisabled} />
    </Pressable>
  );
});

export const SearchUserCard = React.memo(function SearchUserCard({
  item,
  colors,
  onPressItem,
}: {
  item: SearchUserResult;
  colors: SemanticColors;
  onPressItem: (item: SearchUserResult) => void;
}) {
  // 简介 HTML→纯文本解析缓存（同 SearchThreadCard 的 preview 思路，
  // 列表滚动/重渲时避免逐卡重复字符级解析）
  const introText = React.useMemo(() => htmlToText(item.intro), [item.intro]);
  return (
    <Pressable
      style={[styles.userCard, { backgroundColor: colors.card, borderColor: colors.separator }]}
      onPress={() => {
        if (!isValidUid(item.uid)) return;
        onPressItem(item);
      }}
    >
      <Avatar source={item.portrait} initials={(item.nameShow || item.name || '?')[0]} size={44} />
      <View style={styles.userInfo}>
        <Text style={[styles.userName, { color: colors.text }]} numberOfLines={1}>
          {item.nameShow || item.name}
        </Text>
        {item.intro ? (
          <Text style={[styles.userIntro, { color: colors.textTertiary }]} numberOfLines={1}>
            {introText}
          </Text>
        ) : null}
        {item.fansNum > 0 && (
          <Text style={[styles.userFans, { color: colors.textTertiary }]}>
            {formatCount(item.fansNum)} 粉丝
          </Text>
        )}
      </View>
      <SymbolView name="chevron.right" size={14} tintColor={colors.textDisabled} />
    </Pressable>
  );
});

export const SearchPostCard = React.memo(function SearchPostCard({
  item,
  colors,
  onPressItem,
}: {
  item: SearchPostResult;
  colors: SemanticColors;
  onPressItem: (item: SearchPostResult) => void;
}) {
  const preview = React.useMemo(() => htmlToText(item.content || ''), [item]);
  const timeLabel = useTimeLabel();
  return (
    <Pressable
      style={[
        styles.postCard,
        {
          backgroundColor: colors.card,
          borderColor: colors.separator,
        },
      ]}
      onPress={() => onPressItem(item)}
    >
      <Text style={[styles.postTitle, { color: colors.text }]} numberOfLines={2}>
        {item.title || '无标题'}
      </Text>
      <Text style={[styles.postPreview, { color: colors.textSecondary }]} numberOfLines={2}>
        {preview}
      </Text>
      <View style={styles.postFooter}>
        <Text style={[styles.postAuthor, { color: colors.textTertiary }]}>
          {item.authorName}
        </Text>
        <View style={styles.postStats}>
          <Text style={[styles.postStat, { color: colors.textTertiary }]}>
            {formatCount(item.replyNum)}回复
          </Text>
          <Text style={[styles.postStat, { color: colors.textTertiary }]}>
            {timeLabel(item.createTime * 1000)}
          </Text>
        </View>
      </View>
    </Pressable>
  );
});

const styles = StyleSheet.create({
  // Forum card
  forumCard: {
    flexDirection: 'row',
    alignItems: 'center',
    // 卡片距屏边统一 10pt
    marginHorizontal: 10,
    marginTop: 12,
    ...RadiusStyle.card,
    padding: 14,
    borderWidth: StyleSheet.hairlineWidth,
    gap: 12,
  },
  forumInfo: {
    flex: 1,
    gap: 3,
  },
  forumName: {
    ...typographyStyles.calloutBold,
  },
  forumMeta: {
    ...typographyStyles.footnote,
  },
  likedBadge: {
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderRadius: 10,
    borderCurve: 'continuous',
  },
  likedText: {
    ...typographyStyles.caption2Bold,
  },

  // User card
  userCard: {
    flexDirection: 'row',
    alignItems: 'center',
    // 卡片距屏边统一 10pt
    marginHorizontal: 10,
    marginTop: 12,
    ...RadiusStyle.card,
    padding: 14,
    borderWidth: StyleSheet.hairlineWidth,
    gap: 12,
  },
  userInfo: {
    flex: 1,
    gap: 2,
  },
  userName: {
    ...typographyStyles.calloutBold,
  },
  userIntro: {
    ...typographyStyles.footnote,
  },
  userFans: {
    ...typographyStyles.caption1,
    marginTop: 2,
  },

  // In-forum post card（边框色走 colors.separator，随主题明暗切换）
  postCard: {
    padding: 16,
    ...RadiusStyle.chip,
    marginVertical: 6,
    borderWidth: StyleSheet.hairlineWidth,
  },
  postTitle: {
    ...typographyStyles.subheadBold,
    lineHeight: 21,
    marginBottom: 6,
  },
  postPreview: {
    ...typographyStyles.footnote,
    lineHeight: 19,
    marginBottom: 8,
  },
  postFooter: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  postAuthor: {
    ...typographyStyles.caption1,
  },
  postStats: {
    flexDirection: 'row',
    gap: 10,
  },
  postStat: {
    ...typographyStyles.caption2,
  },
});
