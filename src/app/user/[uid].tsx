/**
 * User Profile Page (用户主页)
 * Displays user profile with stats, tabs for posts/replies/forums.
 *
 * Mirrors Kotlin TiebaLite UserProfileDetail composable layout:
 * - Large avatar (80pt) with network image
 * - Username with showNickname
 * - 3-stat row: 关注 | 粉丝 | 获赞 with dividers
 * - Intro (or default "这个人很懒，什么都没留下")
 * - Verification badges: 吧主 (bazhuGrade), 大神认证 (newGodData status != 0)
 * - Chips row: gender, Tieba UID (copyable), IP location, tieba age
 * - Follow/Unfollow/Block action buttons
 * - Tabs: 帖子 | 回复 | 关注的吧 (each with inline count)
 *
 * Structure (after the page split):
 * - ProfileHeader    components/user/ProfileHeader.tsx   资料卡（自持头像大图预览）
 * - UserTabList      components/user/UserTabList.tsx     三 tab 共用列表
 * - SocialTabList    components/user/SocialTabList.tsx   粉丝/关注覆盖层
 *
 * 布局采用吧页终局范式（2026-08-25）：纯 RN 根节点 + headerTransparent，
 * 列表 contentContainerStyle 自行补顶栏让位；资料卡在上、分段栏在下，
 * 都作为 ListHeaderComponent 随列表滚动。分段控件用原生
 * TiebaSegmentedControl（UISegmentedControl）——SwiftUI Host 进 LegendList
 * header 会触发 PlatformViewHost 错位/触摸断链（吧页三连否决结论）；
 * 整页套页面级 ThemedHost 会与手动让位叠加出「卡片距顶栏大片空白」，
 * 且干扰顶栏液态玻璃链路。
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { Alert, StyleSheet, View } from 'react-native';
import { Stack, useLocalSearchParams } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import * as Clipboard from 'expo-clipboard';
import { SegmentPager } from '@/components/ui/SegmentPager';
import { TiebaSegmentedControl } from '@/components/ui/TiebaSegmentedControl';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { SymbolView } from '@/components/ui/SymbolView';
import { ErrorState } from '@/components/ui/ErrorState';
import { SkeletonList } from '@/components/ui/Skeleton';
import { showToast } from '@/components/ui/Toast';
import { ProfileHeader } from '@/components/user/ProfileHeader';
import { UserTabList } from '@/components/user/UserTabList';
import { SocialTabList, type SocialMode } from '@/components/user/SocialTabList';
import { useThemeColors } from '@/theme/ThemeContext';
import { Spacing } from '@/theme';
import { hapticForScene } from '@/theme/hapticsMap';
import { useAuthStore } from '@/stores/authStore';
import { setUserBlack, cancelUserBlack } from '@/services/api/endpoints/misc';
import { followUser, unfollowUser } from '@/services/api/endpoints/thread';
import { profile } from '@/services/api/endpoints/user';
import { BlockManager } from '@/utils/BlockManager';

import { flattenStyle, buildUserHomeUrl } from '@/utils';
import type { UserInfo } from '@/types';

// ---------- Constants ----------

// 外层 segmented 只保留 3 段；粉丝/关注列表改为从头部统计区进入的独立视图，
// 避免「外层分段 + 内嵌分段」的双层分段控件（风险最小的方案）。
const PROFILE_TABS = [
  { label: '贴子', value: 'threads' },
  { label: '回复', value: 'replies' },
  { label: '关注的吧', value: 'forums' },
];

/** 列表内容左右边距（与卡片/分段栏统一 10pt 对齐） */
const PROFILE_LIST_PAD = 10;

/**
 * 顶栏让位高度：headerTransparent 后内容从 y=0 起，手动补状态栏 + 实测
 * 导航栏。取吧页终局同款 56pt（卡片贴 bar 下沿、间隙取小）——此前页面级
 * ThemedHost 自动让位上再叠 insets.top+66 手动 padding 造成双重偏移，
 * 「卡片距顶栏大片空白」即由此而来。
 */
const PROFILE_TOP_CLEARANCE = 56;

// ---------- Page shell ----------

/**
 * 统一页面骨架：纯 RN View 根 + Stack.Screen（loading/error/主渲染共用）。
 * 不做顶栏让位——headerTransparent 下内容从 y=0 起，各状态自行补让位
 * （列表在 contentContainerStyle、静态态在容器 padding），避免双重偏移。
 */
function PageShell({
  title,
  gestureEnabled = true,
  headerRight,
  children,
}: {
  title: string;
  gestureEnabled?: boolean;
  headerRight?: () => React.ReactNode;
  children: React.ReactNode;
}) {
  const { colors } = useThemeColors();
  return (
    <View style={flattenStyle([styles.container, { backgroundColor: colors.background }])}>
      <Stack.Screen options={{ title, headerTransparent: true, gestureEnabled, headerRight }} />
      {children}
    </View>
  );
}

// ---------- Component ----------

export default function UserProfilePage() {
  // ?tab= 支持从「我的页」直达（我的帖子→threads / 关注的吧→forums），
  // 入参仅限已知 tab 值，其余一律回退默认。
  const { uid, tab: tabParam } = useLocalSearchParams<{ uid: string; tab?: string }>();
  const insets = useSafeAreaInsets();
  const { colors } = useThemeColors();
  // 选择性订阅：仅关注 isLoggedIn/account 两个字段，避免 authStore 其它
  // 字段（error/isLoading 等）变化时整页重渲。
  const isLoggedIn = useAuthStore((s) => s.isLoggedIn);
  const account = useAuthStore((s) => s.account);
  const currentAccountUid = account?.uid;

  // Profile data
  const [user, setUser] = useState<UserInfo | null>(null);
  const [isFollowing, setIsFollowing] = useState(false);
  // TODO(#32): UserInfo has no isBlocked field and the profile response does
  // not map it either; keep local state until the API exposes the relation.
  const [isBlocked, setIsBlocked] = useState(false);
  const [isOwnProfile, setIsOwnProfile] = useState(false);

  // Tab state
  const [activeTab, setActiveTab] = useState(() =>
    tabParam === 'threads' || tabParam === 'replies' || tabParam === 'forums' ? tabParam : 'threads',
  );
  const displayedTab = !isOwnProfile && activeTab === 'replies' ? 'threads' : activeTab;
  // 三 tab 按需懒挂载：首屏只挂当前 tab，segment 点击/滑动落地时再补挂
  // 目标 tab —— 三个列表并发拉首屏的问题不再存在，pager 语义保持不变。
  const [mountedTabs, setMountedTabs] = useState<Set<string>>(() => new Set([displayedTab]));
  const activateTab = useCallback((value: string) => {
    setMountedTabs((prev) => (prev.has(value) ? prev : new Set(prev).add(value)));
  }, []);

  // 粉丝/关注独立视图（从头部统计区进入，外层 segmented 不再嵌套；以
  // absolute 覆盖层展示，主视图保持挂载 → 三 tab 列表状态不丢）
  const [socialVisible, setSocialVisible] = useState(false);
  const [socialInitialMode, setSocialInitialMode] = useState<SocialMode>('fans');

  // Profile loading
  const [loadingProfile, setLoadingProfile] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // ---------- Derived tab labels with counts ----------

  // 回复 tab is only shown on the current user's own profile (#33).
  // 过滤后恒剩 ≥2 段（threads/forums），分段栏无需条件渲染。
  const visibleTabs = useMemo(
    () => PROFILE_TABS.filter((tab) => tab.value !== 'replies' || isOwnProfile),
    [isOwnProfile],
  );

  // ---------- Load profile ----------

  // 请求序号：uid 切换/卸载时使过期响应失效，避免旧 uid 数据覆盖新页
  const profileSeqRef = useRef(0);

  // 返回 boolean（成功/失败）：页面在资料卡已存在时（error 态不承接）
  // 用返回值给下拉刷新失败弹轻提示；抓取/映射/状态更新逻辑未变。
  const loadProfile = useCallback(async (targetUid: string): Promise<boolean> => {
    const seq = ++profileSeqRef.current;
    setLoadingProfile(true);
    setError(null);
    try {
      const result = await profile(targetUid);
      const u = result.user;
      if (seq !== profileSeqRef.current) return false;
      setUser(u);
      // Check if current user follows this user (hasConcerned = 0 means not followed)
      setIsFollowing((u.hasConcerned ?? 0) !== 0);
      setIsOwnProfile(currentAccountUid === targetUid);
      return true;
    } catch (e: any) {
      if (seq !== profileSeqRef.current) return false;
      setError(e?.message || '加载失败');
      return false;
    } finally {
      if (seq !== profileSeqRef.current) return false;
      setLoadingProfile(false);
    }
  }, [currentAccountUid]);

  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- initial profile fetch; loading state is already true on mount.
    loadProfile(uid);
    return () => {
      profileSeqRef.current += 1;
    };
  }, [uid, loadProfile]);

  const handleTabChange = useCallback((value: string) => {
    hapticForScene('toggle');
    activateTab(value);
    setActiveTab(value);
  }, [activateTab]);

  // ---------- Actions ----------

  const userName = user?.name;
  const userNameShow = user?.nameShow;

  const handleFollow = useCallback(async () => {
    if (!isLoggedIn || !account) {
      Alert.alert('提示', '请先登录');
      return;
    }
    try {
      if (isFollowing) {
        await unfollowUser(user?.portrait || '', account.tbs);
      } else {
        await followUser(user?.portrait || '', account.tbs);
      }
      setIsFollowing((v) => !v);
      hapticForScene('action-success');
    } catch {
      Alert.alert('错误', '操作失败');
    }
  }, [isLoggedIn, account, isFollowing, user]);

  const handleBlock = useCallback(async () => {
    if (!isLoggedIn || !account) {
      Alert.alert('提示', '请先登录');
      return;
    }
    try {
      if (isBlocked) {
        await cancelUserBlack(uid, account.tbs);
        await BlockManager.removeBlockedUser(uid);
        setIsBlocked(false);
        Alert.alert('已取消拉黑', '该用户已恢复访问');
        return;
      }
      await setUserBlack(uid, account.tbs);
      await BlockManager.addBlockedUser({
        id: Date.now().toString(),
        uid,
        username: userNameShow || userName || '',
      });
      setIsBlocked(true);
      Alert.alert('已拉黑', '该用户已被拉黑');
    } catch {
      Alert.alert('错误', '拉黑失败');
    }
  }, [isLoggedIn, account, isBlocked, uid, userName, userNameShow]);

  /** Copy UID to clipboard and show haptic feedback */
  const handleCopyUID = useCallback(async () => {
    if (!user) return;
    const uidToCopy = user.tiebaUid || user.id;
    try {
      await Clipboard.setStringAsync(uidToCopy);
      hapticForScene('action-success');
      Alert.alert('已复制', `贴吧UID: ${uidToCopy}`);
    } catch {
      // Ignore clipboard errors
    }
  }, [user]);

  /** 分享：复制用户主页链接（utils.buildUserHomeUrl，官方 home/main?id=portrait 格式） */
  const handleShareProfile = useCallback(async () => {
    if (!user) return;
    const link = buildUserHomeUrl(user.portrait || uid);
    try {
      await Clipboard.setStringAsync(link);
      hapticForScene('action-success');
      showToast('已复制用户主页链接');
    } catch {
      showToast('复制失败');
    }
  }, [user, uid]);

  // 顶栏右上角分享按钮（HdrPressable 自带 HDR 高光按压反馈，与吧页同款）
  const headerRight = useMemo(
    // eslint-disable-next-line react-hooks/exhaustive-deps
    () =>
      function HeaderRight() {
        return (
          <HdrPressable style={styles.headerButton} hitSlop={8} onPress={handleShareProfile}>
            <SymbolView name="square.and.arrow.up" size={20} tintColor={colors.primary} />
          </HdrPressable>
        );
      },
    [handleShareProfile, colors.primary],
  );

  // ---------- Loading / Error states ----------

  if (loadingProfile && !user) {
    return (
      <PageShell title="用户">
        <View style={[styles.skeletonWrap, { paddingTop: insets.top + PROFILE_TOP_CLEARANCE }]}>
          <SkeletonList variant="row" count={8} />
        </View>
      </PageShell>
    );
  }

  if (error && !user) {
    return (
      <PageShell title="用户">
        <View style={{ paddingTop: insets.top + PROFILE_TOP_CLEARANCE }}>
          <ErrorState message={error} onRetry={() => loadProfile(uid)} />
        </View>
      </PageShell>
    );
  }

  // 三 tab 共用的列表头：资料卡在上、分段栏在下（用户指定顺序），整体随
  // 列表滚动。分段用原生 UISegmentedControl：RN 树内 UIKit hit-test 直接
  // 命中，LegendList 头内可点；选择态由父组件下发，点按/横滑双向同步。
  const renderListHeader = (user: UserInfo) => (
    <>
      <ProfileHeader
        user={user}
        colors={colors}
        isFollowing={isFollowing}
        isBlocked={isBlocked}
        isOwnProfile={isOwnProfile}
        isLoggedIn={isLoggedIn}
        onFollow={handleFollow}
        onBlock={handleBlock}
        onCopyUID={handleCopyUID}
        onOpenSocial={(mode) => {
          hapticForScene('press');
          setSocialInitialMode(mode);
          setSocialVisible(true);
        }}
      />
      <View style={styles.segmentSlot}>
        <TiebaSegmentedControl
          segments={visibleTabs.map((t) => ({ label: t.label, value: t.value }))}
          selectedIndex={Math.max(0, visibleTabs.findIndex((t) => t.value === displayedTab))}
          onSelect={handleTabChange}
        />
      </View>
    </>
  );

  // ---------- Main render ----------

  // 理论不可达：上方 loading/error 分支已承接 user 为空的所有情形
  if (!user) return null;

  return (
    // 最左侧右滑走原生栈返回手势（整屏滑动退出，2026-08-28 与吧页统一：
    // SegmentPager 不传 canExit → overdrag 关，不再橡皮筋接管退出）
    <PageShell title={user?.nameShow || user?.name || '用户'} headerRight={headerRight}>
      <SegmentPager
        pageIndex={visibleTabs.findIndex((t) => t.value === displayedTab)}
        onPageIndexChange={(i) => {
          const target = visibleTabs[i];
          if (target) {
            activateTab(target.value);
            if (target.value !== activeTab) {
              hapticForScene('toggle');
              setActiveTab(target.value);
            }
          }
        }}
      >
        {visibleTabs.map((tab) => (
          <View key={tab.value} style={styles.tabListWrap}>
            {mountedTabs.has(tab.value) ? (
              <UserTabList
                tab={tab.value}
                uid={uid}
                colors={colors}
                insets={insets}
                header={renderListHeader(user)}
                profileUser={user}
                onHeaderRefresh={() => loadProfile(uid)}
              />
            ) : null}
          </View>
        ))}
      </SegmentPager>

      {/* 粉丝/关注覆盖层：absolute fill 盖在完整主视图上（主视图不卸载，
          三 tab 状态/滚动位置保留）；背景实色防止主列表从行间距透出。
          顶栏让位由覆盖层自身 padding 承接（页面已是纯 RN 根）。 */}
      {socialVisible && (
        <View
          style={[
            styles.socialOverlay,
            { backgroundColor: colors.background, paddingTop: insets.top + PROFILE_TOP_CLEARANCE },
          ]}
        >
          <SocialTabList
            uid={uid}
            colors={colors}
            insets={insets}
            initialMode={socialInitialMode}
            onClose={() => setSocialVisible(false)}
          />
        </View>
      )}
    </PageShell>
  );
}

// ---------- Styles ----------

const styles = StyleSheet.create({
  container: { flex: 1 },
  skeletonWrap: { paddingHorizontal: Spacing.lg },

  // 分段栏（贴子/回复/关注的吧）：位于资料卡之下、随列表滚动；左右与
  // 卡片内容 10pt 边距对齐。minHeight 保底：原生 UISegmentedControl 初次
  // 挂载高度未测准会塌缩/跳变，把下方空态顶得位移（2026-08-27 实测"等一秒
  // 暂无内容上移"）。
  segmentSlot: {
    width: '100%',
    paddingHorizontal: PROFILE_LIST_PAD,
    paddingVertical: Spacing.md,
    minHeight: 48,
    justifyContent: 'center',
  },

  // Tabs
  tabListWrap: { flex: 1 },

  // 顶栏分享按钮（与吧页搜索按钮同款内边距）
  headerButton: { padding: Spacing.sm },

  // 粉丝/关注覆盖层：absolute 填满页面容器（zIndex 需压过列表，iOS 同层
  // zIndex 高的后绘制）；顶部让位由使用处的 paddingTop 提供
  socialOverlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    zIndex: 2,
  },
});
