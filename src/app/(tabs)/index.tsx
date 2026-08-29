/* eslint-disable react-hooks/immutability -- Reanimated shared values are mutable refs; React Compiler cannot model them. */
/**
 * Home Tab (关注) — SwiftUI 原生实现
 *
 * 界面渲染：
 * - 搜索栏：HStack + SF Symbol 放大镜 + 圆角灰底背景
 * - 最近访问：横向 ScrollView + 药丸按钮
 * - 关注吧列表：List + Section + Label(systemImage) 代替 emoji
 * - 签到按钮：buttonStyle('glass') 液态玻璃效果
 * - 未登录/空态：ContentUnavailableView
 * - 下拉刷新：refreshable modifier
 */

import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  VStack, HStack, Button, Text, Label,
  ContentUnavailableView,
  Spacer, RNHostView,
} from '@expo/ui/swift-ui';
import {
  font, buttonStyle, buttonBorderShape, padding,
} from '@expo/ui/swift-ui/modifiers';
import { MenuView, type MenuAction } from '@expo/ui/community/menu';
import {
  Alert, DeviceEventEmitter, View, StyleSheet, Text as RNText, RefreshControl,
  ScrollView as RNScrollView,
} from 'react-native';
import { LegendList, type LegendListRef } from '@legendapp/list/react-native';
import { useFocusEffect, useRouter, type ImperativeRouter } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { hapticForScene } from '@/theme/hapticsMap';
import { useThemeColors } from '@/theme/ThemeContext';
import { useAuthStore } from '@/stores/authStore';
import { useForumAvatarStore, forumAvatarKey } from '@/stores/forumAvatarCache';
import { useForumStore } from '@/stores/forumStore';
import { useSignStore } from '@/stores/signStore';
import { usePreferencesStore } from '@/stores/preferencesStore';
import { useAppPreference } from '@/hooks/useAppPreference';
import { getVisitHistory, toForumHistoryItem, type ForumHistoryItem } from '@/services/storage/visitHistory';
import { formatCount } from '@/utils';
import { SymbolView } from '@/components/ui/SymbolView';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { Avatar } from '@/components/ui/Avatar';
import { GlassView } from '@/components/ui/GlassView';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { SkeletonList } from '@/components/ui/Skeleton';
import { ErrorState } from '@/components/ui/ErrorState';
import { PressScale } from '@/components/ui/PressScale';
import {Spacing, RadiusStyle} from '@/theme';
import { typographyStyles } from '@/theme/typography';
import { EntranceRow } from '@/components/feed/EntranceRow';
import { BottomFade } from '@/components/feed/BottomFade';
import { showToast } from '@/components/ui/Toast';
import { TAB_RESELECT_EVENT } from '@/constants/events';
import type { ForumInfo } from '@/types';

const forumKeyExtractor = (item: ForumInfo) => item.forumId;

/**
 * 首屏入场级联（EntranceRow 为公共组件 @/components/feed/EntranceRow，
 * index 关注页 / explore 信息流与热榜共用，见全量审查 #4）。
 * 顶部操作条/签到逻辑在本文件内实现。
 */

/**
 * 签到未登录提示：handleSign 与 handleSignRequireLogin 共用，
 * 文案单一来源（见全量审查 #13）。
 */
function promptSignRequireLogin(router: ImperativeRouter) {
  Alert.alert('提示', '签到需要先登录百度账号', [
    { text: '去登录', onPress: () => router.push('/login') },
    { text: '取消', style: 'cancel' },
  ]);
}

/**
 * 按压反馈：进入用 PRESS_ENTER 弹簧缩放（0.97），释放回 1。
 * 共享实现见 @/components/ui/PressScale（index/notifications/…… 统一）。
 */
const FORUM_MENU_ACTIONS: MenuAction[] = [
  {
    id: 'unfollow',
    title: '取消关注',
    image: 'person.badge.minus',
    attributes: { destructive: true },
  },
];

export default function HomeScreen() {
  const isLoggedIn = useAuthStore((s) => s.isLoggedIn);
  const isLoading = useAuthStore((s) => s.isLoading);
  const router = useRouter();
  const insets = useSafeAreaInsets();

  // 未登录时一键签到同样可见：点击后提示先登录（登录后跳转登录页）
  const handleSignRequireLogin = useCallback(() => {
    promptSignRequireLogin(router);
  }, [router]);

  // 鉴权未收敛（冷启动 checkAuth 在途）时不再整屏转圈（2026-08-28）：
  // 关注列表数据源 forumFollowed 自带 5min 内存 + 24h 磁盘缓存，缓存命中时
  // Promise 立即 resolve、与鉴权收敛无依赖（登出/切号/登录态失效均已失效
  // 该缓存）——直通 LoggedInHome 让缓存内容随加载完成即时渲染，而不是等
  // checkAuth 全链跑完才动（dev 下该链被 Metro 按需打包拖到 ~3s）。未登录
  // 空态仍只在鉴权定案（!isLoading）后渲染，保持「未登录→已登录」不闪变。
  if (!isLoggedIn && !isLoading) {
    return (
      // ignoreSafeArea='container' 会把 SwiftUI 顶部安全区一并划掉（内容伸进
      // 底栏玻璃的代价），未登录分支同样用外层 RN View 承担 top inset。
      <View style={[styles.container, { paddingTop: insets.top }]}>
      <ThemedHost style={{ flex: 1 }} ignoreSafeArea="container">
        <VStack spacing={0}>
          {/* 顶部操作条：搜索栏 + 签到图标按钮（未登录也可点，点击提示登录）；
              排序切换未登录禁用（灰色禁用态，非死按钮） */}
          <HomeTopActions
            isSigning={false}
            onSignPress={handleSignRequireLogin}
            sortMode="level"
            sortEnabled={false}
          />

          <Spacer />
          <ContentUnavailableView
            systemImage="person.crop.circle.badge.questionmark"
            title="你还未登录"
            description="登录后查看关注的贴吧动态"
          />
          <Button
            onPress={() => router.push('/login')}
            modifiers={[buttonStyle('glassProminent'), buttonBorderShape('capsule'), padding({ bottom: 80 })]}
          >
            <Label title="登录百度账号" systemImage="person.crop.circle.badge.checkmark" />
          </Button>
          <Spacer />
        </VStack>
      </ThemedHost>
      {/* 未登录分支同样铺底栏渐罩：空态下玻璃背后也不露纯平背景色 */}
      <BottomFade />
      </View>
    );
  }

  return <LoggedInHome />;
}

// ── 首页顶部操作条：搜索栏（左）+ 一键签到 / 排序切换 图标按钮（右） ──
// 排序切换（按等级 ⇄ 按名称）在右上角；单列/双列布局入口已移入设置页。
function HomeTopActions({
  isSigning,
  onSignPress,
  sortMode,
  onSortPress,
  sortEnabled = true,
}: {
  isSigning: boolean;
  onSignPress: () => void;
  sortMode: 'level' | 'name';
  /** 排序切换回调（登录后传入）；未登录时 sortEnabled=false 走禁用态 */
  onSortPress?: () => void;
  /** 未登录禁用排序：渲染灰色禁用而非无响应死按钮（见全量审查 #11） */
  sortEnabled?: boolean;
}) {
  const { colors, isDark } = useThemeColors();
  const router = useRouter();

  const tint = isDark ? 'rgba(255,255,255,0.10)' : 'rgba(120,120,128,0.10)';
  const border = isDark ? 'rgba(255,255,255,0.35)' : 'rgba(120,120,128,0.45)';

  return (
    /* 整条顶栏放进单个 RNHostView 的 RN 行：RN 的 flex:1 才让搜索胶囊真正铺满、
       按钮贴右（RNHostView 在 SwiftUI HStack 里拿不到弹性宽度会把胶囊塌缩成固有宽）。
       matchContents：RNHostView 默认在 SwiftUI VStack 中会拉伸占满剩余高度，
       造成顶栏和下方内容之间出现大段空白；matchContents 让它收缩到内容高度。 */
    <RNHostView matchContents>
      <View style={styles.topRow}>
        <View style={{ flex: 1 }}>
          <SearchBarPill onPress={() => router.push('/search')} />
        </View>

        {/* 一键签到：纯图标（无文字），点击直接开始签到（Kotlin 同款无确认弹窗） */}
        <TopIconButton
          theme={isDark ? 'dark' : 'light'}
          tint={tint}
          border={border}
          onPress={onSignPress}
          symbol={isSigning ? 'checkmark.seal.fill' : 'checkmark.seal'}
          symbolTint={isSigning ? colors.primary : colors.text}
        />

        {/* 排序切换：按等级（arrow.up.arrow.down 等级徽章） ⇄ 按名称（character 排序）；
            未登录禁用：灰色图标 + 不可点 */}
        <TopIconButton
          theme={isDark ? 'dark' : 'light'}
          tint={tint}
          border={border}
          onPress={sortEnabled ? onSortPress : undefined}
          disabled={!sortEnabled}
          symbol={sortMode === 'level' ? 'arrow.up.arrow.down' : 'textformat.abc'}
          symbolTint={sortEnabled ? colors.text : colors.textDisabled}
        />
      </View>
    </RNHostView>
  );
}

/** 顶部 34pt 图标按钮：下单玻璃胶囊 + 可见描边（浅色白底也看得出轮廓） */
function TopIconButton({
  theme,
  tint,
  border,
  symbol,
  symbolTint,
  onPress,
  disabled = false,
}: {
  theme: 'light' | 'dark';
  tint: string;
  border: string;
  symbol: string;
  symbolTint: string;
  onPress?: () => void;
  /** 禁用态：不响应按压（Pressable disabled） */
  disabled?: boolean;
}) {
  return (
    <GlassView
      borderRadius={17}
      // 34pt 圆形图标钮：radius=半尺寸，连续曲线几何等价，保持 circular（2026-08-28 定案）
      cornerCurve="circular"
      glassEffectStyle="clear"
      theme={theme}
      tintColor={tint}
      style={styles.topIconBtn}
      // 34pt 小图标钮：显式静态，不占每屏唯一实时玻璃位（让搜索胶囊独享），
      // 也避免每次进首页都触发"实时玻璃超预算"降级日志
      realTime={false}
    >
      <HdrPressable onPress={onPress} disabled={disabled} style={styles.topIconBtnInner} flashRadius={17}>
        <SymbolView name={symbol} size={17} tintColor={symbolTint} />
      </HdrPressable>
      <View
        pointerEvents="none"
        style={[
          StyleSheet.absoluteFill,
          {
            borderRadius: 17,
            borderWidth: StyleSheet.hairlineWidth,
            borderColor: border,
          },
        ]}
      />
    </GlassView>
  );
}

// ── 已登录首页 ──
function LoggedInHome() {
  const { colors } = useThemeColors();
  const router = useRouter();
  const insets = useSafeAreaInsets();
  const isLoggedIn = useAuthStore((s) => s.isLoggedIn);
  const authLoading = useAuthStore((s) => s.isLoading);
  const followedForums = useForumStore((s) => s.followedForums);
  const isLoadingForums = useForumStore((s) => s.isLoadingForums);
  // 鉴权未收敛标记：冷启动 checkAuth 在途且尚未判定登录态时，论坛加载的
  // 失败/空结论态一律不展示（未登录用户会看到误导性的「加载失败」），
  // 统一走中性骨架；鉴权定案后由外层 HomeScreen 切到未登录空态。
  const authPending = authLoading && !isLoggedIn;
  // 下拉刷新专用 spinner：RefreshControl 不能绑 isLoadingForums——
  // 冷启动/切回自动加载也会把它置 true，实际请求 0.4-2s 就结束，
  // spinner 却一直转（2026-08-27 真机「下拉刷新动画一直播放不停」）。
  const [pullingForums, setPullingForums] = useState(false);
  const loadFollowedForums = useForumStore((s) => s.loadFollowedForums);
  const unfollowForum = useForumStore((s) => s.unfollowForum);
  const startSign = useSignStore((s) => s.startSign);
  const isSigning = useSignStore((s) => s.isSigning);
  // 排序切换回顶用（toggleSortMode：排序+回顶，2026-08-27）
  const forumListRef = useRef<LegendListRef | null>(null);
  const showHistoryForum = useAppPreference('homePageShowHistoryForum', false);
  const forumListSingle = useAppPreference('forumListSingle', true);
  // useAppPreference 的 defaultValue 已兜底（store 缺省时返回默认值），返回值
  // 必非 undefined —— TS 无法从签名收窄，这里显式断言（见全量审查 #12）。
  const forumSortMode = useAppPreference('forumSortMode', 'level')!;
  const setPreference = usePreferencesStore((s) => s.setPreference);

  const [recentForums, setRecentForums] = useState<ForumHistoryItem[]>([]);
  // 吧头像统一缓存订阅（「最近访问」老记录 avatar 列常空，随缓存逐条补齐）
  const cachedForumAvatars = useForumAvatarStore((s) => s.avatars);
  const [historyExpanded, setHistoryExpanded] = useState(true);
  // 关注吧加载失败态：用于替代静默 catch，展示重试入口
  const [forumsError, setForumsError] = useState('');

  // 首屏入场标记：仅数据首次到达批次做 stagger 入场（关注吧来自 store，首次到达后置位）。
  const entranceDoneRef = useRef(false);
  useEffect(() => {
    if (followedForums.length > 0) entranceDoneRef.current = true;
  }, [followedForums.length]);

  // 排序：按等级（高→低，未关注等级为 0 排最后）或按名称（中文拼音序）。
  // 右上角图标一键切换（Kotlin 关注列表排序语义）。搜索已迁至 /search
  //（全量审查 #3）：不再在首页做本地过滤，直接对 followedForums 排序。
  const sortedForums = useMemo(() => {
    const list = [...followedForums];
    if (forumSortMode === 'name') {
      list.sort((a, b) => a.forumName.localeCompare(b.forumName, 'zh-Hans-CN'));
    } else {
      list.sort((a, b) => (b.levelId ?? 0) - (a.levelId ?? 0));
    }
    return list;
  }, [followedForums, forumSortMode]);

  const toggleSortMode = useCallback(() => {
    hapticForScene('toggle');
    // 排序切换同时回顶：列表乱序重排后停留在原偏移会导致视觉跳变/错位
    //（2026-08-27 真机：只排序不回顶）
    forumListRef.current?.scrollToOffset({ offset: 0, animated: true });
    setPreference('forumSortMode', forumSortMode === 'level' ? 'name' : 'level');
  }, [forumSortMode, setPreference]);

  const handleLoadFollowedForums = useCallback(async () => {
    try {
      setForumsError('');
      await loadFollowedForums();
    } catch (e: any) {
      setForumsError(e?.message || '加载关注的贴吧失败');
    }
  }, [loadFollowedForums]);

  useFocusEffect(
    useCallback(() => {
      handleLoadFollowedForums();
      if (showHistoryForum) {
        getVisitHistory('forum')
          .then((items) => {
            const mapped = items.map(toForumHistoryItem).filter((f): f is ForumHistoryItem => f !== null);
            setRecentForums(mapped);
            // 吧头像统一缓存：老记录 avatar 列为空时按名/ID 补齐
            useForumAvatarStore.getState().ensureAvatars(mapped);
          })
          .catch(() => {});
      }
    }, [handleLoadFollowedForums, showHistoryForum]),
  );

  useEffect(() => {
    const sub = DeviceEventEmitter.addListener(TAB_RESELECT_EVENT, (tabName: string) => {
      if (tabName === 'index') {
        handleLoadFollowedForums();
      }
    });
    return () => sub.remove();
  }, [handleLoadFollowedForums]);

  const handleSign = useCallback(() => {
    if (!isLoggedIn) {
      promptSignRequireLogin(router);
      return;
    }
    // 点击即开始（Kotlin 同款无确认弹窗）：仅对“未签到”的吧执行；
    // 全部已签到时直接提示。
    const unsigned = followedForums.filter((f) => !f.isSign).length;
    if (unsigned === 0) {
      showToast('今天所有关注的吧都已签到过了');
      return;
    }
    hapticForScene('action-success');
    startSign();
  }, [isLoggedIn, followedForums, router, startSign]);

  const handleForumPress = useCallback((forum: ForumInfo) => {
    hapticForScene('press');
    router.push(`/forum/${encodeURIComponent(forum.forumName)}`);
  }, [router]);

  const handleRefresh = useCallback(async () => {
    // 只有真实下拉才驱动 spinner（成功/失败都收尾）
    setPullingForums(true);
    try {
      await handleLoadFollowedForums();
    } catch {
      // loadFollowedForums 内部已复位 isLoadingForums，这里防 unhandled
    }
    setPullingForums(false);
    hapticForScene('toggle');
  }, [handleLoadFollowedForums]);

  const handleUnfollowConfirm = useCallback((forum: ForumInfo) => {
    Alert.alert(
      '取消关注',
      `确定不再关注「${forum.forumName}吧」吗？`,
      [
        { text: '取消', style: 'cancel' },
        {
          text: '取消关注',
          style: 'destructive',
          onPress: () => {
            unfollowForum(forum.forumId, forum.forumName)
              .then(() => {
                hapticForScene('action-success');
                return loadFollowedForums();
              })
              .catch(() => {
                hapticForScene('action-fail');
              });
          },
        },
      ],
    );
  }, [loadFollowedForums, unfollowForum]);

  const renderForumItem = useCallback(
    ({ item, index }: { item: ForumInfo; index: number }) => (
      <EntranceRow index={index} animateEntry={!entranceDoneRef.current}>
        <MenuView
          style={styles.forumMenu}
          actions={FORUM_MENU_ACTIONS}
          shouldOpenOnLongPress
          onPressAction={(event) => {
            if (event.nativeEvent.event === 'unfollow') {
              handleUnfollowConfirm(item);
            }
          }}
        >
          <PressScale effect="subtle" onPress={() => handleForumPress(item)}>
            <View
              style={[
                forumListSingle ? styles.forumRow : styles.forumCardGrid,
                { backgroundColor: colors.card },
              ]}
            >
              <Avatar
                source={item.avatar || undefined}
                initials={(item.forumName || '吧')?.charAt(0)}
                size={forumListSingle ? 38 : 42}
              />
              <View style={styles.forumRowText}>
                <RNText style={[styles.forumRowName, { color: colors.text }]} numberOfLines={1}>
                  {item.forumName}吧
                </RNText>
                {item.memberCount > 0 && (
                  <RNText style={[styles.forumRowMeta, { color: colors.textTertiary }]} numberOfLines={1}>
                    {formatCount(item.memberCount)} 关注
                  </RNText>
                )}
              </View>
              {/* 等级胶囊（Kotlin 样式）：chip 底 + Lv.X + 已签对勾（主题色） */}
              <View style={[styles.levelCapsule, { backgroundColor: colors.surfaceSecondary }]}>
                {item.levelId > 0 && (
                  <RNText style={[styles.forumRowLevel, { color: colors.primary }]}>
                    Lv.{item.levelId}
                  </RNText>
                )}
                {item.isSign && (
                  <SymbolView name="checkmark" size={10} weight="bold" tintColor={colors.primary} />
                )}
              </View>
            </View>
          </PressScale>
        </MenuView>
      </EntranceRow>
    ),
    [colors, handleForumPress, handleUnfollowConfirm, forumListSingle],
  );

  return (
    // ⚠️ 登录后主界面：ThemedHost 直包 VStack（SwiftUI 组件须为 Host 直子，
    // 否则在 RN View 中间层时挂 "being mounted inside a standard UIView"
    // RedBox）。top inset/padding 由外层 RN View 承担（同 notifications 写法）；
    // ignoreSafeArea='container' 会让 SwiftUI 端顶部安全区归零，此 padding 是关键。
    <View style={[styles.container, { paddingTop: insets.top }]}>
    <ThemedHost style={{ flex: 1 }} ignoreSafeArea="container">
    <VStack spacing={0}>
        {/* 顶部操作条：搜索栏 + 一键签到 / 排序切换 图标按钮（同一行，按钮在右顶端） */}
        <HomeTopActions
          isSigning={isSigning}
          onSignPress={handleSign}
          sortMode={forumSortMode}
          onSortPress={toggleSortMode}
        />

        {/* 最近访问 */}
        {showHistoryForum && recentForums.length > 0 && (
          <HStack
            spacing={8}
            modifiers={[padding({ horizontal: Spacing.lg, top: 6, bottom: Spacing.xs })]}
          >
            <Text modifiers={[font({ textStyle: 'subheadline', weight: 'semibold' })]}>
              最近访问
            </Text>
            <Spacer />
            <Button
              onPress={() => setHistoryExpanded((prev) => !prev)}
              modifiers={[buttonStyle('plain'), buttonBorderShape('capsule')]}
            >
              <Label
                title={historyExpanded ? '收起' : '展开'}
                systemImage={historyExpanded ? 'chevron.up' : 'chevron.down'}
              />
            </Button>
          </HStack>
        )}
        {showHistoryForum && historyExpanded && recentForums.length > 0 && (
          /* 最近访问：RN 横向行（头像缩略图 + 名称药丸，Kotlin 风格）。
             RNHostView matchContents 防拉伸；Avatar 缺图时回落首字色块。 */
          <RNHostView matchContents>
            <View style={styles.historyPillsWrap}>
              <RNScrollView
                horizontal
                showsHorizontalScrollIndicator={false}
                contentContainerStyle={styles.historyPillsContent}
              >
                {recentForums.map((f) => (
                  <HdrPressable
                    key={f.forumName}
                    onPress={() => router.push(`/forum/${encodeURIComponent(f.forumName)}`)}
                    style={[
                      styles.historyPill,
                      // chip 底色：surfaceSecondary 与页面背景同调（浅色下近白、
                      // 深色下同深灰），真机"名称后面没有背景"（2026-08-27）；
                      // 改 tint 底 + 主色文字，与信息流吧名徽章同款。
                      { backgroundColor: colors.chip },
                    ]}
                    flashRadius={17}
                    effect="subtle"
                    accessibilityRole="button"
                    accessibilityLabel={`进入${f.forumName}吧`}
                  >
                    <Avatar
                      source={f.avatar || cachedForumAvatars[forumAvatarKey(f) ?? '']?.avatar}
                      initials={f.forumName.replace(/吧$/, '').charAt(0)}
                      size={22}
                    />
                    <RNText style={[styles.historyPillText, { color: colors.onChip }]} numberOfLines={1}>
                      {f.forumName}
                    </RNText>
                  </HdrPressable>
                ))}
              </RNScrollView>
            </View>
          </RNHostView>
        )}

        {/* 吧列表 / 骨架 / 错误态：RN 子树必须经 RNHostView 挂进 SwiftUI
            VStack（文件头部搜索栏同款模式），flex 布局语义才能生效。 */}
        {/* 骨架只在「真实请求在途（或鉴权未定）且无内容」时出现：followedForums
            已有数据（含缓存命中落入 store）即直出列表、绝不闪骨架——缓存命中
            短路（2026-08-28）；下拉刷新走 pullingForums 专用态，不在此分支。 */}
        {followedForums.length === 0 && (authPending || isLoadingForums) ? (
          <RNHostView>
            <View style={{ flex: 1, width: '100%' }}>
              <SkeletonList variant="row" count={8} style={styles.forumSkeleton} />
            </View>
          </RNHostView>
        ) : forumsError && followedForums.length === 0 ? (
          <RNHostView>
            <View style={{ flex: 1, width: '100%' }}>
              <ErrorState
                title="加载失败"
                message={forumsError}
                icon="wifi.exclamationmark"
                onRetry={handleLoadFollowedForums}
                retryLabel="重试"
              />
            </View>
          </RNHostView>
        ) : followedForums.length === 0 ? (
          <ContentUnavailableView
            systemImage="tray"
            title="暂无关注的贴吧"
            description="去发现页探索感兴趣的贴吧吧"
          />
        ) : (
          <RNHostView>
            <View style={{ flex: 1, width: '100%' }}>
              <LegendList
                recycleItems
                ref={forumListRef}
                key={forumListSingle ? 'forum-list-single' : 'forum-list-grid'}
                data={sortedForums}
                keyExtractor={forumKeyExtractor}
                numColumns={forumListSingle ? 1 : 2}
                renderItem={renderForumItem}
                contentContainerStyle={styles.forumListContent}
                refreshControl={
                  <RefreshControl
                    refreshing={pullingForums}
                    onRefresh={handleRefresh}
                    tintColor={colors.primary}
                  />
                }
                drawDistance={200}
              />
            </View>
          </RNHostView>
        )}
      </VStack>
    </ThemedHost>

    {/* 底部渐罩：叠在列表之上、贴容器底 80pt；glass 底栏背后不再是纯平实色 */}
    <BottomFade />
    </View>
  );
}

// ── 液态玻璃搜索栏组件（参考设计：头像 + 玻璃搜索胶囊 + 签到按钮） ──

function SearchBarPill({ onPress }: { onPress: () => void }) {
  const { colors, isDark } = useThemeColors();
  const account = useAuthStore((s) => s.account);
  const isLoggedIn = useAuthStore((s) => s.isLoggedIn);
  const router = useRouter();

  return (
    <View style={[searchStyles.wrapper, { paddingTop: Spacing.xs }]}>
      <View style={searchStyles.row}>
        {/* Left: User Avatar */}
        <HdrPressable
          accessibilityRole="button"
          accessibilityLabel={isLoggedIn ? '个人主页' : '登录'}
          onPress={() => {
            if (isLoggedIn) {
              if (account?.uid) {
                router.push(`/user/${account.uid}`);
              } else {
                router.push('/settings/account');
              }
            } else {
              router.push('/login');
            }
          }}
          style={searchStyles.avatarWrap}
          flashRadius={18}
        >
          <Avatar
            source={account?.portrait || undefined}
            initials={account?.name?.charAt(0) || '?'}
            size={36}
          />
        </HdrPressable>

        {/* Center: Glass Search Pill —— 用应用内 GlassView（带 glassTokens 描边/高光，
            静态降级时也保持玻璃质感，避免 expo-glass-effect raw 组件的纯白降级） */}
        {/* 搜索入口 effect="subtle"（2026-08-28）：去掉 hdr 扫光/白闪/光晕——
            深色模式下点击搜索栏的高光扫过太显眼；保留自带 scale 按压反馈 */}
        <HdrPressable onPress={onPress} style={({ pressed }) => [searchStyles.pill, { transform: [{ scale: pressed ? 0.96 : 1 }] }]} flashRadius={18} effect="subtle">
          <GlassView
            style={StyleSheet.absoluteFill}
            borderRadius={18}
            // 搜索胶囊：radius=半高，保持 circular（2026-08-28 定案）
            cornerCurve="circular"
            glassEffectStyle="clear"
            theme={isDark ? 'dark' : 'light'}
            tintColor={isDark ? 'rgba(255,255,255,0.10)' : 'rgba(120,120,128,0.10)'}
          />
          {/* 可见描边：浅色白底上液态玻璃需要一条浅灰边才有轮廓，
              glassTokens 浅色 border 是白色，白对白不可见 → 这里显式覆盖 */}
          <View
            pointerEvents="none"
            style={[
              StyleSheet.absoluteFill,
              {
                borderRadius: 18,
                borderWidth: StyleSheet.hairlineWidth,
                borderColor: isDark ? 'rgba(255,255,255,0.35)' : 'rgba(120,120,128,0.45)',
              },
            ]}
          />
          <View style={searchStyles.pillInner}>
            <SymbolView name="magnifyingglass" size={15} tintColor={colors.textTertiary} style={{ marginRight: Spacing.sm }} />
            <RNText style={[searchStyles.text, { color: colors.textTertiary }]} numberOfLines={1}>
              搜吧、搜贴、搜人
            </RNText>
          </View>
        </HdrPressable>
      </View>
    </View>
  );
}

/**
 * 底部渐罩为公共组件（@/components/feed/BottomFade），index / explore 共用。
 * absolute 贴底、transparent → 轻微灰罩（明暗随主题，alpha 0.12）。
 * 底栏液态玻璃叠在纯平背景上时视觉等于实心色带（短列表/空列表/滚到底尤其明显），
 * 渐罩给玻璃背后提供渐变内容可折射；pointerEvents="none" 不挡点击、不挡滚动。
 */

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },

  // 单列/网格行容器同款 flex:1（thermo Z6：历史上两词条曾分叉，现已一致）
  forumMenu: {
    flex: 1,
  },
  /* 顶部图标按钮：34pt 胶囊玻璃钮（签到 / 布局切换），无文字 */
  topIconBtn: {
    width: 34,
    height: 34,
  },
  topIconBtnInner: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  /* 首页顶部条：RN 行，搜索胶囊 flex:1 铺满、图标按钮贴右 */
  topRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    width: '100%',
    paddingHorizontal: Spacing.lg,
    paddingTop: Spacing.sm,
  },
  forumSkeleton: {
    paddingHorizontal: Spacing.lg,
    paddingTop: Spacing.sm,
    paddingBottom: 24,
  },
  forumListContent: {
    paddingHorizontal: Spacing.lg,
    paddingTop: Spacing.sm,
    // 底栏（含 home indicator）高约 83pt：滑到底时最后一项必须停在底栏上边缘
    // 之上，不能被玻璃条罩住（此前 24pt 会让末项贴进条区）。
    paddingBottom: 100,
  },
  // 最近访问：横向药丸行（头像缩略图 + 名称）
  historyPillsWrap: {
    paddingHorizontal: Spacing.lg,
    paddingBottom: Spacing.sm,
  },
  historyPillsContent: {
    gap: 8,
    paddingRight: Spacing.lg,
  },
  historyPill: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingLeft: 4,
    paddingRight: 12,
    paddingVertical: 4,
    borderRadius: 999,
  },
  historyPillText: {
    fontSize: 13,
    fontWeight: '500',
    maxWidth: 140,
  },
  forumRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    ...RadiusStyle.card,
    paddingHorizontal: 14,
    paddingVertical: Spacing.md,
    marginBottom: Spacing.sm,
  },
  /* 双列（一行两个）卡片：略小的内边距以适配窄卡。
     列间间隙用 marginHorizontal（LegendList numColumns 不支持
     columnWrapperStyle，官方该 prop 仅提供 gap 语义的列容器样式） */
  forumCardGrid: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    ...RadiusStyle.card,
    paddingHorizontal: 10,
    paddingVertical: Spacing.sm + 2,
    marginHorizontal: Spacing.xs / 2,
    marginBottom: Spacing.xs,
  },
  forumRowText: { flex: 1, gap: 2 },
  forumRowName: { ...typographyStyles.subheadBold },
  forumRowMeta: { ...typographyStyles.caption1 },
  /* 等级胶囊（Kotlin ForumItemContent 对位）：chip 底色圆角盒，
     Lv.X + 已签对勾（对勾与 Lv 文字同色、12dp 圆角勾） */
  levelCapsule: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 4,
    borderRadius: 4,
    borderCurve: 'continuous',
    paddingHorizontal: 6,
    paddingVertical: 4,
  },
  forumRowLevel: { ...typographyStyles.caption1Bold },
});

const searchStyles = StyleSheet.create({
  wrapper: {
    paddingBottom: Spacing.sm,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
  },
  avatarWrap: {
    width: 36,
    height: 36,
    borderRadius: 18,
    overflow: 'hidden',
  },
  pill: {
    flex: 1,
    borderRadius: 18,
    height: 36,
    overflow: 'hidden',
  },
  pillInner: {
    flex: 1,
    flexDirection: 'row',
    alignItems: 'center',
    borderRadius: 18,
    paddingHorizontal: 14,
  },
  text: {
    ...typographyStyles.subhead,
  },
});
