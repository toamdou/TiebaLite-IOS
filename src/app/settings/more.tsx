import { useCallback, useState } from 'react';
import { Form, Section, Button, Label, Text, Picker, ConfirmationDialog } from '@expo/ui/swift-ui';
import { foregroundStyle, pickerStyle, tag } from '@expo/ui/swift-ui/modifiers';
import { useRouter } from 'expo-router';
import { openSettings } from 'expo-linking';
import { hapticForScene } from '@/theme/hapticsMap';
import { clearAuthCredentials } from '@/services/api/interceptors';
import { resetNotificationBaseline, stopNotificationPoller } from '@/services/NotificationPoller';
import { clearAllAuthSync, clearSecureCredentials } from '@/services/storage/AuthSQLiteStorage';
import { clearVisitHistory, clearHistoryAuthorPortraits } from '@/services/storage/visitHistory';
import { clearSearchHistory } from '@/storage/searchHistory';
import { clearAllUnifiedStorage, clearLegacyStorage } from '@/services/storage/unifiedDb';
import { clearBackgroundSnapshot } from '@/services/nativeBackground';
import { useAuthStore } from '@/stores/authStore';
import { BlockManager } from '@/utils/BlockManager';
import { openLink } from '@/utils/linkOpener';
import { usePreferencesStore } from '@/stores/preferencesStore';
import { useFormTint } from '@/hooks/useFormTint';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { navigateToSettingsRoute, NOTIFICATION_POLL_OPTIONS } from '@/constants/settings';
import { TiebaNative } from '../../../modules/tieba-native/src/TiebaNative';
import { applyCacheMaxSize, clearImageCaches } from '@/services/cache/cacheMaintenance';
import { clearForumAvatarCache } from '@/stores/forumAvatarCache';

export default function MoreSettingsPage() {
  const router = useRouter();
  const formTint = useFormTint();
  const preferences = usePreferencesStore((s) => s.preferences);
  const setPreference = usePreferencesStore((s) => s.setPreference);
  const resetPreferences = usePreferencesStore((s) => s.resetPreferences);
  const [showClearCache, setShowClearCache] = useState(false);
  const [showReset, setShowReset] = useState(false);
  const [showClearAll, setShowClearAll] = useState(false);

  // 消息检查频率：合法档位表 + 本地清洗兜底（expo-ui Picker 未知 selection 会崩）
  const POLL_MINUTES = NOTIFICATION_POLL_OPTIONS.map((o) => Number(o.value));
  const rawPollMinutes = preferences.notificationPollMinutes;
  const safePollMinutes = String(POLL_MINUTES.includes(rawPollMinutes) ? rawPollMinutes : 30);

  const handleOpenSystemSettings = useCallback(() => {
    hapticForScene('press');
    openSettings().catch(() => {});
  }, []);

  const handleClearCache = useCallback(async () => {
    hapticForScene('destructive');
    try {
      // expo-image 磁盘/内存双清 + Paths.cache 目录删除 + 原生缩略图缓存，
      // 统一走 cacheMaintenance.clearImageCaches（best-effort，永不抛错）。
      await clearImageCaches();
      // 作者头像引用按缓存处理：随图片缓存一并擦除（历史记录本身保留，
      // 头像回落首字占位，下次访问该帖重新入库）。
      await clearHistoryAuthorPortraits();
      // 吧头像 URL 缓存（全站统一：动态/最近访问/历史/收藏/搜索）唯一
      // 手动清理入口：不参与 cacheAutoCleanDays 自动清理，仅此按钮/
      // 清除全部数据会清空，之后各页按需重新拉取。
      clearForumAvatarCache();
      hapticForScene('action-success');
    } catch {
      hapticForScene('action-fail');
    }
    setShowClearCache(false);
  }, []);

  const handleReset = useCallback(async () => {
    hapticForScene('destructive');
    try {
      await resetPreferences();
      await BlockManager.clearAllBlocked();
      await clearLegacyStorage();
      hapticForScene('action-success');
    } catch {
      // resetPreferences 失败会向上抛错（preferencesStore 不再静默吞掉），
      // 这里与 handleClearCache 的失败反馈对齐。
      hapticForScene('action-fail');
    }
    setShowReset(false);
  }, [resetPreferences]);

  const handleClearAll = useCallback(async () => {
    hapticForScene('destructive');
    try {
      await resetPreferences();
      await clearAllUnifiedStorage();

      await clearSearchHistory();
      await clearVisitHistory();
      await BlockManager.clearAllBlocked();
      clearAllAuthSync();
      await clearSecureCredentials();
      clearAuthCredentials();
      clearBackgroundSnapshot();
      // 清除全部数据需一并清空 expo-image 磁盘/内存缓存与原生缩略图缓存：
      // 否则登出后头像、图片等仍残留在 Library/Caches/com.hackemist.SDImageCache，
      // 等于偷留一份“缓存里的账号痕迹”。与 handleClearCache 同一套兜底。
      await clearImageCaches();
      clearForumAvatarCache();
      stopNotificationPoller();
      TiebaNative.cancelAllBackgroundTasks();
      await resetNotificationBaseline();
      useAuthStore.setState({
        isLoggedIn: false,
        account: null,
        error: null,
        isLoading: false,
      });
      hapticForScene('action-success');
    } catch {
      hapticForScene('action-fail');
    }
    setShowClearAll(false);
  }, [resetPreferences]);

  return (
    <ThemedHost style={{ flex: 1 }}>
      <Form modifiers={formTint}>
        {/* 图片相关已拆至 /settings/image（2026-08-27 分类整改） */}

        <Section
          title="通知"
          footer={<Text>前台消息检查频率；低电量模式自动加倍，后台任务由系统统一调度。</Text>}
        >
          <Picker
            label="消息检查频率"
            selection={safePollMinutes}
            onSelectionChange={(v: string) => {
              const minutes = Number(v);
              if (POLL_MINUTES.includes(minutes)) {
                setPreference('notificationPollMinutes', minutes);
                hapticForScene('toggle');
              }
            }}
            modifiers={[pickerStyle('menu')]}
          >
            {NOTIFICATION_POLL_OPTIONS.map((opt) => (
              <Text key={opt.value} modifiers={[tag(opt.value)]}>{opt.label}</Text>
            ))}
          </Picker>
        </Section>

        <Section title="数据">
          <Picker
            label="自动清理缓存"
            selection={String(preferences.cacheAutoCleanDays ?? 0)}
            onSelectionChange={(v: string) => {
              setPreference('cacheAutoCleanDays', Number(v));
              hapticForScene('toggle');
            }}
            modifiers={[pickerStyle('menu')]}
          >
            <Text modifiers={[tag('0')]}>关闭</Text>
            <Text modifiers={[tag('1')]}>每 1 天</Text>
            <Text modifiers={[tag('3')]}>每 3 天</Text>
            <Text modifiers={[tag('7')]}>每 7 天</Text>
            <Text modifiers={[tag('15')]}>每 15 天</Text>
            <Text modifiers={[tag('30')]}>每 30 天</Text>
          </Picker>
          <Picker
            label="最大缓存大小"
            selection={String(preferences.cacheMaxSizeMb ?? 400)}
            onSelectionChange={(v: string) => {
              const mb = Number(v);
              setPreference('cacheMaxSizeMb', mb);
              applyCacheMaxSize(mb);
              hapticForScene('toggle');
            }}
            modifiers={[pickerStyle('menu')]}
          >
            <Text modifiers={[tag('100')]}>100 MB</Text>
            <Text modifiers={[tag('200')]}>200 MB</Text>
            <Text modifiers={[tag('400')]}>400 MB</Text>
            <Text modifiers={[tag('1000')]}>1000 MB</Text>
          </Picker>

          <ConfirmationDialog
            title="清除图片缓存"
            isPresented={showClearCache}
            onIsPresentedChange={setShowClearCache}
            titleVisibility="visible"
          >
            <ConfirmationDialog.Trigger>
              <Button
                label="清除图片缓存"
                systemImage="trash.fill"
                onPress={() => setShowClearCache(true)}
              />
            </ConfirmationDialog.Trigger>
            <ConfirmationDialog.Actions>
              <Button label="确定清除" role="destructive" onPress={handleClearCache} />
              <Button label="取消" role="cancel" />
            </ConfirmationDialog.Actions>
            <ConfirmationDialog.Message>
              <Text>图片与吧头像缓存将被清除（可在下次浏览时重新加载）；登录状态和应用设置不会被清除。</Text>
            </ConfirmationDialog.Message>
          </ConfirmationDialog>

          <ConfirmationDialog
            title="重置所有设置"
            isPresented={showReset}
            onIsPresentedChange={setShowReset}
            titleVisibility="visible"
          >
            <ConfirmationDialog.Trigger>
              <Button
                label="重置所有设置"
                systemImage="arrow.counterclockwise"
                onPress={() => setShowReset(true)}
              />
            </ConfirmationDialog.Trigger>
            <ConfirmationDialog.Actions>
              <Button label="确定重置" role="destructive" onPress={handleReset} />
              <Button label="取消" role="cancel" />
            </ConfirmationDialog.Actions>
            <ConfirmationDialog.Message>
              <Text>这将恢复默认主题、偏好等，请重启应用以生效。</Text>
            </ConfirmationDialog.Message>
          </ConfirmationDialog>

          <ConfirmationDialog
            title="清除全部数据"
            isPresented={showClearAll}
            onIsPresentedChange={setShowClearAll}
            titleVisibility="visible"
          >
            <ConfirmationDialog.Trigger>
              <Button
                label="清除全部数据"
                systemImage="trash.slash"
                onPress={() => setShowClearAll(true)}
              />
            </ConfirmationDialog.Trigger>
            <ConfirmationDialog.Actions>
              <Button label="确定清除" role="destructive" onPress={handleClearAll} />
              <Button label="取消" role="cancel" />
            </ConfirmationDialog.Actions>
            <ConfirmationDialog.Message>
              <Text>将清除登录状态、设置、历史、屏蔽数据与本地凭据，且不可恢复。</Text>
            </ConfirmationDialog.Message>
          </ConfirmationDialog>
        </Section>

        <Section title="外部链接">
          <Button
            label="开源仓库"
            systemImage="chevron.left.forwardslash.chevron.right"
            onPress={() => openLink('https://github.com/HuanChengFly/TiebaLite')}
          />
          <Button
            label="问题反馈"
            systemImage="exclamationmark.bubble.fill"
            onPress={() => openLink('https://github.com/HuanChengFly/TiebaLite/issues')}
          />
        </Section>

        <Section
          title="更多"
          footer={<Text>系统应用设置可管理通知、权限与后台任务。</Text>}
        >
          <Button onPress={() => navigateToSettingsRoute(router, '/settings/logs')}>
            <Label title="崩溃与卡顿日志" systemImage="exclamationmark.triangle" modifiers={[foregroundStyle('#FF9500')]} />
          </Button>
          <Button onPress={() => navigateToSettingsRoute(router, '/settings/about')}>
            <Label title="关于" systemImage="info.circle" modifiers={[foregroundStyle('#8E8E93')]} />
          </Button>
          <Button onPress={handleOpenSystemSettings}>
            <Label title="系统应用设置" systemImage="gear" modifiers={[foregroundStyle('#007AFF')]} />
          </Button>
        </Section>
      </Form>
    </ThemedHost>
  );
}
