/**
 * Forum Rules Page (吧规) — 吧规只读展示（吧务编辑能力已随需求裁掉，2026-08-25）。
 *
 * 对齐 Kotlin ForumRuleDetailPage 布局：
 *   title (h5) → UserHeader (bazhu avatar + name + publishTime) →
 *   preface → rules[{ title (subtitle1), content renders }]
 *
 * Data: forumRuleDetail(forumId) →
 *   proto: { title, publish_time, preface, rules: [{ title, content: PbContent[] }], bazhu }
 *   web fallback: TiebaRes { code, data: {...} }
 */

import React, { useCallback } from 'react';
import {
  View,
  ScrollView,
  StyleSheet,
  Text,
  Pressable,
  RefreshControl,
} from 'react-native';
import { Image } from 'expo-image';
import { useLocalSearchParams, Stack } from 'expo-router';
import { hapticForScene } from '@/theme/hapticsMap';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { SymbolView } from '@/components/ui/SymbolView';
import { Avatar } from '@/components/ui/Avatar';
import { ErrorState } from '@/components/ui/ErrorState';
import { EmptyState } from '@/components/ui/EmptyState';
import { useThemeColors } from '@/theme/ThemeContext';
import {Shadows, Spacing, RadiusStyle} from '@/theme';
import { typographyStyles } from '@/theme/typography';
import { SkeletonList } from '../../../components/ui/Skeleton';
import { useAsyncData } from '@/hooks/useAsyncData';
import { forumRuleDetail } from '@/services/api/endpoints/forum';
import { openLink } from '@/utils/linkOpener';
import { htmlToText } from '@/utils/htmlSummary';
import { pick } from '@/utils/protoFields';
import type { SemanticColors } from '@/theme';

// ────────────────────────────────────────────────────────────
// Types & parsing (tolerates proto / web-fallback shapes)
// ────────────────────────────────────────────────────────────

interface RuleAuthor {
  userId: string;
  userName: string;
  nameShow: string;
  portrait: string;
}

interface RuleSection {
  title: string;
  content: RuleContent;
}

/**
 * PbContent proto 段的宽松形态：老/新 proto 与 web fallback 三段形状共存，
 * 字段均可选，渲染时再逐字段容错（不继续拆联合，避免把容错逻辑铺开到
 * 每个字段的窄化分支）。
 */
interface PbSegment {
  type?: string | number;
  text?: string;
  content?: string;
  c?: string;
  bold?: boolean;
  is_bold?: boolean;
  isBold?: boolean;
  fontWeight?: string;
  color?: string;
  font_color?: string;
  fontColor?: string;
  text_color?: string;
  quoteContent?: { content?: string; text?: string } | string | null;
  quote_content?: { content?: string; text?: string } | string | null;
  quote?: { content?: string; text?: string } | string | null;
  quote_text?: { content?: string; text?: string } | string | null;
  cdnSrc?: string;
  bigCdnSrc?: string;
  src?: string;
  bigSrc?: string;
  width?: number | string;
  height?: number | string;
  link?: string;
  url?: string;
}

type RuleContent = string | PbSegment[];

interface RuleData {
  title: string;
  publishTime: string;
  preface: string;
  author: RuleAuthor | null;
  sections: RuleSection[];
}

/** PbContent[] / string[] / string → rich content or plain text fallback */
function toContent(content: unknown): RuleContent {
  if (!content) return [];
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    // 元素按 PbSegment 宽松读取（容错形状见 PbSegment 注释）
    return content as PbSegment[];
  }
  return [];
}

function parseRuleData(res: any): RuleData | null {
  if (!res || typeof res !== 'object') return null;
  // proto 路径直接返回 data；web fallback 返回 TiebaRes { code, data } ——
  // 两条路径里 data 都是内容载体（endpoint 已各自解包），统一取 data，
  // 旧的 looksWrapped 恒等判断是死逻辑（两分支结果一致），已删。
  const d: any = res?.data ?? res;
  if (!d || typeof d !== 'object') return null;

  const title = String(pick<string>(d, 'title', 'ruleTitle', 'rule_title') ?? '');
  const publishTime = String(pick<string>(d, 'publish_time', 'publishTime') ?? '');
  const preface = String(pick<string>(d, 'preface') ?? '');

  const rawRules: any[] = d?.rules ?? d?.rule_list ?? d?.ruleList ?? [];
  let sections: RuleSection[] = rawRules
    .map((r) => ({
      title: String(pick<string>(r, 'title') ?? ''),
      content: toContent(r?.content ?? r?.contentRenders),
    }))
    .filter(
      (s) =>
        s.title ||
        (Array.isArray(s.content) ? s.content.length > 0 : Boolean(s.content)),
    );

  // Proto path returns ruleText/ruleHtml instead of a rules array.
  if (sections.length === 0 && (d?.ruleText || d?.ruleHtml)) {
    sections.push({
      title: String(pick<string>(d, 'ruleTitle', 'title') ?? ''),
      content: d?.ruleText || htmlToText(String(d?.ruleHtml ?? '')),
    });
  }

  const rawAuthor = d?.bazhu ?? d?.author ?? null;
  const author: RuleAuthor | null = rawAuthor
    ? {
        userId: String(rawAuthor?.user_id ?? rawAuthor?.userId ?? ''),
        userName: String(rawAuthor?.user_name ?? rawAuthor?.userName ?? ''),
        nameShow: String(rawAuthor?.name_show ?? rawAuthor?.nameShow ?? ''),
        portrait: String(rawAuthor?.portrait ?? ''),
      }
    : null;

  if (!title && !preface && sections.length === 0) return null;
  return { title, publishTime, preface, author, sections };
}

// ────────────────────────────────────────────────────────────
// Rich PbContent renderer
// ────────────────────────────────────────────────────────────

function RuleContentRenderer({
  content,
  colors,
}: {
  content: RuleContent;
  colors: SemanticColors;
}) {
  if (!content) return null;
  if (typeof content === 'string') {
    return (
      <Text
        style={[styles.ruleParagraph, { color: colors.textSecondary }]}
        selectable
      >
        {content}
      </Text>
    );
  }
  if (!Array.isArray(content)) return null;

  const renderSegment = (segment: PbSegment, key: number): React.ReactNode => {
    if (typeof segment === 'string') {
      return (
        <Text
          key={key}
          style={[styles.ruleParagraph, { color: colors.textSecondary }]}
          selectable
        >
          {segment}
        </Text>
      );
    }
    if (!segment || typeof segment !== 'object') return null;

    const type = segment.type ?? '';
    const numericType = Number(type);
    const text = String(segment.text ?? segment.content ?? '');
    const isBold =
      segment.bold === true ||
      segment.is_bold === true ||
      segment.isBold === true ||
      segment.fontWeight === 'bold';
    const segmentColor =
      segment.color || segment.font_color || segment.fontColor || segment.text_color;

    // Quote block (web fallback shapes; proto PbContent has no quote field).
    const quoteContent =
      segment.quoteContent ??
      segment.quote_content ??
      segment.quote ??
      segment.quote_text ??
      null;
    if (type === 'quote' || type === 'blockquote' || quoteContent) {
      const quoteText =
        typeof quoteContent === 'string'
          ? quoteContent
          : String(quoteContent?.content ?? quoteContent?.text ?? text ?? '');
      return (
        <View
          key={key}
          style={[
            styles.quoteBlock,
            {
              borderLeftColor: colors.primary,
              backgroundColor: colors.primary + '0A',
            },
          ]}
        >
          <Text style={[styles.quoteText, { color: colors.textSecondary }]} selectable>
            {quoteText}
          </Text>
        </View>
      );
    }

    // Image
    if (type === 'image' || numericType === 3 || numericType === 20) {
      const src =
        segment.cdnSrc ||
        segment.bigCdnSrc ||
        segment.src ||
        segment.bigSrc ||
        '';
      if (!src) {
        return (
          <Text
            key={key}
            style={[styles.ruleParagraph, { color: colors.textTertiary }]}
          >
            [图片]
          </Text>
        );
      }
      const width = Number(segment.width ?? 0);
      const height = Number(segment.height ?? 0);
      return (
        <Image
          key={key}
          source={{ uri: src }}
          style={[
            styles.ruleImage,
            { backgroundColor: colors.surfaceSecondary },
            width > 0 && height > 0 ? { aspectRatio: width / height } : null,
          ]}
          contentFit="cover"
          cachePolicy="memory-disk"
          recyclingKey={src}
        />
      );
    }

    // Link
    if (type === 'link' || numericType === 1) {
      const url = String(segment.link ?? segment.url ?? text ?? '');
      return (
        <Pressable
          key={key}
          onPress={() => openLink(url)}
          style={[styles.linkChip, { backgroundColor: colors.primary + '12' }]}
        >
          <SymbolView name="link" size={12} tintColor={colors.primary} />
          <Text style={[styles.linkText, { color: colors.primary }]} numberOfLines={1}>
            {text || url}
          </Text>
        </Pressable>
      );
    }

    if (type === 'linebreak' || numericType === 10) {
      return <View key={key} style={styles.lineBreak} />;
    }

    return (
      <Text
        key={key}
        style={[
          styles.ruleSegment,
          { color: segmentColor || colors.textSecondary },
          isBold && styles.ruleSegmentBold,
        ]}
        selectable
      >
        {text || segment.c || ''}
      </Text>
    );
  };

  const nodes = content.map((segment, index) => renderSegment(segment, index)).filter(Boolean);
  if (nodes.length === 0) return null;
  return <View style={styles.richFlow}>{nodes}</View>;
}

// ────────────────────────────────────────────────────────────
// Page
// ────────────────────────────────────────────────────────────

export default function ForumRulesPage() {
  const { name, forumId } = useLocalSearchParams<{ name: string; forumId: string }>();
  const insets = useSafeAreaInsets();
  const { colors } = useThemeColors();

  // 单次加载样板见 useAsyncData（loading/refreshing/error + 首载 + 竞态守卫；
  // forumId 缺失时不请求，直接以空态展示，不卡骨架）
  const { data: ruleData, loading, refreshing, error, refresh } = useAsyncData<RuleData | null>({
    fetcher: async () => parseRuleData(await forumRuleDetail(forumId)),
    enabled: !!forumId,
  });

  const handleRefresh = useCallback(async () => {
    hapticForScene('press');
    await refresh();
    hapticForScene('toggle');
  }, [refresh]);

  // ── Loading ──
  if (loading && !ruleData) {
    return (
      <View style={[styles.container, { backgroundColor: colors.background }]}>
        <Stack.Screen options={{ title: '吧规' }} />
        <SkeletonList count={4} variant="card" />
      </View>
    );
  }

  // ── Error ──
  if (error && !ruleData) {
    return (
      <View style={[styles.container, { backgroundColor: colors.background }]}>
        <Stack.Screen options={{ title: '吧规' }} />
        <ErrorState title="加载失败" message={error} onRetry={handleRefresh} retryLabel="重试" />
      </View>
    );
  }

  // ── Empty ──
  if (!ruleData) {
    return (
      <View style={[styles.container, { backgroundColor: colors.background }]}>
        <Stack.Screen options={{ title: '吧规' }} />
        <EmptyState
          icon={'doc.text' as any}
          title="暂无吧规"
          description={`${name || '这个'}吧还没有设置吧规`}
        />
      </View>
    );
  }

  const authorName = ruleData.author?.nameShow || ruleData.author?.userName || '';

  return (
    <View style={[styles.container, { backgroundColor: colors.background }]}>
      <Stack.Screen options={{ title: '吧规' }} />
      <ScrollView
        contentContainerStyle={[styles.scrollContent, { paddingTop: insets.top + 66, paddingBottom: insets.bottom + 32 }]}
        showsVerticalScrollIndicator={false}
        refreshControl={
          <RefreshControl refreshing={refreshing} onRefresh={handleRefresh} tintColor={colors.primary} />
        }
      >
        {/* ── Title ── */}
        <Text style={[styles.title, { color: colors.text }]} selectable>
          {ruleData.title || `${name || '本'}吧吧规`}
        </Text>

        {/* ── Author row (对齐 Kotlin UserHeader) ── */}
        {(ruleData.author || ruleData.publishTime) && (
          <View style={styles.authorRow}>
            <Avatar
              source={ruleData.author?.portrait || undefined}
              initials={(authorName || '吧').charAt(0)}
              size={40}
            />
            <View style={styles.authorTextCol}>
              <Text style={[styles.authorName, { color: colors.text }]} numberOfLines={1}>
                {authorName || `${name}吧吧务团队`}
              </Text>
              {ruleData.publishTime ? (
                <Text style={[styles.publishTime, { color: colors.textTertiary }]} numberOfLines={1}>
                  {ruleData.publishTime}
                </Text>
              ) : null}
            </View>
          </View>
        )}

        {/* ── Preface ── */}
        {ruleData.preface ? (
          <View style={[styles.prefaceCard, { backgroundColor: colors.primary + '0F' }]}>
            <SymbolView name="text.quote" size={16} tintColor={colors.primary} />
            <Text style={[styles.prefaceText, { color: colors.textSecondary }]} selectable>
              {ruleData.preface}
            </Text>
          </View>
        ) : null}

        {/* ── Rule sections ── */}
        {ruleData.sections.map((section, i) => (
          <View key={`s-${i}`} style={[styles.ruleCard, { backgroundColor: colors.card, ...Shadows.card }]}>
            {section.title ? (
              <View style={styles.ruleTitleRow}>
                <View style={[styles.ruleIndex, { backgroundColor: colors.primary + '1A' }]}>
                  <Text style={[styles.ruleIndexText, { color: colors.primary }]}>{i + 1}</Text>
                </View>
                <Text style={[styles.ruleTitle, { color: colors.text }]} selectable>
                  {section.title}
                </Text>
              </View>
            ) : null}
            <RuleContentRenderer content={section.content} colors={colors} />
          </View>
        ))}

        {/* ── Footer note ── */}
        <Text style={[styles.footerNote, { color: colors.textDisabled }]}>
          以上内容来自{`${name || '本'}吧`}吧务团队发布的管理规范
        </Text>
      </ScrollView>
    </View>
  );
}

// ────────────────────────────────────────────────────────────
// Styles
// ────────────────────────────────────────────────────────────

const styles = StyleSheet.create({
  container: { flex: 1 },
  scrollContent: { paddingTop: Spacing.lg, paddingHorizontal: Spacing.lg },

  // Title
  title: {
    fontSize: 27,
    fontWeight: '800',
    lineHeight: 35,
    letterSpacing: -0.4,
    paddingHorizontal: Spacing.xs,
  },

  // Author row
  authorRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 11,
    marginTop: Spacing.lg,
    paddingHorizontal: Spacing.xs,
  },
  authorTextCol: { flex: 1 },
  authorName: { ...typographyStyles.subheadBold },
  publishTime: { ...typographyStyles.caption1, marginTop: 2 },

  // Preface
  prefaceCard: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: 9,
    marginTop: Spacing.lg,
    padding: 14,
    ...RadiusStyle.card,
  },
  prefaceText: { flex: 1, fontSize: 14, lineHeight: 22 },

  // Rule sections
  ruleCard: {
    marginTop: 14,
    ...RadiusStyle.card,
    padding: Spacing.lg,
  },
  ruleTitleRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 10 },
  ruleIndex: {
    width: 24,
    height: 24,
    ...RadiusStyle.chip,
    alignItems: 'center',
    justifyContent: 'center',
    marginTop: 1,
  },
  ruleIndexText: { fontSize: 13, fontWeight: '800' },
  ruleTitle: { flex: 1, fontSize: 17, fontWeight: '700', lineHeight: 25, letterSpacing: -0.2 },
  ruleParagraph: { fontSize: 15, lineHeight: 24, marginTop: 10 },
  richFlow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    alignItems: 'flex-start',
  },
  ruleSegment: { fontSize: 15, lineHeight: 24, marginTop: 10 },
  ruleSegmentBold: { fontWeight: '700' },
  ruleImage: {
    width: '100%',
    marginTop: 10,
    ...RadiusStyle.input,
    // backgroundColor 走 colors.surfaceSecondary（组件内动态注入，暗色不亮块）
  },
  quoteBlock: {
    width: '100%',
    borderLeftWidth: 3,
    paddingHorizontal: Spacing.md,
    paddingVertical: Spacing.sm,
    marginTop: 10,
    ...RadiusStyle.chip,
  },
  quoteText: { fontSize: 14, lineHeight: 21 },
  linkChip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.xs,
    marginTop: 10,
    paddingHorizontal: Spacing.sm,
    paddingVertical: Spacing.xs,
    ...RadiusStyle.chip,
  },
  linkText: { ...typographyStyles.footnote, flexShrink: 1 },
  lineBreak: { width: '100%', height: Spacing.sm },

  // Footer
  footerNote: {
    textAlign: 'center',
    ...typographyStyles.caption1,
    marginTop: 24,
    paddingHorizontal: Spacing.lg,
  },
});
