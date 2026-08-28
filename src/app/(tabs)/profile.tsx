/**
 * Profile Tab (我的) — 官方 @expo/ui FieldGroup 原生 Form 实现
 *
 * iOS 上 FieldGroup = SwiftUI Form（iOS 26 液态玻璃分组材质），
 * ListItem = 原生行（leading 色块图标 / 标题 / 副标题 / trailing 开关或 chevron）。
 * 用户卡片为 RN 布局：横排左对齐（头像左 / 名字+简介右），登录后下方接
 * hairline 三等分统计行；登录前同构骨架（占位头像+文案+实心 primary 胶囊
 * 主 CTA）。卡片叠纵向单色淡染渐变让液态玻璃有可模糊内容。
 * 页面背景走 colors.background（浅 #F2F2F7 / 深 #000000）。
 */

import { useCallback, useEffect, useState } from 'react';
import { FieldGroup, ListItem } from '@expo/ui';
import {
  DeviceEventEmitter,
  Pressable,
  StyleSheet,
  Text as RNText,
  View,
} from 'react-native';
import { LinearGradient } from 'expo-linear-gradient';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useRouter } from 'expo-router';
import type { Href } from 'expo-router';
import { hapticForScene } from '@/theme/hapticsMap';
import { Avatar } from '@/components/ui/Avatar';
import { GlassView } from '@/components/ui/GlassView';
import { SymbolView } from '@/components/ui/SymbolView';
import { SkeletonList } from '@/components/ui/Skeleton';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { RowIcon } from '@/components/ui/RowIcon';
import { BottomFade } from '@/components/feed/BottomFade';
import { useThemeColors } from '@/theme/ThemeContext';
import {Spacing, Radius} from '@/theme';
import { typographyStyles } from '@/theme/typography';
import { useAuthStore } from '@/stores/authStore';
import { profile as fetchProfile } from '@/services/api/endpoints/user';
import { formatCount } from '@/utils';
import type { UserProfile } from '@/types';
import { TAB_RESELECT_EVENT } from '@/constants/events';
import { HdrPressable } from '@/components/ui/HdrPressable';

/** 行前色块图标：见 @/components/ui/RowIcon（Profile/Settings 统一） */
export default function ProfileScreen() {
  const { colors, isDark } = useThemeColors();
  const isLoggedIn = useAuthStore((s) => s.isLoggedIn);
  const account = useAuthStore((s) => s.account);
  const isLoading = useAuthStore((s) => s.isLoading);
  const router = useRouter();
  const currentUid = account?.uid;

  const [userProfile, setUserProfile] = useState<UserProfile | null>(null);
  const insets = useSafeAreaInsets();

  const loadProfile = useCallback(async () => {
    if (!isLoggedIn || !currentUid) return;
    try {
      const result = await fetchProfile(currentUid);
      setUserProfile(result);
    } catch {
      // 失败降级：保留 account 缓存字段展示
    }
  }, [isLoggedIn, currentUid]);

  useEffect(() => {
    // 挂载时拉一次个人资料（跨端数据源，setState 发生在 await 之后）
    // eslint-disable-next-line react-hooks/set-state-in-effect -- mount-time data load
    loadProfile();
  }, [loadProfile]);

  useEffect(() => {
    const sub = DeviceEventEmitter.addListener(TAB_RESELECT_EVENT, (tabName: string) => {
      if (tabName === 'profile') loadProfile();
    });
    return () => sub.remove();
  }, [loadProfile]);

  const navigateTo = useCallback((route: Href) => {
    hapticForScene('press');
    router.push(route);
  }, [router]);

  // ── 加载中 ──
  if (isLoading) {
    return (
      <View style={[styles.container, { backgroundColor: colors.background }]}>
        <SkeletonList variant="row" count={8} style={styles.profileSkeleton} />
      </View>
    );
  }

  const stats = userProfile?.statue;
  // 关注数 = 关注的「用户」数（Kotlin 个人资料卡同判据 user.concern_num）；
  // statue.concernForumsNum 是关注的「贴吧」数，误用会显示成吧数量
  //（2026-08-27 真机反馈）。
  const concernCount = userProfile?.user?.concernNum ?? account?.concernNum ?? 0;
  const fansCount = userProfile?.user?.fansNum ?? account?.fansNum ?? 0;
  const postsCount = stats?.postsNum ?? account?.postNum ?? 0;

  // ── 用户卡片：横排左对齐骨架，两态同构（切换不跳变）；
  // 直接置于 GlassView RN 容器内，无需 RNHostView 桥 ──
  const userCard = (
    <Pressable
      onPress={
        isLoggedIn && account?.uid
          ? () => navigateTo(`/user/${account.uid}`)
          : undefined
      }
      // 未登录时 onPress 置空：仅由下方「立即登录」实心按钮触发跳转，
      // 避免点卡片与点按钮同时 push /login 弹出两个登录窗口。
      disabled={!isLoggedIn}
      style={styles.userCardPressable}
      accessibilityRole="button"
      accessibilityLabel={isLoggedIn ? '个人主页' : '登录'}
    >
      <View style={styles.headerRow}>
        {isLoggedIn ? (
          <Avatar
            source={account?.portrait || undefined}
            initials={(account?.nameShow || account?.name || '吧')?.charAt(0)}
            size={64}
          />
        ) : (
          <View style={[styles.avatarPlaceholder, { backgroundColor: colors.surfaceSecondary }]}>
            <SymbolView name="person.crop.circle" size={30} tintColor={colors.textTertiary} />
          </View>
        )}
        <View style={styles.headerTextCol}>
          <RNText style={[styles.userName, { color: colors.text }]} numberOfLines={1}>
            {isLoggedIn
              ? account?.nameShow || account?.name || '贴吧用户'
              : '登录百度账号'}
          </RNText>
          {(isLoggedIn ? userProfile?.user?.intro : null) ? (
            <RNText style={[styles.userIntro, { color: colors.textSecondary }]} numberOfLines={2}>
              {userProfile!.user!.intro}
            </RNText>
          ) : !isLoggedIn ? (
            <RNText style={[styles.userIntro, { color: colors.textSecondary }]} numberOfLines={1}>
              登录后查看个人信息、签到、收藏
            </RNText>
          ) : null}
        </View>
      </View>

      {isLoggedIn && (
        <View style={[styles.statsRow, { borderTopColor: colors.separator }]}>
          <View style={styles.statItem}>
            <RNText style={[styles.statValue, { color: colors.text }]}>{formatCount(concernCount)}</RNText>
            <RNText style={[styles.statLabel, { color: colors.textSecondary }]}>关注</RNText>
          </View>
          <View style={[styles.statDivider, { backgroundColor: colors.separator }]} />
          <View style={styles.statItem}>
            <RNText style={[styles.statValue, { color: colors.text }]}>{formatCount(fansCount)}</RNText>
            <RNText style={[styles.statLabel, { color: colors.textSecondary }]}>粉丝</RNText>
          </View>
          <View style={[styles.statDivider, { backgroundColor: colors.separator }]} />
          <View style={styles.statItem}>
            <RNText style={[styles.statValue, { color: colors.text }]}>{formatCount(postsCount)}</RNText>
            <RNText style={[styles.statLabel, { color: colors.textSecondary }]}>帖子</RNText>
          </View>
        </View>
      )}

      {!isLoggedIn && (
        <HdrPressable
          onPress={() => {
            void hapticForScene('press');
            navigateTo('/login');
          }}
          accessibilityRole="button"
          accessibilityLabel="立即登录"
          // 深色模式下整卡高光扫过太抢眼，用户要求登录按钮不闪高光（2026-08-26）
          effect="subtle"
          flashRadius={22}
          hitSlop={{ top: 6, bottom: 6 }}
          style={({ pressed }) => [styles.loginButton, { opacity: pressed ? 0.85 : 1 }]}
        >
          <View style={[styles.loginButtonInner, { backgroundColor: colors.primary }]}>
            <SymbolView name="person.crop.circle.badge.checkmark" size={16} weight="semibold" tintColor="#FFFFFF" />
            <RNText style={[styles.loginButtonText, { color: colors.textOnPrimary }]}>立即登录</RNText>
          </View>
        </HdrPressable>
      )}
    </Pressable>
  );

  return (
    <View style={[styles.container, { backgroundColor: colors.background }]}>
      {/* 顶部液态玻璃用户卡片：玻璃叠在淡蓝渐变上才有可模糊内容（纯白底磨砂玻璃不可见） */}
      <View style={[styles.profileHeader, { paddingTop: insets.top + Spacing.md }]}>
        <GlassView borderRadius={Radius.card} glassEffectStyle="regular">
          <LinearGradient
            colors={
              isDark
                ? ['rgba(32,138,239,0.16)', 'rgba(32,138,239,0.04)']
                : ['rgba(32,138,239,0.10)', 'rgba(32,138,239,0.02)']
            }
            start={{ x: 0, y: 0 }}
            end={{ x: 0, y: 1 }}
            style={StyleSheet.absoluteFill}
          />
          {userCard}
        </GlassView>
      </View>

      {/* FieldGroup = SwiftUI Form：必须经 ThemedHost（Host 桥）嵌入 RN 树，
          否则 Form 不撑开高度导致下方列表全部消失。
          ignoreSafeArea='container'：内容延伸到屏幕底（含液态底栏之下），
          Form 画布铺满 → 玻璃底栏背后有内容可折射，不再出现"内容截止 +
          底栏上沿纯色带"（2026-08-27 真机：外层 View paddingBottom 会把
          Form 截在底栏上方，截断区 = 页面纯背景色，双叠让位是根因）。 */}
      <ThemedHost style={{ flex: 1 }} ignoreSafeArea="container">
        <FieldGroup>
          {/* ── 我的内容 ── */}
          <FieldGroup.Section title="我的内容">
            {isLoggedIn ? (
              <>
                <ListItem leading={<RowIcon icon="person" tint="#5856D6" />} onPress={() => navigateTo(`/user/${account?.uid}`)}>个人主页</ListItem>
                <ListItem leading={<RowIcon icon="doc.text" tint="#FF9500" />} onPress={() => navigateTo(`/user/${account?.uid}?tab=threads`)}>我的帖子</ListItem>
                <ListItem leading={<RowIcon icon="square.grid.2x2" tint="#34C759" />} onPress={() => navigateTo(`/user/${account?.uid}?tab=forums`)}>关注的吧</ListItem>
              </>
            ) : null}
            <ListItem leading={<RowIcon icon="clock" tint="#FF9500" />} onPress={() => navigateTo('/history')}>浏览历史</ListItem>
            <ListItem leading={<RowIcon icon="bookmark" tint="#FF3B30" />} onPress={() => navigateTo('/threadstore')}>我的收藏</ListItem>
          </FieldGroup.Section>

          {/* ── 设置 ── */}
          <FieldGroup.Section title="设置">
            <ListItem leading={<RowIcon icon="gearshape" tint="#8E8E93" />} onPress={() => navigateTo('/settings')}>设置</ListItem>
            <ListItem leading={<RowIcon icon="info.circle" tint="#5AC8FA" />} onPress={() => navigateTo('/settings/about')}>关于 贴吧Lite</ListItem>
            {/* 底部滚动让位：Form 行尾到屏幕底之间的可滚动余量——最后一个
                ListItem（关于 贴吧Lite）可再下滑一段距离，不被液态底栏遮住
                （2026-08-27 真机：末行一半被底栏盖住）。放在 Section 尾部
                而非 form 外，保证余量随内容滚动。 */}
            <FieldGroup.SectionFooter>
              <View style={{ height: insets.bottom + 76 }} />
            </FieldGroup.SectionFooter>
          </FieldGroup.Section>
        </FieldGroup>
      </ThemedHost>

      {/* 底部渐罩：公共组件（@/components/feed/BottomFade，index/explore 共用）。
          底栏液态玻璃背后不再是纯平背景色，玻璃有内容可折射；pointerEvents="none"，
          不挡下方 Form 的滚动与点击；条区内常驻文案由原生侧 caption 提供 */}
      <BottomFade />
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },

  profileSkeleton: {
    paddingHorizontal: Spacing.lg,
    paddingTop: 24,
    alignSelf: 'stretch',
  },
  profileHeader: {
    paddingHorizontal: Spacing.lg,
    paddingBottom: Spacing.sm,
  },
  userCardPressable: {
    alignSelf: 'stretch',
    padding: Spacing.lg,
  },

  // ── 横排头部：头像左（64pt）/ 名字+简介右 ──
  headerRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.md,
  },
  headerTextCol: {
    flex: 1,
    gap: 2,
  },
  avatarPlaceholder: {
    width: 64,
    height: 64,
    borderRadius: 32,
    alignItems: 'center',
    justifyContent: 'center',
  },
  userName: {
    ...typographyStyles.title3,
  },
  userIntro: {
    fontSize: 13,
    lineHeight: 18,
  },

  // ── 登录后：hairline 三等分统计行 ──
  statsRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginTop: Spacing.md,
    paddingTop: Spacing.md,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  statItem: {
    flex: 1,
    alignItems: 'center',
    gap: 2,
  },
  statDivider: {
    width: StyleSheet.hairlineWidth,
    alignSelf: 'stretch',
    marginVertical: 2,
  },
  statValue: {
    fontSize: 20,
    fontWeight: '600',
    fontVariant: ['tabular-nums'],
  },
  statLabel: {
    ...typographyStyles.caption1,
  },

  // ── 登录前：实心 primary 胶囊主 CTA ──
  loginButton: {
    borderRadius: Radius.capsule,
    marginTop: Spacing.md,
  },
  loginButtonInner: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'center',
    gap: 6,
    paddingVertical: 12,
    borderRadius: Radius.capsule,
  },
  loginButtonText: {
    ...typographyStyles.calloutBold,
  },
});
