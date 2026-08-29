/**
 * Forum Members Page (吧成员) — shows forum member groups + level rank.
 *
 * Data:
 * - 成员 segment: getMemberInfo(forumId) →
 *     { memberGroupInfo: [{ memberGroupType, memberGroupNum, memberGroupList: [...] }],
 *       forumMemberInfo: { isLike, userLevel, levelName, curScore, levelupScore } }
 *   (proto: GetMemberInfoResponseData.member_group_info → MemberGroupInfo,
 *           forum_member_info → ForumMember)
 *   Fallback: 当 proto 失败或返回空时降级到 getMemberUsers(forumName) +
 *             parseMemberUsersHtml（web HTML 解析，风险较高）。
 * - 等级排行 segment: getRankUsers(forumName, pn) + parseRankUsersHtml
 *   （web HTML 解析，支持 pn 分页；解析失败返回空数组由 UI 容错）。
 *
 * iOS 26 design: SwiftUI segmented Picker（成员 | 等级排行），成员段为
 * 分组 3 列网格 + 等级徽章，排行段为行式列表；点击成员跳用户主页。
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  View,
  StyleSheet,
  Text,
  Pressable,
  RefreshControl,
  useWindowDimensions,
} from 'react-native';
import { LegendList } from '@legendapp/list/react-native';
import { useLocalSearchParams, useRouter, Stack } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Picker, Text as SWText } from '@expo/ui/swift-ui';
import { pickerStyle, tag } from '@expo/ui/swift-ui/modifiers';
import { hapticForScene } from '@/theme/hapticsMap';
import { HOT_RANK_COLORS } from '@/constants/rank';

import { SymbolView } from '@/components/ui/SymbolView';
import { Avatar } from '@/components/ui/Avatar';
import { ErrorState } from '@/components/ui/ErrorState';
import { EmptyState } from '@/components/ui/EmptyState';
import { LoadMoreFooter } from '@/components/ui/LoadMoreFooter';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { useThemeColors } from '@/theme/ThemeContext';
import {Spacing, RadiusStyle, Radius} from '@/theme';
import { typographyStyles } from '@/theme/typography';
import { SkeletonList } from '../../../components/ui/Skeleton';
import { getMemberInfo } from '@/services/api/endpoints/forum';
import { getMemberUsers, getRankUsers, type MemberUserItem, type RankUserItem } from '@/services/api/endpoints/social';
import { formatCount } from '@/utils';
import { parseForumUser, flattenGroupRows, type GroupedRow, type FlattenedForumUser } from '@/utils/forumUsers';
import { usePagedList } from '@/hooks/usePagedList';
import { useAsyncData } from '@/hooks/useAsyncData';

// ────────────────────────────────────────────────────────────
// Types & parsing (tolerates snake_case proto / camelCase normalized fields)
// ────────────────────────────────────────────────────────────

type MemberUser = FlattenedForumUser;

interface MemberGroup {
  type: string;
  num: number;
  users: MemberUser[];
}

interface MyMemberInfo {
  isLike: boolean;
  userLevel: number;
  levelName: string;
  curScore: number;
  levelupScore: number;
}

type Segment = 'members' | 'rank';

/** member_group_type → Chinese label (fallback: raw value) */
const GROUP_TYPE_LABELS: Record<string, string> = {
  manager: '吧务成员',
  god: '本吧大神',
  active: '活跃成员',
  member: '普通成员',
  friend: '互关好友',
};

function parseGroups(data: any): MemberGroup[] {
  const rawGroups: any[] =
    data?.memberGroupInfo ??
    data?.member_group_info ??
    data?.memberInfo ??
    [];
  return rawGroups
    .map((g) => ({
      type: String(g?.member_group_type ?? g?.memberGroupType ?? ''),
      num: Number(g?.member_group_num ?? g?.memberGroupNum ?? 0),
      users: (g?.member_group_list ?? g?.memberGroupList ?? []).map((u: any) => parseForumUser(u)),
    }))
    .filter((g) => g.users.length > 0 || g.num > 0);
}

function parseMyMemberInfo(data: any): MyMemberInfo | null {
  const m = data?.forum_member_info ?? data?.forumMemberInfo ?? null;
  if (!m) return null;
  return {
    isLike: Number(m?.is_like ?? m?.isLike ?? 0) === 1,
    userLevel: Number(m?.user_level ?? m?.userLevel ?? 0),
    levelName: String(m?.level_name ?? m?.levelName ?? ''),
    curScore: Number(m?.cur_score ?? m?.curScore ?? 0),
    levelupScore: Number(m?.levelup_score ?? m?.levelupScore ?? 0),
  };
}

/**
 * web HTML 解析的成员没有 uid（parseMemberUsersHtml 只给 userName/portrait/level），
 * 归并到 FlattenedForumUser 时 userId 留空 → 列表内点击跳转自动跳过。
 */
function mapWebMember(user: MemberUserItem): FlattenedForumUser {
  return {
    userId: '',
    userName: user.userName,
    nameShow: user.userName,
    portrait: user.portrait,
    userLevel: user.level,
    levelName: '',
  };
}

const MIN_GRID_COL_WIDTH = 96;
const GRID_HORIZONTAL_PADDING = 24;

type Row = GroupedRow<MemberUser>;

// ────────────────────────────────────────────────────────────
// Page
// ────────────────────────────────────────────────────────────

export default function ForumMembersPage() {
  const { name, forumId } = useLocalSearchParams<{ name: string; forumId: string }>();
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { colors } = useThemeColors();
  const { width: screenWidth } = useWindowDimensions();
  const gridCols = useMemo(
    () =>
      Math.max(
        2,
        Math.min(
          6,
          Math.floor((screenWidth - GRID_HORIZONTAL_PADDING) / MIN_GRID_COL_WIDTH),
        ),
      ),
    [screenWidth],
  );

  // ── Segment ──
  const [activeSegment, setActiveSegment] = useState<Segment>('members');

  const handleSegmentChange = useCallback((value: Segment) => {
    hapticForScene('toggle');
    setActiveSegment(value);
  }, []);

  // ── 成员段：proto getMemberInfo 为主，web getMemberUsers 兜底 ──
  // 单次加载样板见 useAsyncData（loading/refreshing/error + 首载 + 竞态守卫；
  // forumId 缺失时不请求，直接渲染空态，不卡骨架）
  const { data: memberData, loading, refreshing, error, refresh } = useAsyncData<{
    groups: MemberGroup[];
    myInfo: MyMemberInfo | null;
  }>({
    fetcher: async () => {
      let g: MemberGroup[] = [];
      let mi: MyMemberInfo | null = null;
      try {
        const d = await getMemberInfo(forumId);
        g = parseGroups(d);
        mi = parseMyMemberInfo(d);
      } catch {
        // proto 失败 → 落入 web 降级
      }
      if (g.length === 0) {
        // proto 为空/失败 → 降级 getMemberUsers（web HTML 解析，可能失败）
        try {
          const web = await getMemberUsers(name || '', 1);
          if (web.items.length > 0) {
            g = [{ type: 'member', num: web.items.length, users: web.items.map(mapWebMember) }];
          }
        } catch (e: unknown) {
          // 全链路失败才抛给 hook：首载置 error，刷新保留旧数据 + warn
          if (mi === null && g.length === 0) throw e;
        }
      }
      return { groups: g, myInfo: mi };
    },
    enabled: !!forumId,
  });
  const groups = memberData?.groups ?? [];
  const myInfo = memberData?.myInfo ?? null;

  // ── 等级排行段：getRankUsers + parseRankUsersHtml（web HTML，支持 pn 分页）──
  const rankFetcher = useCallback(
    async (p: number, params: { fname: string }, signal?: AbortSignal) => {
      const res = await getRankUsers(params.fname, p, signal);
      // HTML 无 has_more 标记：以本页是否解析出条目作为分页信号，空页即到底。
      return { items: res.items, hasMore: res.items.length > 0, nextPage: p + 1 };
    },
    [],
  );
  const rankPaged = usePagedList<RankUserItem, { fname: string }>({
    fetcher: rankFetcher,
    params: { fname: name || '' },
    maxItems: 200,
  });
  const {
    items: rankItems,
    loading: rankLoading,
    refreshing: rankRefreshing,
    loadingMore: rankLoadingMore,
    hasMore: rankHasMore,
    error: rankError,
    load: rankLoad,
    refresh: rankRefresh,
    loadMore: rankLoadMore,
  } = rankPaged;

  // 首次切到「等级排行」段时再加载（懒加载，切换回来不重复请求）
  const rankLoadedRef = useRef(false);
  useEffect(() => {
    if (activeSegment === 'rank' && !rankLoadedRef.current) {
      rankLoadedRef.current = true;
      rankLoad(1);
    }
  }, [activeSegment, rankLoad]);

  const handleRefresh = useCallback(async () => {
    if (activeSegment === 'rank') {
      await rankRefresh();
      hapticForScene('toggle');
      return;
    }
    await refresh();
    hapticForScene('toggle');
  }, [activeSegment, rankRefresh, refresh]);

  const handleRankLoadMore = useCallback(() => {
    if (!rankHasMore || rankLoadingMore || rankLoading) return;
    rankLoadMore();
  }, [rankHasMore, rankLoadingMore, rankLoading, rankLoadMore]);

  const handleUserPress = useCallback(
    (user: MemberUser) => {
      if (!user.userId) return; // web 解析成员无 uid，无法跳转
      hapticForScene('press');
      router.push({ pathname: '/user/[uid]', params: { uid: user.userId } });
    },
    [router],
  );

  // Flatten groups → header + chunked grid rows
  const rows = useMemo<Row[]>(
    () =>
      flattenGroupRows(
        groups.map((g) => ({
          title: GROUP_TYPE_LABELS[g.type] || g.type || '成员',
          count: g.num || g.users.length,
          items: g.users,
        })),
        (user) => user.userId,
        gridCols,
        'member',
      ),
    [groups, gridCols],
  );

  const renderCell = useCallback(
    (user: MemberUser | undefined, cellIndex: number) => {
      if (!user) return <View key={`empty-${cellIndex}`} style={styles.gridCell} />;
      const displayName = user.nameShow || user.userName || '?';
      return (
        <Pressable
          key={user.userId || `${displayName}-${cellIndex}`}
          style={({ pressed }) => [
            styles.gridCell,
            { opacity: pressed ? 0.7 : 1, transform: [{ scale: pressed ? 0.96 : 1 }] },
          ]}
          onPress={() => handleUserPress(user)}
          accessibilityRole="button"
          accessibilityLabel={displayName}
        >
          <Avatar source={user.portrait || undefined} initials={displayName.charAt(0)} size={58} />
          <Text style={[styles.cellName, { color: colors.text }]} numberOfLines={1}>
            {displayName}
          </Text>
          {user.userLevel > 0 ? (
            <View style={[styles.cellLevelBadge, { backgroundColor: `${colors.primary}26` }]}>
              <Text style={[styles.cellLevelText, { color: colors.primary }]}>Lv.{user.userLevel}</Text>
            </View>
          ) : (
            <Text style={[styles.cellLevelName, { color: colors.textTertiary }]} numberOfLines={1}>
              {user.levelName || ' '}
            </Text>
          )}
        </Pressable>
      );
    },
    [colors, handleUserPress],
  );

  const renderItem = useCallback(
    ({ item }: { item: Row }) => {
      if (item.kind === 'header') {
        return (
          <View style={styles.groupHeader}>
            <View style={styles.groupHeaderLeft}>
              <View style={[styles.groupDot, { backgroundColor: colors.primary }]} />
              <Text style={[styles.groupLabel, { color: colors.text }]}>{item.title}</Text>
            </View>
            <View style={[styles.groupCountChip, { backgroundColor: colors.surfaceSecondary }]}>
              <Text style={[styles.groupCountText, { color: colors.textTertiary }]}>
                {item.count > 0 ? `${item.count}人` : ''}
              </Text>
            </View>
          </View>
        );
      }
      if (item.kind !== 'grid') return null;
      // Pad the last row so every cell keeps an equal flex width
      const cells: (MemberUser | undefined)[] = [...item.items];
      while (cells.length < gridCols) cells.push(undefined);
      return (
        <View style={styles.gridRow}>{cells.map((u, i) => renderCell(u, i))}</View>
      );
    },
    [colors, renderCell, gridCols],
  );

  const groupBg = colors.groupFill;
  const levelProgress =
    myInfo && myInfo.levelupScore > 0
      ? Math.min((myInfo.curScore / myInfo.levelupScore) * 100, 100)
      : 0;

  const memberKeyExtractor = useCallback((item: Row) => item.key, []);
  const memberItemType = useCallback((item: Row) => item.kind, []);
  const listHeader = useCallback(
    () =>
      myInfo && myInfo.isLike && myInfo.userLevel > 0 ? (
        <View style={[styles.myCard, { backgroundColor: groupBg }]}>
          <View style={styles.myCardTop}>
            <View style={[styles.myLevelBadge, { backgroundColor: `${colors.primary}26` }]}>
              <Text style={[styles.myLevelBadgeText, { color: colors.primary }]}>Lv.{myInfo.userLevel}</Text>
            </View>
            <View style={styles.myTextCol}>
              <Text style={[styles.myTitle, { color: colors.text }]} numberOfLines={1}>
                我在{name}吧
              </Text>
              <Text style={[styles.mySubtitle, { color: colors.textTertiary }]} numberOfLines={1}>
                {myInfo.levelName || ' '}
                {myInfo.levelupScore > 0
                  ? `  ·  ${myInfo.curScore}/${myInfo.levelupScore}`
                  : ''}
              </Text>
            </View>
            <SymbolView name="star.fill" size={18} tintColor={colors.warning} />
          </View>
          {myInfo.levelupScore > 0 && (
            <View style={[styles.myTrack, { backgroundColor: colors.surfaceSecondary }]}>
              <View
                style={[styles.myFill, { width: `${levelProgress}%`, backgroundColor: colors.primary }]}
              />
            </View>
          )}
        </View>
      ) : null,
    [myInfo, groupBg, name, colors, levelProgress],
  );
  const listEmpty = useCallback(
    () =>
      !loading ? (
        <EmptyState
          icon={'person.3' as any}
          title="暂无成员信息"
          description="这个吧还没有公开成员数据"
          actionLabel="重试"
          onAction={handleRefresh}
        />
      ) : null,
    [loading, handleRefresh],
  );

  // ── 等级排行行渲染 ──
  const renderRankItem = useCallback(
    ({ item, index }: { item: RankUserItem; index: number }) => {
      const rank = index + 1;
      const rankColor = rank <= 3 ? HOT_RANK_COLORS[rank - 1] : colors.textTertiary;
      const displayName = item.userName || '未知用户';
      return (
        <View style={[styles.rankRow, { backgroundColor: colors.card }]}>
          <Text style={[styles.rankIndex, { color: rankColor }]}>{rank}</Text>
          <Avatar source={undefined} initials={displayName.charAt(0)} size={40} />
          <View style={styles.rankBody}>
            <View style={styles.rankNameRow}>
              <Text style={[styles.rankName, { color: colors.text }]} numberOfLines={1}>
                {displayName}
              </Text>
              {item.isVip && <SymbolView name="crown.fill" size={13} tintColor={colors.warning} />}
            </View>
            <Text style={[styles.rankSub, { color: colors.textTertiary }]} numberOfLines={1}>
              {item.exp > 0 ? `贡献值 ${formatCount(item.exp)}` : item.level > 0 ? '本吧等级成员' : '本吧吧友'}
            </Text>
          </View>
          {item.level > 0 ? (
            <View style={[styles.rankLevelBadge, { backgroundColor: `${colors.primary}26` }]}>
              <Text style={[styles.rankLevelText, { color: colors.primary }]}>Lv.{item.level}</Text>
            </View>
          ) : (
            <View style={styles.rankVipSlot}>
              <SymbolView name="person.fill" size={13} tintColor={colors.textTertiary} />
            </View>
          )}
        </View>
      );
    },
    [colors],
  );

  const rankKeyExtractor = useCallback(
    // 索引 key：RankUserItem 无稳定 id（HTML 解析产物，同名用户可重复出现，
    // userName 唯一性不可靠——旧 key `rk-${userName}-${index}` 遇重名会
    // 键错位）。列表仅"尾部分页追加 + 刷新全量替换"（无插入/重排），索引
    // key 对既有行稳定；行渲染无内部状态，替换时重挂载无副作用。
    (_item: RankUserItem, index: number) => `rk-${index}`,
    [],
  );
  const rankListEmpty = useCallback(
    () =>
      !rankLoading ? (
        <EmptyState
          icon={'trophy' as any}
          title="暂无排行数据"
          description="等级排行解析失败，或该吧暂无公开排行"
        />
      ) : null,
    [rankLoading],
  );

  const rankListFooter = useCallback(
    () => (
      <LoadMoreFooter
        hasMore={rankHasMore}
        loading={rankLoadingMore}
        colors={colors}
        onLoadMore={handleRankLoadMore}
      />
    ),
    [rankHasMore, rankLoadingMore, colors, handleRankLoadMore],
  );

  return (
    <View style={[styles.container, { backgroundColor: colors.background }]}>
      <Stack.Screen options={{ title: '吧成员' }} />

      {/* ── Segmented tabs: 成员 | 等级排行 ── */}
      <View style={styles.segmentBar}>
        <ThemedHost matchContents>
          <Picker
            selection={activeSegment}
            onSelectionChange={handleSegmentChange}
            modifiers={[pickerStyle('segmented')]}
          >
            <SWText key="members" modifiers={[tag('members')]}>成员</SWText>
            <SWText key="rank" modifiers={[tag('rank')]}>等级排行</SWText>
          </Picker>
        </ThemedHost>
      </View>

      {activeSegment === 'rank' ? (
        // ───────────────────────── 等级排行 ─────────────────────────
        rankLoading && rankItems.length === 0 ? (
          <SkeletonList count={8} variant="row" style={styles.rankSkeleton} />
        ) : rankError && rankItems.length === 0 ? (
          <ErrorState title="加载失败" message={rankError} onRetry={() => rankLoad(1)} retryLabel="重试" />
        ) : (
          <LegendList
            data={rankItems}
            keyExtractor={rankKeyExtractor}
            renderItem={renderRankItem}
            contentContainerStyle={[styles.rankListContent, { paddingTop: insets.top + 66, paddingBottom: insets.bottom + 24 }]}
            refreshControl={
              <RefreshControl refreshing={rankRefreshing} onRefresh={handleRefresh} tintColor={colors.primary} />
            }
            ListEmptyComponent={rankListEmpty}
            ListFooterComponent={rankListFooter}
            onEndReached={handleRankLoadMore}
            onEndReachedThreshold={0.4}
            drawDistance={250}
          />
        )
      ) : (
        // ───────────────────────── 吧成员 ─────────────────────────
        loading && rows.length === 0 ? (
          <SkeletonList count={6} variant="card" />
        ) : error && rows.length === 0 ? (
          <ErrorState title="加载失败" message={error} onRetry={handleRefresh} retryLabel="重试" />
        ) : (
          <LegendList
            data={rows}
            keyExtractor={memberKeyExtractor}
            renderItem={renderItem}
            getItemType={memberItemType}
            contentContainerStyle={[styles.listContent, { paddingTop: insets.top + 66, paddingBottom: insets.bottom + 24 }]}
            refreshControl={
              <RefreshControl refreshing={refreshing} onRefresh={handleRefresh} tintColor={colors.primary} />
            }
            ListHeaderComponent={listHeader}
            ListEmptyComponent={listEmpty}
            drawDistance={250}
          />
        )
      )}
    </View>
  );
}

// ────────────────────────────────────────────────────────────
// Styles
// ────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: { flex: 1 },

  // Segment bar
  segmentBar: {
    flexDirection: 'row',
    justifyContent: 'center',
    paddingHorizontal: Spacing.lg,
    paddingTop: 10,
    paddingBottom: Spacing.xs,
  },

  // Shared list content
  listContent: { paddingTop: Spacing.md },
  rankListContent: { paddingTop: Spacing.sm, paddingHorizontal: Spacing.md },
  rankSkeleton: { paddingHorizontal: Spacing.lg, paddingTop: Spacing.md },

  // My membership card
  myCard: {
    marginHorizontal: Spacing.lg,
    marginBottom: 6,
    paddingHorizontal: 14,
    paddingVertical: 13,
    ...RadiusStyle.card,
  },
  myCardTop: { flexDirection: 'row', alignItems: 'center', gap: 10 },
  myLevelBadge: { paddingHorizontal: 7, paddingVertical: 3, borderRadius: Radius.chip },
  myLevelBadgeText: { fontSize: 12, fontWeight: '700' },
  myTextCol: { flex: 1 },
  myTitle: { ...typographyStyles.subheadBold },
  mySubtitle: { ...typographyStyles.caption1, marginTop: 1 },
  myTrack: { height: 4, borderRadius: 2, overflow: 'hidden', marginTop: 11 },
  myFill: { height: 4, borderRadius: 2 },

  // Group header
  groupHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginTop: 18,
    marginBottom: Spacing.sm,
    marginHorizontal: Spacing.xxl,
  },
  groupHeaderLeft: { flexDirection: 'row', alignItems: 'center', gap: 7 },
  groupDot: { width: 4, height: 14, borderRadius: 2 },
  groupLabel: { fontSize: 15, fontWeight: '700' },
  groupCountChip: { paddingHorizontal: Spacing.sm, paddingVertical: 2, borderRadius: Radius.chip },
  groupCountText: { ...typographyStyles.caption2Bold },

  // Member grid
  gridRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    paddingHorizontal: Spacing.md,
    paddingVertical: Spacing.xs,
  },
  gridCell: {
    flex: 1,
    alignItems: 'center',
    paddingVertical: 10,
    paddingHorizontal: Spacing.xs,
    ...RadiusStyle.card,
    minHeight: 108,
  },
  cellName: { ...typographyStyles.footnoteBold, marginTop: Spacing.sm, maxWidth: '100%' },
  cellLevelBadge: { paddingHorizontal: 6, paddingVertical: 1.5, borderRadius: Radius.chip, marginTop: 5 },
  cellLevelText: { fontSize: 10, fontWeight: '700', lineHeight: 13 },
  cellLevelName: { ...typographyStyles.caption2, marginTop: 5, maxWidth: '100%' },

  // Rank rows
  rankRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    marginHorizontal: 2,
    marginVertical: 5,
    paddingHorizontal: 14,
    paddingVertical: 10,
    ...RadiusStyle.card,
  },
  rankIndex: {
    width: 26,
    fontSize: 17,
    fontWeight: '800',
    fontVariant: ['tabular-nums'],
    textAlign: 'center',
  },
  rankBody: { flex: 1, gap: 2 },
  rankNameRow: { flexDirection: 'row', alignItems: 'center', gap: 6 },
  rankName: { ...typographyStyles.subheadBold, flexShrink: 1 },
  rankSub: { ...typographyStyles.caption1 },
  rankLevelBadge: {
    paddingHorizontal: 7,
    paddingVertical: 3,
    ...RadiusStyle.chip,
    minWidth: 48,
    alignItems: 'center',
  },
  rankLevelText: { fontSize: 11, fontWeight: '700' },
  rankVipSlot: {
    minWidth: 48,
    alignItems: 'center',
    paddingVertical: 3,
  },
});
