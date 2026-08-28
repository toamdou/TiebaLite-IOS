/**
 * 图片与流量设置 — 从「更多设置」拆出（2026-08-27 设置分类整改）：
 * 图片加载策略/水印/暗化/大图清晰度原挤在 more.tsx 的「通用」里，
 * 与更多设置入口语义重叠；独立成页后更多设置只剩启动页/数据/杂项。
 */

import { Form, Section, Toggle, Picker, Text } from '@expo/ui/swift-ui';
import { pickerStyle, tag } from '@expo/ui/swift-ui/modifiers';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { hapticForScene } from '@/theme/hapticsMap';
import { usePreferencesStore } from '@/stores/preferencesStore';
import { useFormTint } from '@/hooks/useFormTint';
import { IMAGE_LOAD_TYPE_LABELS, IMAGE_WATERMARK_LABELS } from '@/constants/settings';
import type { AppPreferences } from '@/types';

export default function ImageSettingsPage() {
  const preferences = usePreferencesStore((s) => s.preferences);
  const setPreference = usePreferencesStore((s) => s.setPreference);
  const formTint = useFormTint();

  return (
    <ThemedHost style={{ flex: 1 }}>
      <Form modifiers={formTint}>
        <Section title="图片加载">
          <Picker
            label="图片加载策略"
            selection={preferences.imageLoadType}
            onSelectionChange={(v: string) =>
              setPreference('imageLoadType', v as AppPreferences['imageLoadType'])
            }
            modifiers={[pickerStyle('menu')]}
          >
            {Object.entries(IMAGE_LOAD_TYPE_LABELS).map(([value, label]) => (
              <Text key={value} modifiers={[tag(value)]}>{label}</Text>
            ))}
          </Picker>
          <Picker
            label="大图清晰度"
            selection={preferences.dataSaverMode}
            onSelectionChange={(v: string) =>
              setPreference('dataSaverMode', v as AppPreferences['dataSaverMode'])
            }
            modifiers={[pickerStyle('menu')]}
          >
            <Text modifiers={[tag('origin')]}>原图（最清晰，费流量）</Text>
            <Text modifiers={[tag('high')]}>高清（默认，省流量）</Text>
            <Text modifiers={[tag('lite')]}>省流（最省流量）</Text>
          </Picker>
        </Section>

        <Section title="图片水印">
          <Picker
            label="水印样式"
            selection={preferences.imageWatermark}
            onSelectionChange={(v: string) =>
              setPreference('imageWatermark', v as AppPreferences['imageWatermark'])
            }
            modifiers={[pickerStyle('menu')]}
          >
            {Object.entries(IMAGE_WATERMARK_LABELS).map(([value, label]) => (
              <Text key={value} modifiers={[tag(value)]}>{label}</Text>
            ))}
          </Picker>
          <Toggle
            label="图片右下角水印"
            systemImage="signature"
            isOn={preferences.imageWatermarkEnabled}
            onIsOnChange={(v) => setPreference('imageWatermarkEnabled', v)}
          />
        </Section>

        <Section title="显示">
          <Toggle
            label="暗色模式下暗化图片"
            systemImage="moon.circle.fill"
            isOn={preferences.imageDarkenWhenNight}
            onIsOnChange={(v) => {
              hapticForScene('toggle');
              setPreference('imageDarkenWhenNight', v);
            }}
          />
        </Section>

        <Section
          title="视频"
          footer={<Text>自动播放：帖内视频滚入视野即静音开播，滚出视野自动收起（滚回重播）；关闭后点按播放。WiFi 档需网络状态模块，暂不提供。</Text>}
        >
          <Toggle
            label="帖内视频自动播放"
            systemImage="play.circle"
            isOn={preferences.videoAutoplay}
            onIsOnChange={(v) => {
              hapticForScene('toggle');
              setPreference('videoAutoplay', v);
            }}
          />
        </Section>
      </Form>
    </ThemedHost>
  );
}