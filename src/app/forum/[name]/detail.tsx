/**
 * Forum Detail Page (吧信息) — 对齐 Kotlin ForumDetailPage
 *
 * Kotlin ForumDetailPage 布局:
 *   Avatar + 吧名 → 统计卡片 (关注 | 贴子) → 简介 Chip + slogan + intro
 *
 * iOS 26+ design: grouped cards, SF Symbols icon circles, haptics,
 * staggered entrance. Extra sections (吧务团队 / 吧成员 / 吧规 入口、
 * 吧数据中心) are RN extensions on top of the Kotlin baseline.
 */

import React, { useCallback } from 'react';
import {
  View,
  ScrollView,
  StyleSheet,
  Text,
    RefreshControl,
} from 'react-native';
import { useLocalSearchParams, useRouter, Stack } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { hapticForScene } from '@/theme/hapticsMap';

import { SymbolView } from '@/components/ui/SymbolView';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { Avatar } from '@/components/ui/Avatar';
import { ErrorState } from '@/components/ui/ErrorState';
import { useThemeColors } from '@/theme/ThemeContext';
import {Shadows, Spacing, RadiusStyle, Radius} from '@/theme';
import { typographyStyles } from '@/theme/typography';
import { forumDetail, getForumDetail } from '@/services/api/endpoints/forum';
import { contentToText, formatCount, buildForumUrl } from '@/utils';
import { openLink } from '@/utils/linkOpener';
import { SkeletonList } from '../../../components/ui/Skeleton';
import { useAsyncData } from '@/hooks/useAsyncData';
import { pick } from '@/utils/protoFields';
import type { ForumDetail } from '@/types';

/** Navigation entries (吧务团队 / 吧成员 / 吧规) */
const NAV_ITEMS = [
  { key: 'bawu', title: '吧务团队', subtitle: '查看本吧管理团队', icon: 'person.2.fill', tint: '#007AFF' },
  { key: 'members', title: '吧成员', subtitle: '查看本吧成员信息', icon: 'person.3.fill', tint: '#34C759' },
  { key: 'rules', title: '吧规', subtitle: '发帖前请先阅读吧规', icon: 'doc.text.fill', tint: '#FF9500' },
] as const;

// ────────────────────────────────────────────────────────────
// Page
// ────────────────────────────────────────────────────────────

export default function ForumDetailPage() {
  const { name, forumId } = useLocalSearchParams<{ name: string; forumId: string }>();
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const { colors } = useThemeColors();

  // 单次加载样板见 useAsyncData（loading/refreshing/error + 首载 + 竞态守卫）；
  // getForumDetail 只是补充数据（吧数据中心），失败不阻塞主数据展示，仅留日志。
  const { data, loading, refreshing, error, refresh } = useAsyncData<{
    detail: ForumDetail;
    extra: unknown;
  }>({
    fetcher: async () => {
      const [detailData, extraData] = await Promise.all([
        forumDetail(forumId),
        getForumDetail(forumId).catch((e: unknown) => {
          console.warn('[ForumDetail] getForumDetail failed, using forumDetail data only:', e);
          return null;
        }),
      ]);
      return { detail: detailData, extra: extraData ?? null };
    },
    enabled: !!forumId,
  });
  const detail = data?.detail ?? null;
  const extra = data?.extra ?? null;

  const handleRefresh = useCallback(async () => {
    await refresh();
    hapticForScene('toggle');
  }, [refresh]);

  const handleNav = useCallback(
    (route: string) => {
      hapticForScene('press');
      router.push(
        `/forum/${encodeURIComponent(name || '')}/${route}?forumId=${encodeURIComponent(forumId || '')}`,
      );
    },
    [name, forumId, router],
  );

  const handleOpenInBrowser = useCallback(() => {
    hapticForScene('press');
    void openLink(buildForumUrl(name || ''));
  }, [name]);

  // ── Derived data (tolerates proto snake_case / camelCase) ──
  // pick 语义见 utils/protoFields：数值字段保留真实 0（member_count: 0 等），
  // 字符串字段跳过空串。
  const extraObj = extra as Record<string, unknown> | null;
  const extraForum: unknown = extraObj?.forum_info ?? extraObj?.forumInfo ?? extraObj?.forum ?? extraObj;
  const slogan: string =
    (detail as unknown as { slogan?: string })?.slogan ?? pick<string>(extraForum, 'slogan') ?? '';
  const intro: string =
    detail?.intro || contentToText(pick<string>(extraForum, 'content')).trim() || '';
  const memberCount = Number(detail?.memberCount ?? pick<number>(extraForum, 'member_count', 'memberCount') ?? 0);
  const threadCount = Number(detail?.threadCount ?? pick<number>(extraForum, 'thread_count', 'threadCount') ?? 0);
  const postCountRaw = pick<number>(extraForum, 'post_num', 'postNum', 'post_count', 'postCount');
  const postCount = postCountRaw !== undefined ? Number(postCountRaw) : null;
  const hotText: string = pick<string>(extraForum, 'hot_text', 'hotText') ?? '';
  const recomReason: string = pick<string>(extraForum, 'recom_reason', 'recomReason') ?? '';

  const stats: { label: string; value: string }[] = [
    { label: '关注', value: formatCount(memberCount) },
    { label: '主题', value: formatCount(threadCount) },
  ];
  if (postCount !== null && !Number.isNaN(postCount)) {
    stats.push({ label: '回贴', value: formatCount(postCount) });
  }

  const groupBg = colors.groupFill;

  // ── Loading ──
  if (loading && !detail) {
    return (
      <View style={[styles.container, { backgroundColor: colors.background }]}>
        <Stack.Screen options={{ title: '吧信息' }} />
        <SkeletonList count={5} variant="card" />
      </View>
    );
  }

  // ── Error ──
  if (error && !detail) {
    return (
      <View style={[styles.container, { backgroundColor: colors.background }]}>
        <Stack.Screen options={{ title: '吧信息' }} />
        <ErrorState title="加载失败" message={error} onRetry={handleRefresh} retryLabel="重试" />
      </View>
    );
  }

  return (
    <View style={[styles.container, { backgroundColor: colors.background }]}>
      <Stack.Screen options={{ title: '吧信息' }} />
      <ScrollView
        contentContainerStyle={[styles.scrollContent, { paddingTop: insets.top + 66, paddingBottom: insets.bottom + 32 }]}
        showsVerticalScrollIndicator={false}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={handleRefresh} tintColor={colors.primary} />
        }
      >
        {/* ── 资料卡：avatar + name + slogan ── */}
        <View style={[styles.infoCard, { backgroundColor: colors.card, ...Shadows.card }]}>
          <Avatar
            source={detail?.avatar || pick<string>(extraForum, 'avatar') || undefined}
            initials={(name || '吧').charAt(0)}
            size={76}
          />
          <Text style={[styles.infoTitle, { color: colors.text }]} numberOfLines={1}>
            {name}吧
          </Text>
          {slogan ? (
            <Text style={[styles.infoSlogan, { color: colors.textSecondary }]} numberOfLines={2}>
              {slogan}
            </Text>
          ) : null}
          {detail?.isLike ? (
            <View style={[styles.followedChip, { backgroundColor: colors.primary + '1A' }]}>
              <SymbolView name="checkmark.seal.fill" size={12} tintColor={colors.primary} />
              <Text style={[styles.followedChipText, { color: colors.primary }]}>已关注</Text>
            </View>
          ) : null}
        </View>

        {/* ── Stats (对齐 Kotlin StatCardItem 行) ── */}
        <View style={[styles.statsCard, { backgroundColor: colors.card, ...Shadows.card }]}>
          {stats.map((s, i) => (
            <React.Fragment key={s.label}>
              {i > 0 && <View style={[styles.statDivider, { backgroundColor: colors.separator }]} />}
              <View style={styles.statItem}>
                <Text style={[styles.statValue, { color: colors.text }]}>{s.value}</Text>
                <Text style={[styles.statLabel, { color: colors.textTertiary }]}>{s.label}</Text>
              </View>
            </React.Fragment>
          ))}
        </View>

        {/* ── Quick links: 吧务团队 / 吧成员 / 吧规 ── */}
        <>
          <Text style={[styles.sectionTitle, { color: colors.textSecondary }]}>吧管理</Text>
          <View style={[styles.group, { backgroundColor: groupBg }]}>
            {NAV_ITEMS.map((item, idx) => (
              <React.Fragment key={item.key}>
                {idx > 0 && <View style={[styles.rowSeparator, { backgroundColor: colors.divider }]} />}
                <HdrPressable
                  style={({ pressed }) => [styles.navRow, { opacity: pressed ? 0.7 : 1 }]}
                  onPress={() => handleNav(item.key)}
                  accessibilityRole="button"
                  accessibilityLabel={item.title}
                >
                  <View style={[styles.iconCircle, { backgroundColor: item.tint + '1F' }]}>
                    <SymbolView name={item.icon as any} size={17} tintColor={item.tint} />
                  </View>
                  <View style={styles.navTextCol}>
                    <Text style={[styles.navTitle, { color: colors.text }]}>{item.title}</Text>
                    <Text style={[styles.navSubtitle, { color: colors.textTertiary }]}>{item.subtitle}</Text>
                  </View>
                  <SymbolView name="chevron.right" size={13} weight="semibold" tintColor={colors.textDisabled} />
                </HdrPressable>
              </React.Fragment>
            ))}
          </View>
        </>

        {/* ── Intro (对齐 Kotlin: Chip 简介 + slogan + intro) ── */}
        {intro ? (
          <>
            <Text style={[styles.sectionTitle, { color: colors.textSecondary }]}>简介</Text>
            <View style={[styles.introCard, { backgroundColor: colors.card, ...Shadows.card }]}>
              <Text style={[styles.introText, { color: colors.textSecondary }]} selectable>
                {intro}
              </Text>
            </View>
          </>
        ) : null}

        {/* ── Data center extras (getForumDetail, if available) ── */}
        {hotText || recomReason ? (
          <>
            <Text style={[styles.sectionTitle, { color: colors.textSecondary }]}>吧数据中心</Text>
            <View style={[styles.introCard, { backgroundColor: colors.card, ...Shadows.card }]}>
              {recomReason ? (
                <View style={styles.dataRow}>
                  <SymbolView name="sparkles" size={15} tintColor={colors.warning} />
                  <Text style={[styles.dataRowText, { color: colors.textSecondary }]} selectable>
                    {recomReason}
                  </Text>
                </View>
              ) : null}
              {hotText ? (
                <View style={styles.dataRow}>
                  <SymbolView name="flame.fill" size={15} tintColor={colors.error} />
                  <Text style={[styles.dataRowText, { color: colors.textSecondary }]} selectable>
                    {hotText}
                  </Text>
                </View>
              ) : null}
            </View>
          </>
        ) : null}

        {/* ── Basic info group ── */}
        <>
          <Text style={[styles.sectionTitle, { color: colors.textSecondary }]}>吧信息</Text>
          <View style={[styles.group, { backgroundColor: groupBg }]}>
            <View style={styles.infoRow}>
              <Text style={[styles.infoLabel, { color: colors.textSecondary }]}>吧名称</Text>
              <Text style={[styles.infoValue, { color: colors.text }]} numberOfLines={1}>
                {name}
              </Text>
            </View>
            <View style={[styles.rowSeparator, { backgroundColor: colors.divider }]} />
            <View style={styles.infoRow}>
              <Text style={[styles.infoLabel, { color: colors.textSecondary }]}>吧ID</Text>
              <Text style={[styles.infoValue, { color: colors.text }]} numberOfLines={1} selectable>
                {forumId}
              </Text>
            </View>
            <View style={[styles.rowSeparator, { backgroundColor: colors.divider }]} />
            <HdrPressable
              style={({ pressed }) => [styles.infoRow, { opacity: pressed ? 0.7 : 1 }]}
              onPress={handleOpenInBrowser}
              accessibilityRole="button"
              accessibilityLabel="在浏览器中打开"
            >
              <Text style={[styles.infoLabel, { color: colors.textSecondary }]}>在浏览器中打开</Text>
              <View style={styles.infoValueRow}>
                <SymbolView name="safari" size={15} tintColor={colors.primary} />
                <SymbolView name="chevron.right" size={13} weight="semibold" tintColor={colors.textDisabled} />
              </View>
            </HdrPressable>
          </View>
        </>
      </ScrollView>
    </View>
  );
}

// ────────────────────────────────────────────────────────────
// Styles
// ────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: { flex: 1 },
  scrollContent: { paddingTop: Spacing.md },

  // 资料卡样式
  infoCard: {
    alignItems: 'center',
    marginHorizontal: Spacing.lg,
    paddingVertical: 24,
    paddingHorizontal: Spacing.lg,
    ...RadiusStyle.card,
    overflow: 'hidden',
  },
  infoTitle: { fontSize: 24, fontWeight: '700', marginTop: Spacing.md, letterSpacing: -0.4 },
  infoSlogan: {
    fontSize: 13,
    lineHeight: 19,
    marginTop: 6,
    textAlign: 'center',
    paddingHorizontal: Spacing.md,
  },
  followedChip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.xs,
    marginTop: 10,
    paddingHorizontal: 10,
    paddingVertical: Spacing.xs,
    ...RadiusStyle.chip,
  },
  followedChipText: { ...typographyStyles.caption1Bold },

  // Stats
  statsCard: {
    flexDirection: 'row',
    alignItems: 'center',
    marginHorizontal: Spacing.lg,
    marginTop: Spacing.md,
    paddingVertical: 18,
    ...RadiusStyle.card,
    overflow: 'hidden',
  },
  statItem: { flex: 1, alignItems: 'center', gap: 3 },
  statValue: { fontSize: 21, fontWeight: '700', fontVariant: ['tabular-nums'] },
  statLabel: { ...typographyStyles.caption1 },
  statDivider: { width: StyleSheet.hairlineWidth, height: 30 },

  // Section title
  sectionTitle: {
    ...typographyStyles.footnoteBold,
    marginTop: 22,
    marginBottom: Spacing.sm,
    marginHorizontal: Spacing.xxl,
  },

  // Grouped list container (iOS settings style)
  group: { marginHorizontal: Spacing.lg, borderRadius: Radius.card, overflow: 'hidden' },
  rowSeparator: { height: StyleSheet.hairlineWidth, marginLeft: 62 },

  // Nav rows
  navRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 13,
    paddingHorizontal: 14,
    paddingVertical: Spacing.md,
  },
  iconCircle: {
    width: 34,
    height: 34,
    ...RadiusStyle.chip,
    alignItems: 'center',
    justifyContent: 'center',
  },
  navTextCol: { flex: 1 },
  navTitle: { fontSize: 16, fontWeight: '500' },
  navSubtitle: { ...typographyStyles.caption1, marginTop: 1 },

  // Intro / data center card
  introCard: {
    marginHorizontal: Spacing.lg,
    ...RadiusStyle.card,
    padding: Spacing.lg,
  },
  introText: { fontSize: 15, lineHeight: 23 },
  dataRow: { flexDirection: 'row', alignItems: 'flex-start', gap: Spacing.sm, paddingVertical: Spacing.xs },
  dataRowText: { flex: 1, fontSize: 14, lineHeight: 21 },

  // Info rows
  infoRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: Spacing.lg,
    paddingVertical: 13,
    gap: Spacing.md,
  },
  infoLabel: { ...typographyStyles.subhead },
  infoValue: { fontSize: 15, fontWeight: '500', flexShrink: 1 },
  infoValueRow: { flexDirection: 'row', alignItems: 'center', gap: Spacing.sm },
});
