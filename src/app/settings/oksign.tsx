/**
 * OKSign Settings Page (一键签到设置)
 *
 * Mirrors Kotlin TiebaLite OKSignSettingsPage:
 * - One-click sign button with progress display
 * - Auto sign scheduling (daily)
 * - Slow mode / fail-auto-stop / official batch sign toggles
 *
 * Preferences are read/written directly through usePreferencesStore so the
 * page never holds local copies of auto-sign settings.
 */

import { useCallback, useEffect, useState } from 'react';
import { Alert, StyleSheet, View } from 'react-native';
import { Text as RNText } from '../../components/ui/CompatText';
import {
  Button,
  DatePicker,
  Form,
  HStack,
  Picker,
  ProgressView,
  RNHostView,
  Section,
  Spacer,
  Text,
  Toggle,
} from '@expo/ui/swift-ui';
import {
  buttonStyle,
  controlSize,
  disabled,
  font,
  foregroundStyle,
  pickerStyle,
  progressViewStyle,
  tag,
  tint,
} from '@expo/ui/swift-ui/modifiers';
import { Stack } from 'expo-router';
import { hapticForScene } from '@/theme/hapticsMap';
import { useSignStore } from '@/stores/signStore';
import { useAuthStore } from '@/stores/authStore';
import { usePreferencesStore } from '@/stores/preferencesStore';
import { useFormTint } from '@/hooks/useFormTint';
import { useThemeColors } from '@/theme/ThemeContext';
import { Spacing, typographyStyles } from '@/theme';
import type { SignProgressItem } from '@/stores/signStore';
import { SymbolView } from '@/components/ui/SymbolView';
import { recoverStaleSignLiveActivities } from '@/services/liveActivity';
import { ThemedHost } from '@/components/ui/ThemedHost';

function parseTimeToDate(time: string): Date {
  const [hours, minutes] = time.split(':').map(Number);
  const date = new Date();
  date.setHours(
    Number.isFinite(hours) ? hours : 8,
    Number.isFinite(minutes) ? minutes : 0,
    0,
    0,
  );
  return date;
}

/**
 * 一键签到设置页（2026-08-29：移除 LiveActivityPreview 预览图形——
 * 用户要求"删除掉那几张图片"；签到进度展示位置仍可在灵动岛/通知栏间切换）。
 */
export default function OKSignSettingsPage() {
  const { colors } = useThemeColors();
  const formTint = useFormTint();
  const isLoggedIn = useAuthStore((s) => s.isLoggedIn);

  // Sign store state
  const isSigning = useSignStore((s) => s.isSigning);
  const status = useSignStore((s) => s.status);
  const totalCount = useSignStore((s) => s.totalCount);
  const successCount = useSignStore((s) => s.successCount);
  const failCount = useSignStore((s) => s.failCount);
  const currentIndex = useSignStore((s) => s.currentIndex);
  const totalExp = useSignStore((s) => s.totalExp);
  const progressList = useSignStore((s) => s.progressList);
  const signError = useSignStore((s) => s.error);

  const startSign = useSignStore((s) => s.startSign);
  const cancelSign = useSignStore((s) => s.cancelSign);
  const reset = useSignStore((s) => s.reset);
  const scheduleAutoSign = useSignStore((s) => s.scheduleAutoSign);
  const cancelAutoSign = useSignStore((s) => s.cancelAutoSign);
  const checkAutoSignScheduled = useSignStore((s) => s.checkAutoSignScheduled);

  // Preferences are subscribed directly from the shared store.
  const hasHydrated = usePreferencesStore((s) => s.hasHydrated);
  const autoSign = usePreferencesStore((s) => s.preferences.autoSign);
  const autoSignTime = usePreferencesStore((s) => s.preferences.autoSignTime);
  const slowSignMode = usePreferencesStore((s) => s.preferences.slowSignMode);
  const failAutoStop = usePreferencesStore((s) => s.preferences.failAutoStop);
  const useOfficialSign = usePreferencesStore((s) => s.preferences.useOfficialSign);
  const signDisplayMode = usePreferencesStore((s) => s.preferences.signDisplayMode);
  const signSilent = usePreferencesStore((s) => s.preferences.signSilent);
  const liveActivitySignEnabled = usePreferencesStore((s) => s.preferences.liveActivitySignEnabled);
  const setPreference = usePreferencesStore((s) => s.setPreference);

  const [isScheduled, setIsScheduled] = useState(false);

  useEffect(() => {
    checkAutoSignScheduled()
      .then(setIsScheduled)
      .catch(() => setIsScheduled(false));
  }, [checkAutoSignScheduled]);

  // ---------- Handlers ----------

  const handleManualSign = useCallback(async () => {
    if (!isLoggedIn) {
      Alert.alert('提示', '请先登录后再使用一键签到');
      return;
    }
    if (isSigning) return;

    // startSign 内部捕获一切异常并写入 signError，永不向外抛出——
    // 原来的 try/catch Alert 是死代码，已删除。
    hapticForScene('press');
    await startSign();
  }, [isLoggedIn, isSigning, startSign]);

  const handleCancelSign = useCallback(() => {
    cancelSign();
  }, [cancelSign]);

  const handleAutoSignToggle = useCallback(
    async (value: boolean) => {
      hapticForScene('toggle');
      setPreference('autoSign', value);
      try {
        if (value) {
          await scheduleAutoSign(autoSignTime);
          setIsScheduled(true);
        } else {
          await cancelAutoSign();
          setIsScheduled(false);
        }
      } catch {
        setPreference('autoSign', !value);
        setIsScheduled(false);
        Alert.alert('错误', '设置自动签到失败');
      }
    },
    [autoSignTime, scheduleAutoSign, cancelAutoSign, setPreference],
  );

  const handleSlowModeToggle = useCallback(
    (value: boolean) => {
      hapticForScene('toggle');
      setPreference('slowSignMode', value);
    },
    [setPreference],
  );

  const handleFailAutoStopToggle = useCallback(
    (value: boolean) => {
      hapticForScene('toggle');
      setPreference('failAutoStop', value);
    },
    [setPreference],
  );

  const handleOfficialSignToggle = useCallback(
    (value: boolean) => {
      hapticForScene('toggle');
      setPreference('useOfficialSign', value);
    },
    [setPreference],
  );

  const handleDisplayModeChange = useCallback(
    (value: string) => {
      hapticForScene('toggle');
      setPreference('signDisplayMode', value === 'notification' ? 'notification' : 'liveActivity');
      if (value === 'notification') {
        recoverStaleSignLiveActivities().catch(() => {});
      }
    },
    [setPreference],
  );

  const handleSilentToggle = useCallback(
    (value: boolean) => {
      hapticForScene('toggle');
      setPreference('signSilent', value);
    },
    [setPreference],
  );

  // 灵动岛总开关：关闭时结束在场的签到 Live Activity（与切「通知栏」同款清理），
  // 之后签到不再上灵动岛、后台静默完成。
  const handleLiveActivityToggle = useCallback(
    (value: boolean) => {
      hapticForScene('toggle');
      setPreference('liveActivitySignEnabled', value);
      if (!value) {
        recoverStaleSignLiveActivities().catch(() => {});
      }
    },
    [setPreference],
  );

  const handleTimeChange = useCallback(
    (date: Date) => {
      const previous = autoSignTime;
      const next = `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
      setPreference('autoSignTime', next);
      if (autoSign) {
        scheduleAutoSign(next)
          .then(() => setIsScheduled(true))
          .catch(() => {
            // 原生注册失败时回滚为旧值，避免 UI 与定时任务不一致。
            setPreference('autoSignTime', previous);
            setIsScheduled(false);
            Alert.alert('错误', '更新签到时间失败');
          });
      }
    },
    [autoSign, autoSignTime, scheduleAutoSign, setPreference],
  );

  // 未水合时返回轻量占位，避免整页白屏闪烁
  if (!hasHydrated) {
    return (
      <ThemedHost style={{ flex: 1, alignItems: 'center', justifyContent: 'center' }}>
        <ProgressView modifiers={[progressViewStyle('circular'), tint(colors.primary)]} />
      </ThemedHost>
    );
  }

  // currentIndex = 已完成数（对齐 Kotlin onProgressFinish 的已完成语义）。
  const signProgress =
    totalCount > 0 ? Math.min(currentIndex / totalCount, 1) : 0;

  return (
    <ThemedHost style={{ flex: 1 }}>
      <Stack.Screen options={{ title: '一键签到' }} />
      <Form modifiers={formTint}>
        <Section title="一键签到">
          <Button
            label={isLoggedIn ? '一键签到' : '请先登录'}
            systemImage="checkmark.circle.fill"
            onPress={handleManualSign}
            modifiers={[
              buttonStyle('borderedProminent'),
              controlSize('large'),
              tint(colors.primary),
              disabled(!isLoggedIn),
            ]}
          />
          <Text
            modifiers={[
              font({ textStyle: 'caption' }),
              foregroundStyle({ type: 'hierarchical', style: 'secondary' }),
            ]}
          >
            点击立即签到所有关注的贴吧
          </Text>
        </Section>

        {isSigning && (
          <Section title="签到进度">
            <Text>正在签到 {currentIndex} / {totalCount}</Text>
            <ProgressView
              value={signProgress}
              modifiers={[progressViewStyle('linear'), tint(colors.primary)]}
            />
            <HStack spacing={Spacing.md} alignment="center">
              <RNHostView matchContents>
                <View style={styles.signStatRow}>
                  <SymbolView name="checkmark.circle.fill" size={16} tintColor={colors.success} />
                  <RNText style={[styles.signStatText, { color: colors.success }]}>{successCount}</RNText>
                  <SymbolView name="xmark.circle" size={16} tintColor={colors.danger} />
                  <RNText style={[styles.signStatText, { color: colors.danger }]}>{failCount}</RNText>
                </View>
              </RNHostView>
              {totalExp > 0 && (
                <Text
                  modifiers={[
                    foregroundStyle({ type: 'hierarchical', style: 'secondary' }),
                  ]}
                >
                  +{totalExp} 经验
                </Text>
              )}
            </HStack>
            <Button
              label="取消签到"
              systemImage="xmark.circle.fill"
              role="destructive"
              onPress={handleCancelSign}
            />
          </Section>
        )}

        {status === 'completed' && (
          <Section title="签到结果">
            <Text modifiers={[foregroundStyle(colors.success), font({ weight: 'semibold' })]}>
              签到完成
            </Text>
            <Text
              modifiers={[
                foregroundStyle({ type: 'hierarchical', style: 'secondary' }),
              ]}
            >
              成功 {successCount} 个
              {failCount > 0 ? `，失败 ${failCount} 个` : ''}
              {totalExp > 0 ? `，获得 ${totalExp} 经验` : ''}
            </Text>
            <Button label="完成" systemImage="checkmark" onPress={reset} />
          </Section>
        )}

        {status === 'error' && signError && (
          <Section title="签到出错">
            <Text modifiers={[foregroundStyle(colors.danger), font({ weight: 'semibold' })]}>
              签到出错
            </Text>
            <Text
              modifiers={[
                foregroundStyle({ type: 'hierarchical', style: 'secondary' }),
              ]}
            >
              {signError}
            </Text>
            <Button label="关闭" systemImage="xmark" onPress={reset} />
          </Section>
        )}

        <Section title="进度显示">
          <Picker
            label="签到进度显示位置"
            selection={signDisplayMode}
            onSelectionChange={handleDisplayModeChange}
            modifiers={[pickerStyle('menu')]}
          >
            <Text modifiers={[tag('liveActivity')]}>灵动岛</Text>
            <Text modifiers={[tag('notification')]}>通知栏</Text>
          </Picker>
          <Text
            modifiers={[
              font({ textStyle: 'caption' }),
              foregroundStyle({ type: 'hierarchical', style: 'secondary' }),
            ]}
          >
            选择在灵动岛还是通知栏显示签到进度
          </Text>
          {signDisplayMode === 'liveActivity' && (
            <Toggle isOn={liveActivitySignEnabled} onIsOnChange={handleLiveActivityToggle}>
              <Text>灵动岛实时进度</Text>
              <Text>关闭后签到进度不再显示在灵动岛，后台静默完成</Text>
            </Toggle>
          )}
          <Toggle isOn={signSilent} onIsOnChange={handleSilentToggle}>
            <Text>静默显示</Text>
            <Text>签到完成通知不发声，横幅照常显示</Text>
          </Toggle>
        </Section>

        <Section title="自动签到">
          <Toggle isOn={autoSign} onIsOnChange={handleAutoSignToggle}>
            <Text>每日自动签到</Text>
            <Text>在每天指定时间尝试后台自动签到</Text>
          </Toggle>
          {autoSign && (
            <DatePicker
              title="签到时间"
              selection={parseTimeToDate(autoSignTime)}
              displayedComponents={['hourAndMinute']}
              onDateChange={handleTimeChange}
            />
          )}
          {isScheduled && (
            <Text
              modifiers={[
                font({ textStyle: 'caption' }),
                foregroundStyle({ type: 'hierarchical', style: 'secondary' }),
              ]}
            >
              将在每天 {autoSignTime} 自动签到
            </Text>
          )}
        </Section>

        <Section title="签到行为">
          <Toggle isOn={slowSignMode} onIsOnChange={handleSlowModeToggle}>
            <Text>慢速模式</Text>
            <Text>降低签到速度，减少被限制的风险</Text>
          </Toggle>
          <Toggle isOn={failAutoStop} onIsOnChange={handleFailAutoStopToggle}>
            <Text>失败自动停止</Text>
            <Text>遇到签到失败时立即停止</Text>
          </Toggle>
          <Toggle isOn={useOfficialSign} onIsOnChange={handleOfficialSignToggle}>
            <Text>使用官方批量签到</Text>
            <Text>优先使用贴吧官方批量签到接口</Text>
          </Toggle>
        </Section>

        {progressList.length > 0 && (
          <Section title="进度列表">
            {status === 'completed' ? (
              // 完成态折叠为摘要，不再保留逐吧明细
              <HStack spacing={Spacing.md} alignment="center">
                <RNHostView matchContents>
                  <View style={styles.signStatRow}>
                    <SymbolView name="checkmark.circle.fill" size={16} tintColor={colors.success} />
                    <RNText style={[styles.signStatText, { color: colors.success }]}>{successCount}</RNText>
                    {failCount > 0 && (
                      <>
                        <SymbolView name="xmark.circle" size={16} tintColor={colors.danger} />
                        <RNText style={[styles.signStatText, { color: colors.danger }]}>{failCount}</RNText>
                      </>
                    )}
                  </View>
                </RNHostView>
                {totalExp > 0 && (
                  <Text
                    modifiers={[
                      foregroundStyle({ type: 'hierarchical', style: 'secondary' }),
                    ]}
                  >
                    共 {progressList.length} 个吧 · +{totalExp} 经验
                  </Text>
                )}
              </HStack>
            ) : (
              progressList.map((item: SignProgressItem, index: number) => (
                <HStack
                  key={item.forumId || `progress-${index}`}
                  spacing={Spacing.sm}
                  alignment="center"
                >
                  <Text modifiers={[font({ weight: 'medium' })]}>{item.forumName}</Text>
                  <Spacer />
                  {item.status === 'success' && (
                    <RNHostView matchContents>
                      <View style={styles.signStatRow}>
                        <SymbolView name="checkmark.circle.fill" size={16} tintColor={colors.success} />
                        {item.exp ? (
                          <RNText style={[styles.signStatText, { color: colors.success }]}>+{item.exp}</RNText>
                        ) : null}
                      </View>
                    </RNHostView>
                  )}
                  {item.status === 'failed' && (
                    <RNHostView matchContents>
                      <SymbolView name="xmark.circle" size={16} tintColor={colors.danger} />
                    </RNHostView>
                  )}
                  {item.status === 'signing' && (
                    <ProgressView modifiers={[progressViewStyle('circular')]} />
                  )}
                  {item.status === 'pending' && (
                    <Text
                      modifiers={[
                        foregroundStyle({ type: 'hierarchical', style: 'secondary' }),
                      ]}
                    >
                      等待中
                    </Text>
                  )}
                </HStack>
              ))
            )}
          </Section>
        )}

        <Section title="关于一键签到">
          <Text
            modifiers={[
              font({ textStyle: 'caption' }),
              foregroundStyle({ type: 'hierarchical', style: 'secondary' }),
            ]}
          >
            一键签到会依次为您关注的每一个贴吧签到。开启自动签到后，应用会在每天指定时间通过后台任务自动签到。频繁签到可能被贴吧系统临时限制，建议开启慢速模式降低风险。
          </Text>
        </Section>
      </Form>
    </ThemedHost>
  );
}

const styles = StyleSheet.create({
  signStatRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: Spacing.xs,
  },
  signStatText: typographyStyles.subheadBold,
});
