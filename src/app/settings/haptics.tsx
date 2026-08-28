/**
 * 振动设置页 — 每场景独立选择振动风格（@expo/ui Form 原生实现，habit 同范式）
 *
 * 数据流：偏好 hapticsSceneStyles（JSON 字符串）→ hapticsMap.resolveHapticEntry
 * 消费侧解析。本页只读写该键；每次改动立即回放该场景触觉，所选即所得。
 *
 * ⚠️ 与 habit.tsx 相同的坑位约束：逐行不要包 ThemedHost（Form 会把 Host 行居中）。
 */

import { Fragment, useCallback } from 'react';
import { Form, Section, Button, Text, Picker, ProgressView } from '@expo/ui/swift-ui';
import { pickerStyle, progressViewStyle, tag, tint } from '@expo/ui/swift-ui/modifiers';
import { ThemedHost } from '@/components/ui/ThemedHost';
import {
  hapticForScene,
  HAPTIC_SCENE_META,
  WAVEFORM_CHOICES,
  type HapticStyleChoice,
  type HapticWaveformChoice,
} from '@/theme/hapticsMap';
import {
  REALTIME_EFFECT_META,
  type RealtimeLevel,
} from '@/theme/hapticsRealtime';
import { usePreferencesStore } from '@/stores/preferencesStore';
import { useFormTint } from '@/hooks/useFormTint';
import { useThemeColors } from '@/theme/ThemeContext';

/** 全场景统一可选档：跟随默认 / 关闭 / 三档整体浓淡（缩放模式内全部事件强度） */
const SCENE_CHOICES: { value: HapticStyleChoice; label: string }[] = [
  { value: 'default', label: '跟随默认' },
  { value: 'off', label: '关闭' },
  { value: 'light', label: '轻' },
  { value: 'medium', label: '中' },
  { value: 'heavy', label: '强' },
];

/** 实时触觉可选档：关闭 / 三档强度（缺省=适中开） */
const REALTIME_CHOICES: { value: RealtimeLevel; label: string }[] = [
  { value: 'off', label: '关闭' },
  { value: 'light', label: '轻' },
  { value: 'medium', label: '适中' },
  { value: 'strong', label: '强' },
];

export default function HapticsSettingsPage() {
  const { colors } = useThemeColors();
  const formTint = useFormTint();
  const hasHydrated = usePreferencesStore((s) => s.hasHydrated);
  const sceneStylesRaw = usePreferencesStore((s) => s.preferences.hapticsSceneStyles);
  const realtimeStylesRaw = usePreferencesStore((s) => s.preferences.hapticsRealtimeStyles);
  const waveformsRaw = usePreferencesStore((s) => s.preferences.hapticsWaveforms);
  const setPreference = usePreferencesStore((s) => s.setPreference);

  // 存储不可信：解析失败按空覆盖渲染（与消费侧 resolveHapticEntry 同一宽容度）
  let overrides: Partial<Record<string, string>> = {};
  try {
    const parsed: unknown = JSON.parse(sceneStylesRaw || '{}');
    if (parsed && typeof parsed === 'object') overrides = parsed as typeof overrides;
  } catch {}

  let waveformOverrides: Partial<Record<string, string>> = {};
  try {
    const parsed: unknown = JSON.parse(waveformsRaw || '{}');
    if (parsed && typeof parsed === 'object') waveformOverrides = parsed as typeof overrides;
  } catch {}

  let realtimeOverrides: Partial<Record<string, string>> = {};
  try {
    const parsed: unknown = JSON.parse(realtimeStylesRaw || '{}');
    if (parsed && typeof parsed === 'object') realtimeOverrides = parsed as typeof realtimeOverrides;
  } catch {}

  /** 写入单个实时效果档位（缺省=适中，显式存储便于用户看到当前值） */
  const handleRealtimeChoice = useCallback(
    (id: string, level: RealtimeLevel) => {
      // 写入侧同款清洗：非档位表值不落库（与渲染侧 safeChoice 同表校验，
      // 保证偏好表永远不产生原生 Picker 不认识的 tag）
      if (!REALTIME_CHOICES.some((c) => c.value === level)) return;
      let next: Record<string, string>;
      try {
        next = JSON.parse(realtimeStylesRaw || '{}');
        if (!next || typeof next !== 'object') next = {};
      } catch {
        next = {};
      }
      next[id] = level;
      setPreference('hapticsRealtimeStyles', JSON.stringify(next));
    },
    [realtimeStylesRaw, setPreference],
  );

  /** 写入单个场景的选择并立即回放（所选即所得） */
  const handleChoice = useCallback(
    (scene: (typeof HAPTIC_SCENE_META)[number]['scene'], choice: HapticStyleChoice) => {
      // 写入侧同款清洗：非法档位不落库（渲染侧 safeChoice 同表校验）
      if (!SCENE_CHOICES.some((c) => c.value === choice)) return;
      let next: Record<string, string>;
      try {
        next = JSON.parse(sceneStylesRaw || '{}');
        if (!next || typeof next !== 'object') next = {};
      } catch {
        next = {};
      }
      if (choice === 'default') {
        delete next[scene]; // 缺省即内置规范，表保持最小
      } else {
        next[scene] = choice;
      }
      setPreference('hapticsSceneStyles', JSON.stringify(next));
      // 回放用同一生效链：全局开关与该场景静音都会被正确处理
      void hapticForScene(scene);
    },
    [sceneStylesRaw, setPreference],
  );

  /** 写入单个场景的波形选择并立即回放（与力度正交：先取波形再按力度缩放） */
  const handleWaveform = useCallback(
    (scene: (typeof HAPTIC_SCENE_META)[number]['scene'], choice: HapticWaveformChoice) => {
      // 写入侧同款清洗：非法波形不落库（渲染侧 safeChoice 同表校验）
      if (!WAVEFORM_CHOICES.some((c) => c.value === choice)) return;
      let next: Record<string, string>;
      try {
        next = JSON.parse(waveformsRaw || '{}');
        if (!next || typeof next !== 'object') next = {};
      } catch {
        next = {};
      }
      if (choice === 'default') {
        delete next[scene]; // 缺省即内置波形，表保持最小
      } else {
        next[scene] = choice;
      }
      setPreference('hapticsWaveforms', JSON.stringify(next));
      void hapticForScene(scene);
    },
    [waveformsRaw, setPreference],
  );

  const handleResetAll = useCallback(() => {
    setPreference('hapticsSceneStyles', '{}');
    setPreference('hapticsRealtimeStyles', '{}');
    setPreference('hapticsWaveforms', '{}');
    void hapticForScene('press');
  }, [setPreference]);

  if (!hasHydrated) {
    return (
      <ThemedHost style={{ flex: 1, alignItems: 'center', justifyContent: 'center' }}>
        <ProgressView modifiers={[progressViewStyle('circular'), tint(colors.primary)]} />
      </ThemedHost>
    );
  }

  const actionScenes = HAPTIC_SCENE_META.filter((m) => m.group === 'action');
  const signalScenes = HAPTIC_SCENE_META.filter((m) => m.group === 'signal');

  // 存储不可信：selection 必须是 Picker 现有 tag 之一，否则 expo-ui 原生
  // Picker 渲染直接崩（2026-08-27 真机：进振动设置页即崩，空 error 消息、
  // 栈在 renderPicker）。深色模式本身不参与取值——切换主题只是触发整页
  // 重渲染，把旧版本存过的值（如 'strong'）逐一带到原生 Picker 面前才崩。
  // 这里统一清洗（SCENE/WAVEFORM/REALTIME 三表校验，非法回落 default；
  // 写入侧 handleChoice/handleWaveform/handleRealtimeChoice 已同步拦截，
  // 偏好表不再产生新脏值，本清洗兜底历史遗留数据）。
  const safeChoice = (
    raw: string | undefined,
    choices: readonly { value: string }[],
    fallback = 'default',
  ): string => (choices.some((c) => c.value === raw) ? (raw as string) : fallback);

  const renderPicker = (meta: (typeof HAPTIC_SCENE_META)[number]) => {
    const current = safeChoice(overrides[meta.scene], SCENE_CHOICES);
    const currentWaveform = safeChoice(waveformOverrides[meta.scene], WAVEFORM_CHOICES);
    // map 产物必须以带 key 的元素/Fragment 进入列表（否则 expo-ui SlotView
    // 报 "Each child in a list should have a unique key"）：力度+波形两行
    // 打包在同一个具 key Fragment 里。
    return (
      <Fragment key={meta.scene}>
        <Picker
          label={`${meta.label} · 力度`}
          selection={current}
          onSelectionChange={(v: string) => handleChoice(meta.scene, v as HapticStyleChoice)}
          modifiers={[pickerStyle('menu')]}
        >
          {SCENE_CHOICES.map((c) => (
            <Text key={c.value} modifiers={[tag(c.value)]}>
              {c.label}
            </Text>
          ))}
        </Picker>
        <Picker
          label={`${meta.label} · 波形`}
          selection={currentWaveform}
          onSelectionChange={(v: string) => handleWaveform(meta.scene, v as HapticWaveformChoice)}
          modifiers={[pickerStyle('menu')]}
        >
          {WAVEFORM_CHOICES.map((c) => (
            <Text key={c.value} modifiers={[tag(c.value)]}>
              {c.label}
            </Text>
          ))}
        </Picker>
      </Fragment>
    );
  };

  return (
    <ThemedHost style={{ flex: 1 }}>
      <Form modifiers={formTint}>
        <Section
          title="操作反馈"
          footer={<Text>力度：「跟随默认」使用应用内置 AHAP 模式；轻/中/强为整体浓淡缩放。波形：改变触觉节奏（内置/单次/双脉冲/渐强三连/轻柔），与力度叠加生效。选择后立即回放一次以便试听。</Text>}
        >
          {actionScenes.map(renderPicker)}
        </Section>

        <Section title="切换与结果通知">
          {signalScenes.map(renderPicker)}
        </Section>

        <Section
          title="实时触觉（手势跟随）"
          footer={<Text>跟随手指连续变化：大图下滑关闭的剥离感、横滑退出边缘的抵抗感、点赞按住的蓄力。只在对应手势进行时生效；信息流滚动等高频场景刻意未加入。</Text>}
        >
          {REALTIME_EFFECT_META.map((meta) => {
            const current = safeChoice(realtimeOverrides[meta.id], REALTIME_CHOICES, 'medium') as RealtimeLevel;
            return (
              <Picker
                key={meta.id}
                label={meta.label}
                selection={current}
                onSelectionChange={(v: string) => handleRealtimeChoice(meta.id, v as RealtimeLevel)}
                modifiers={[pickerStyle('menu')]}
              >
                {REALTIME_CHOICES.map((c) => (
                  <Text key={c.value} modifiers={[tag(c.value)]}>
                    {c.label}
                  </Text>
                ))}
              </Picker>
            );
          })}
        </Section>

        <Section footer={<Text>恢复默认会清除所有场景的自定义覆盖（不影响总开关「振动反馈」）。</Text>}>
          <Button label="恢复默认" systemImage="arrow.counterclockwise" onPress={handleResetAll} />
        </Section>
      </Form>
    </ThemedHost>
  );
}
