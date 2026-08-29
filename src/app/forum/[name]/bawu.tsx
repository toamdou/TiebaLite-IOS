/**
 * Bawu Team Page (吧务团队) — shows the forum management team.
 *
 * Data: getBawuInfo(forumId) → { bawuTeamList: [{ roleName, roleInfo: [...] }] }
 * (proto: BawuTeam.bawu_team_list → BawuRoleDes { role_name, role_info: BawuRoleInfoPub[] })
 *
 * iOS 26 design: grouped role sections, SF Symbols, level badges,
 * haptic row feedback（入场动画已随设计移除，2026-08-25）。Rows navigate to the user page.
 */

import { useCallback, useMemo } from 'react';
import {
  View,
  StyleSheet,
  Text,
  Pressable,
  RefreshControl,
} from 'react-native';
import { LegendList } from '@legendapp/list/react-native';
import { useLocalSearchParams, useRouter, Stack } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { hapticForScene } from '@/theme/hapticsMap';

import { SymbolView } from '@/components/ui/SymbolView';
import { Avatar } from '@/components/ui/Avatar';
import { ErrorState } from '@/components/ui/ErrorState';
import { EmptyState } from '@/components/ui/EmptyState';
import { useThemeColors } from '@/theme/ThemeContext';
import {Spacing, RadiusStyle, Radius} from '@/theme';
import { typographyStyles } from '@/theme/typography';
import { SkeletonList } from '../../../components/ui/Skeleton';
import { getBawuInfo } from '@/services/api/endpoints/forum';
import { parseForumUser, flattenGroupRows, type GroupedRow, type FlattenedForumUser } from '@/utils/forumUsers';
import { useAsyncData } from '@/hooks/useAsyncData';

// ────────────────────────────────────────────────────────────
// Types & parsing (tolerates snake_case proto / camelCase normalized fields)
// ────────────────────────────────────────────────────────────

type BawuUser = FlattenedForumUser;

interface BawuRole {
  roleName: string;
  users: BawuUser[];
}

/**
 * 吧务响应统一解析（thermo Z1-L：原先 fetcher 与 parse 各自解包一次
 * bawu_team_info，收敛为唯一出口；返回 teams + totalNum）。
 */
function parseBawuInfo(data: any): { teams: BawuRole[]; totalNum: number } {
  const teamInfo = data?.bawu_team_info ?? data?.bawuTeamInfo ?? data;
  const rawList: any[] =
    data?.bawuTeamList ??
    data?.bawu_team_list ??
    teamInfo?.bawu_team_list ??
    teamInfo?.bawuTeamList ??
    [];
  const teams: BawuRole[] = rawList
    .map((r: any) => {
      const roleName = String(r?.role_name ?? r?.roleName ?? '');
      const usersRaw: any[] = r?.role_info ?? r?.roleInfo ?? [];
      return { roleName, users: usersRaw.map((u: any) => parseForumUser(u, roleName)) };
    })
    .filter((r: BawuRole) => r.roleName || r.users.length > 0);
  return {
    teams,
    totalNum: Number(teamInfo?.total_num ?? teamInfo?.totalNum ?? 0),
  };
}


type Row = GroupedRow<BawuUser>;

// ────────────────────────────────────────────────────────────
// Page
// ────────────────────────────────────────────────────────────

export default function BawuTeamPage() {
  const { name, forumId } = useLocalSearchParams<{ name: string; forumId: string }>();
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { colors } = useThemeColors();

  // 单次加载样板见 useAsyncData（loading/refreshing/error + 首载 + 竞态守卫；
  // forumId 缺失时不请求，直接渲染空态，不卡骨架）
  const { data, loading, refreshing, error, refresh } = useAsyncData<{
    teams: BawuRole[];
    totalNum: number;
  }>({
    fetcher: async () => {
      const d = await getBawuInfo(forumId);
      return parseBawuInfo(d);
    },
    enabled: !!forumId,
  });
  const teams = data?.teams ?? [];
  const totalNum = data?.totalNum ?? 0;

  const handleRefresh = useCallback(async () => {
    await refresh();
    hapticForScene('toggle');
  }, [refresh]);

  const handleUserPress = useCallback(
    (user: BawuUser) => {
      if (!user.userId) return;
      hapticForScene('press');
      router.push({ pathname: '/user/[uid]', params: { uid: user.userId } });
    },
    [router],
  );

  // Flatten roles → header + user rows for LegendList
  const rows = useMemo<Row[]>(
    () =>
      flattenGroupRows(
        teams.map((team) => ({
          title: team.roleName || '吧务',
          count: team.users.length,
          items: team.users,
        })),
        (user) => user.userId,
      ),
    [teams],
  );

  const renderItem = useCallback(
    ({ item }: { item: Row }) => {
      if (item.kind === 'header') {
        return (
          <View style={styles.roleHeader}>
            <View style={styles.roleHeaderLeft}>
              <View style={[styles.roleDot, { backgroundColor: colors.primary }]} />
              <Text style={[styles.roleName, { color: colors.text }]}>{item.title}</Text>
            </View>
            <View style={[styles.roleCountChip, { backgroundColor: colors.surfaceSecondary }]}>
              <Text style={[styles.roleCountText, { color: colors.textTertiary }]}>{item.count}人</Text>
            </View>
          </View>
        );
      }

      if (item.kind !== 'item') return null;
      const user = item.item;
      const displayName = user.nameShow || user.userName || '匿名用户';
      return (
        <Pressable
          style={({ pressed }) => [
            styles.userRow,
            {
              backgroundColor: colors.card,
              borderColor: colors.divider,
              opacity: pressed ? 0.85 : 1,
              transform: [{ scale: pressed ? 0.985 : 1 }],
            },
          ]}
          onPress={() => handleUserPress(user)}
          accessibilityRole="button"
          accessibilityLabel={displayName}
        >
          <Avatar source={user.portrait || undefined} initials={displayName.charAt(0)} size={46} />
          <View style={styles.userTextCol}>
            <View style={styles.userNameRow}>
              <Text style={[styles.userName, { color: colors.text }]} numberOfLines={1}>
                {displayName}
              </Text>
              {user.userLevel > 0 && (
                <View style={[styles.levelBadge, { backgroundColor: `${colors.primary}26` }]}>
                  <Text style={[styles.levelBadgeText, { color: colors.primary }]}>Lv.{user.userLevel}</Text>
                </View>
              )}
            </View>
            <Text style={[styles.userSubtitle, { color: colors.textTertiary }]} numberOfLines={1}>
              {user.roleName}
              {user.levelName ? ` · ${user.levelName}` : ''}
            </Text>
          </View>
          <SymbolView name="chevron.right" size={13} weight="semibold" tintColor={colors.textDisabled} />
        </Pressable>
      );
    },
    [colors, handleUserPress],
  );

  const groupBg = colors.groupFill;

  const bawuKeyExtractor = useCallback((item: Row) => item.key, []);
  const bawuItemType = useCallback((item: Row) => item.kind, []);
  const listHeader = useCallback(
    () =>
      rows.length > 0 ? (
        <View style={[styles.summaryCard, { backgroundColor: groupBg }]}>
          <View style={[styles.summaryIcon, { backgroundColor: colors.primary + '1F' }]}>
            <SymbolView name="shield.lefthalf.filled" size={20} tintColor={colors.primary} />
          </View>
          <View style={styles.summaryTextCol}>
            <Text style={[styles.summaryTitle, { color: colors.text }]}>
              {name}吧管理团队
            </Text>
            <Text style={[styles.summarySubtitle, { color: colors.textTertiary }]}>
              共 {totalNum > 0 ? totalNum : rows.filter((r) => r.kind === 'item').length} 名吧务成员
            </Text>
          </View>
        </View>
      ) : null,
    [rows, groupBg, colors, name, totalNum],
  );
  const listEmpty = useCallback(
    () =>
      !loading ? (
        <EmptyState
          icon={'person.2' as any}
          title="暂无吧务信息"
          description="这个吧还没有公开管理团队"
        />
      ) : null,
    [loading],
  );

  // ── Loading ──
  if (loading && rows.length === 0) {
    return (
      <View style={[styles.container, { backgroundColor: colors.background }]}>
        <Stack.Screen options={{ title: '吧务团队' }} />
        <SkeletonList count={6} variant="row" />
      </View>
    );
  }

  // ── Error ──
  if (error && rows.length === 0) {
    return (
      <View style={[styles.container, { backgroundColor: colors.background }]}>
        <Stack.Screen options={{ title: '吧务团队' }} />
        <ErrorState title="加载失败" message={error} onRetry={handleRefresh} retryLabel="重试" />
      </View>
    );
  }

  return (
    <View style={[styles.container, { backgroundColor: colors.background }]}>
      <Stack.Screen options={{ title: '吧务团队' }} />
      <LegendList
        recycleItems
        data={rows}
        keyExtractor={bawuKeyExtractor}
        renderItem={renderItem}
        getItemType={bawuItemType}
        contentContainerStyle={[styles.listContent, { paddingTop: insets.top + 66, paddingBottom: insets.bottom + 24 }]}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={handleRefresh} tintColor={colors.primary} />
        }
        ListHeaderComponent={listHeader}
        ListEmptyComponent={listEmpty}
        drawDistance={250}
      />
    </View>
  );
}

// ────────────────────────────────────────────────────────────
// Styles
// ────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: { flex: 1 },
  listContent: { paddingTop: Spacing.md },

  // Summary card
  summaryCard: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.md,
    marginHorizontal: Spacing.lg,
    marginBottom: 6,
    paddingHorizontal: 14,
    paddingVertical: 13,
    ...RadiusStyle.card,
  },
  summaryIcon: {
    width: 40,
    height: 40,
    ...RadiusStyle.input,
    alignItems: 'center',
    justifyContent: 'center',
  },
  summaryTextCol: { flex: 1 },
  summaryTitle: { ...typographyStyles.calloutBold },
  summarySubtitle: { ...typographyStyles.caption1, marginTop: 2 },

  // Role section header
  roleHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginTop: 18,
    marginBottom: Spacing.sm,
    marginHorizontal: Spacing.xxl,
  },
  roleHeaderLeft: { flexDirection: 'row', alignItems: 'center', gap: 7 },
  roleDot: { width: 4, height: 14, borderRadius: 2 },
  roleName: { fontSize: 15, fontWeight: '700' },
  roleCountChip: { paddingHorizontal: Spacing.sm, paddingVertical: 2, borderRadius: Radius.chip },
  roleCountText: { ...typographyStyles.caption2Bold },

  // User row
  userRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.md,
    marginHorizontal: Spacing.lg,
    marginVertical: Spacing.xs,
    paddingHorizontal: 14,
    paddingVertical: 11,
    ...RadiusStyle.card,
    borderWidth: 0.5,
  },
  userTextCol: { flex: 1 },
  userNameRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  userName: { ...typographyStyles.calloutBold, flexShrink: 1 },
  levelBadge: { paddingHorizontal: 5, paddingVertical: 1, borderRadius: Radius.chip },
  levelBadgeText: { fontSize: 10, fontWeight: '700', lineHeight: 14 },
  userSubtitle: { ...typographyStyles.caption1, marginTop: 2 },
});
