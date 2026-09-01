import { useCallback, useRef, useState } from 'react';
import { Form, Section, Toggle, Picker, Text, Slider, LabeledContent, HStack } from '@expo/ui/swift-ui';
import { pickerStyle, tag } from '@expo/ui/swift-ui/modifiers';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { hapticForScene } from '@/theme/hapticsMap';
import { usePreferencesStore } from '@/stores/preferencesStore';
import { useFormTint } from '@/hooks/useFormTint';
import { TiebaNative } from '../../../modules/tieba-native/src/TiebaNative';
import {
  DEFAULT_SORT_OPTIONS,
  FORUM_FAB_OPTIONS,
  START_TAB_OPTIONS,
  TIMESTAMP_STYLE_OPTIONS,
} from '@/constants/settings';
import type { AppPreferences } from '@/types';

/** 所有值为 boolean 的偏好键：把 handlePrefChange 的入参从全量键收窄为开关键。 */
type BooleanPreferenceKey = {
  [K in keyof AppPreferences]: AppPreferences[K] extends boolean ? K : never;
}[keyof AppPreferences];

/**
 * 使用习惯 — 全部行直接嵌在 Form/Section 下（SwiftUI 原生行）。
 * ⚠️ 不要用逐行 ThemedHost 包裹 Toggle：Host 行会被 Form 整体居中，
 * 导致整页设置项水平居中（踩过）。逐行须保持与 theme.tsx 相同的写法。
 */
export default function HabitSettingsPage() {
  const preferences = usePreferencesStore((s) => s.preferences);
  const setPreference = usePreferencesStore((s) => s.setPreference);
  const formTint = useFormTint();

  const handlePrefChange = useCallback((key: BooleanPreferenceKey, v: boolean) => {
    hapticForScene('toggle');
    setPreference(key, v);
  }, [setPreference]);

  const handleSortChange = useCallback((v: string) => {
    hapticForScene('toggle');
    setPreference('defaultSortType', v);
  }, [setPreference]);

  const handleFabChange = useCallback((v: string) => {
    hapticForScene('toggle');
    setPreference('forumFabFunction', v);
  }, [setPreference]);

  // ── 顶栏透明度（无级调节，即时生效）──
  // SwiftUI Slider 拖动由系统接管（非受控）：拖动中只把值推给原生 setter
  // 实时预览（不写 store，避免每帧重渲染驱动控件抖动），松手才持久化；
  // 百分比文本用本地 state 跟进显示。
  const glassAlphaRef = useRef(preferences.navBarGlassAlpha);
  const [glassAlphaLabel, setGlassAlphaLabel] = useState(() =>
    Math.round(preferences.navBarGlassAlpha * 100),
  );
  const handleGlassAlphaChange = useCallback((v: number) => {
    const clamped = Math.min(Math.max(v, 0), 1);
    glassAlphaRef.current = clamped;
    setGlassAlphaLabel(Math.round(clamped * 100));
    TiebaNative.setNavBarGlassAlpha(clamped);
  }, []);
  const handleGlassAlphaEditEnd = useCallback(() => {
    setPreference('navBarGlassAlpha', glassAlphaRef.current);
    TiebaNative.setNavBarGlassAlpha(glassAlphaRef.current);
  }, [setPreference]);

  const handleStartTabChange = useCallback((v: string) => {
    hapticForScene('toggle');
    setPreference('startTab', v as AppPreferences['startTab']);
  }, [setPreference]);

  const handleTimestampChange = useCallback((v: string) => {
    hapticForScene('toggle');
    setPreference('timestampStyle', v as AppPreferences['timestampStyle']);
  }, [setPreference]);

  // 枚举键本地白名单兜底：保证 Picker selection 恒为现有 tag（expo-ui 崩溃防线）
  const safePick = (raw: string, allowed: readonly string[], fallback: string) =>
    allowed.includes(raw) ? raw : fallback;
  const safeStartTab = safePick(
    preferences.startTab,
    START_TAB_OPTIONS.map((o) => o.value),
    'index',
  );
  const safeTimestamp = safePick(
    preferences.timestampStyle,
    TIMESTAMP_STYLE_OPTIONS.map((o) => o.value),
    'relative',
  );

  return (
    <ThemedHost style={{ flex: 1 }}>
      <Form modifiers={formTint}>
        <Section title="首页">
          <Toggle
            label="显示历史吧"
            systemImage="clock.fill"
            isOn={preferences.homePageShowHistoryForum}
            onIsOnChange={(v) => handlePrefChange('homePageShowHistoryForum', v)}
          />
          <Toggle
            label="关注吧列表单列"
            systemImage="list.bullet"
            isOn={preferences.forumListSingle}
            onIsOnChange={(v) => handlePrefChange('forumListSingle', v)}
          />
          <Picker
            label="启动默认页"
            selection={safeStartTab}
            onSelectionChange={handleStartTabChange}
            modifiers={[pickerStyle('menu')]}
          >
            {START_TAB_OPTIONS.map((opt) => (
              <Text key={opt.value} modifiers={[tag(opt.value)]}>{opt.label}</Text>
            ))}
          </Picker>
        </Section>

        <Section title="浏览">
          <Toggle
            label="无痕模式"
            systemImage="theatermasks.fill"
            isOn={preferences.incognitoMode}
            onIsOnChange={(v) => handlePrefChange('incognitoMode', v)}
          />
          <Toggle
            label="使用内置浏览器"
            systemImage="safari.fill"
            isOn={preferences.useBuiltInBrowser}
            onIsOnChange={(v) => handlePrefChange('useBuiltInBrowser', v)}
          />
          <Toggle
            label="自动刷新动态"
            systemImage="arrow.clockwise"
            isOn={preferences.exploreAutoRefresh}
            onIsOnChange={(v) => handlePrefChange('exploreAutoRefresh', v)}
          />
          <Toggle
            label="剪贴板链接识别"
            systemImage="doc.on.clipboard"
            isOn={preferences.clipboardLinkDetection}
            onIsOnChange={(v) => handlePrefChange('clipboardLinkDetection', v)}
          />
          <Toggle
            label="双击顶栏回顶"
            systemImage="arrow.up.circle"
            isOn={preferences.navBarDoubleTapToTop}
            onIsOnChange={(v) => handlePrefChange('navBarDoubleTapToTop', v)}
          />
          <LabeledContent label="顶栏透明度">
            <HStack spacing={8}>
              <Slider
                min={0}
                max={1}
                step={0.01}
                value={preferences.navBarGlassAlpha}
                onValueChange={handleGlassAlphaChange}
                onEditingChanged={(editing) => {
                  if (!editing) handleGlassAlphaEditEnd();
                }}
              />
              <Text>{glassAlphaLabel}%</Text>
            </HStack>
          </LabeledContent>
          <Toggle
            label="底栏滚动收纳"
            systemImage="menubar.rectangle"
            isOn={preferences.tabBarMinimizeEnabled}
            onIsOnChange={(v) => handlePrefChange('tabBarMinimizeEnabled', v)}
          >
            <Text>下滑收起底部栏、上滑恢复；关闭后底栏常驻</Text>
          </Toggle>
          <Picker
            label="吧默认排序方式"
            selection={preferences.defaultSortType}
            onSelectionChange={handleSortChange}
            modifiers={[pickerStyle('menu')]}
          >
            {DEFAULT_SORT_OPTIONS.map((opt) => (
              <Text key={opt.value} modifiers={[tag(opt.value)]}>{opt.label}</Text>
            ))}
          </Picker>
          <Toggle
            label="隐藏媒体内容"
            systemImage="photo.on.rectangle.angled"
            isOn={preferences.hideMedia}
            onIsOnChange={(v) => handlePrefChange('hideMedia', v)}
          />
        </Section>

        <Section title="贴子">
          <Toggle
            label="显示两个用户名"
            systemImage="person.2.fill"
            isOn={preferences.showBothUsername}
            onIsOnChange={(v) => handlePrefChange('showBothUsername', v)}
          />
          <Toggle
            label="贴内显示快捷按钮"
            systemImage="bolt.fill"
            isOn={preferences.showShortcutInThread}
            onIsOnChange={(v) => handlePrefChange('showShortcutInThread', v)}
          />
          <Picker
            label="悬浮按钮功能"
            selection={preferences.forumFabFunction}
            onSelectionChange={handleFabChange}
            modifiers={[pickerStyle('menu')]}
          >
            {FORUM_FAB_OPTIONS.map((opt) => (
              <Text key={opt.value} modifiers={[tag(opt.value)]}>{opt.label}</Text>
            ))}
          </Picker>
          <Picker
            label="时间显示格式"
            selection={safeTimestamp}
            onSelectionChange={handleTimestampChange}
            modifiers={[pickerStyle('menu')]}
          >
            {TIMESTAMP_STYLE_OPTIONS.map((opt) => (
              <Text key={opt.value} modifiers={[tag(opt.value)]}>{opt.label}</Text>
            ))}
          </Picker>
          <Toggle
            label="显示 IP 属地"
            systemImage="location.fill"
            isOn={preferences.showIpLocation}
            onIsOnChange={(v) => handlePrefChange('showIpLocation', v)}
          />
          <Toggle
            label="显示等级徽标"
            systemImage="shield.fill"
            isOn={preferences.showLevelBadge}
            onIsOnChange={(v) => handlePrefChange('showLevelBadge', v)}
          />
        </Section>

        <Section title="内容">
          <Toggle
            label="隐藏屏蔽内容"
            systemImage="nosign"
            isOn={preferences.hideBlockedContent}
            onIsOnChange={(v) => handlePrefChange('hideBlockedContent', v)}
          />
          <Toggle
            label="不显示视频贴"
            systemImage="video.slash.fill"
            isOn={preferences.blockVideo}
            onIsOnChange={(v) => handlePrefChange('blockVideo', v)}
          />
          <Toggle
            label="过滤广告与直播贴"
            systemImage="cup.and.saucer.fill"
            isOn={preferences.filterAdThreads}
            onIsOnChange={(v) => handlePrefChange('filterAdThreads', v)}
          >
            <Text>关闭后信息流与吧内的广告、直播卡片原样展示</Text>
          </Toggle>
        </Section>

        <Section title="收藏">
          <Toggle
            label="收藏贴子只看楼主"
            systemImage="person.fill"
            isOn={preferences.collectSeeLz}
            onIsOnChange={(v) => handlePrefChange('collectSeeLz', v)}
          />
          <Toggle
            label="收藏贴子倒序查看"
            systemImage="arrow.up.arrow.down"
            isOn={preferences.collectDescSort}
            onIsOnChange={(v) => handlePrefChange('collectDescSort', v)}
          />
        </Section>
      </Form>
    </ThemedHost>
  );
}