/**
 * Settings Page (设置) — 官方 @expo/ui FieldGroup 原生 Form 实现
 *
 * FieldGroup（iOS = SwiftUI Form，iOS 26 液态玻璃分组材质）+ ListItem
 * （原生行：leading 色块图标 / 标题 / 副标题 / trailing 开关或 chevron），
 * 分隔线、行高、分组全部由原生渲染。全局背景白色。
 */

import { FieldGroup, ListItem, Switch } from '@expo/ui';
import { useCallback, useState } from 'react';
import { Alert, StyleSheet, View } from 'react-native';
import { useRouter } from 'expo-router';
import { hapticForScene } from '@/theme/hapticsMap';
import { tint } from '@expo/ui/swift-ui/modifiers';
import { useThemeColors } from '@/theme/ThemeContext';
import { usePreferencesStore } from '@/stores/preferencesStore';
import {
  authenticateForUnlock,
  isBiometricsReady,
  useAppLockStore,
} from '@/stores/appLockStore';
import { syncHapticEnginePower } from '@/utils/haptics';
import { showToast } from '@/components/ui/Toast';
import { navigateToSettingsRoute } from '@/constants/settings';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { RowIcon } from '@/components/ui/RowIcon';

/** 行前色块图标：见 @/components/ui/RowIcon（Profile/Settings 统一） */
export default function SettingsPage() {
  const router = useRouter();
  const { colors, themeName } = useThemeColors();
  // 「默认」主题 = 初始内置态：行图标恢复五彩、原生行不染主色
  const isDefaultTheme = themeName === 'default';
  const rowTint = (c: string) => (isDefaultTheme ? c : colors.primary);
  const setPreference = usePreferencesStore((s) => s.setPreference);
  const hapticFeedback = usePreferencesStore((s) => s.preferences.hapticFeedback);
  const appLockEnabled = useAppLockStore((s) => s.enabled);
  const setAppLockEnabled = useAppLockStore((s) => s.setEnabled);
  const [appLockBusy, setAppLockBusy] = useState(false);

  // 开/关都先过一次面容验证：开启是确认本人意愿，关闭防止拿到
  // 已解锁手机的人直接把锁摘掉。
  const handleAppLockChange = useCallback(async (v: boolean) => {
    if (appLockBusy) return;
    setAppLockBusy(true);
    try {
      if (v && !(await isBiometricsReady())) {
        Alert.alert('无法开启应用锁', '此设备不支持面容 ID 或尚未录入，请先在系统设置中录入面容。');
        return;
      }
      const res = await authenticateForUnlock(v ? '验证面容以开启应用锁' : '验证面容以关闭应用锁');
      if (!res.ok) {
        showToast(res.message);
        return;
      }
      await setAppLockEnabled(v);
      hapticForScene('toggle');
      showToast(v ? '应用锁已开启' : '应用锁已关闭');
    } catch {
      Alert.alert('操作失败', '安全存储读写异常，请重试。');
    } finally {
      setAppLockBusy(false);
    }
  }, [appLockBusy, setAppLockEnabled]);

  return (
    <View style={[styles.container, { backgroundColor: colors.background }]}>
      {/* FieldGroup = SwiftUI Form：必须经 ThemedHost（Host 桥）嵌入 RN 树，
          否则 Form 不撑开高度导致列表消失 */}
      <ThemedHost style={{ flex: 1 }}>
        {/* tint 环境级下发：Section 内原生行（ListItem chevron/Switch）统一主色 */}
        <FieldGroup modifiers={isDefaultTheme ? [] : [tint(colors.primary)]}>
        {/* ── 外观 ── */}
        <FieldGroup.Section title="外观">
          <ListItem
            leading={<RowIcon icon="paintpalette.fill" tint={rowTint('#AF52DE')} />}
            supportingText="深浅色外观、字号、导航栏样式"
            onPress={() => navigateToSettingsRoute(router, '/settings/theme')}
          >
            个性化
          </ListItem>
        </FieldGroup.Section>

        {/* ── 使用习惯 ── 振动是操作反馈偏好，归使用习惯（2026-08-28 分类整改） */}
        <FieldGroup.Section title="使用习惯">
          <ListItem
            leading={<RowIcon icon="slider.horizontal.3" tint={rowTint('#8E8E93')} />}
            supportingText="首页、浏览、贴子、内容等偏好"
            onPress={() => navigateToSettingsRoute(router, '/settings/habit')}
          >
            使用习惯
          </ListItem>
          <ListItem
            leading={<RowIcon icon="iphone.radiowaves.left.and.right" tint={rowTint('#8E8E93')} />}
            supportingText="点击、长按、成功/失败等操作反馈"
            trailing={
              <Switch
                value={hapticFeedback}
                modifiers={isDefaultTheme ? [] : [tint(colors.primary)]}
                onValueChange={(v) => {
                  setPreference('hapticFeedback', v);
                  // 引擎即时加减（开=预热消除首触发迟滞；关=销毁省电）
                  syncHapticEnginePower(v);
                  if (v) hapticForScene('toggle');
                }}
              />
            }
          >
            振动反馈
          </ListItem>
          <ListItem
            leading={<RowIcon icon="waveform" tint={rowTint('#FF9500')} />}
            supportingText="为每个场景单独选择振动强度"
            onPress={() => navigateToSettingsRoute(router, '/settings/haptics')}
          >
            振动设置
          </ListItem>
          <ListItem
            leading={<RowIcon icon="checkmark.circle" tint={rowTint('#34C759')} />}
            supportingText="自动签到关注的贴吧"
            onPress={() => navigateToSettingsRoute(router, '/settings/oksign')}
          >
            一键签到
          </ListItem>
        </FieldGroup.Section>

        {/* ── 内容与流量 ── */}
        <FieldGroup.Section title="内容与流量">
          <ListItem
            leading={<RowIcon icon="photo.on.rectangle" tint={rowTint('#34C759')} />}
            supportingText="图片加载策略、水印、清晰度与流量"
            onPress={() => navigateToSettingsRoute(router, '/settings/image')}
          >
            图片与流量
          </ListItem>
          <ListItem
            leading={<RowIcon icon="hand.raised" tint={rowTint('#FF9500')} />}
            supportingText="屏蔽词、屏蔽用户、云端黑名单"
            onPress={() => navigateToSettingsRoute(router, '/settings/block')}
          >
            屏蔽设置
          </ListItem>
        </FieldGroup.Section>

        {/* ── 账号与安全 ── */}
        <FieldGroup.Section title="账号与安全">
          <ListItem
            leading={<RowIcon icon="person.circle" tint={rowTint('#4477E0')} />}
            supportingText="登录账号、退出登录"
            onPress={() => navigateToSettingsRoute(router, '/settings/account')}
          >
            账号管理
          </ListItem>
          <ListItem
            leading={<RowIcon icon="faceid" tint={rowTint('#34C759')} />}
            supportingText="冷启动或从后台返回时需验证面容"
            trailing={
              <Switch
                value={appLockEnabled}
                disabled={appLockBusy}
                modifiers={isDefaultTheme ? [] : [tint(colors.primary)]}
                onValueChange={(v) => { void handleAppLockChange(v); }}
              />
            }
          >
            面容 ID 应用锁
          </ListItem>
        </FieldGroup.Section>

        {/* ── 通用 ── */}
        <FieldGroup.Section title="通用">
          <ListItem
            leading={<RowIcon icon="ellipsis.circle" tint={rowTint('#8E8E93')} />}
            supportingText="缓存与数据、外部链接、日志与关于"
            onPress={() => navigateToSettingsRoute(router, '/settings/more')}
          >
            更多设置
          </ListItem>
        </FieldGroup.Section>
        </FieldGroup>
      </ThemedHost>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
});
