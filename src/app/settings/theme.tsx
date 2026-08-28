import { useCallback } from 'react';
import { useColorScheme } from 'react-native';
import { Form, Section, Toggle, Text, Picker, ProgressView, ColorPicker } from '@expo/ui/swift-ui';
import { pickerStyle, progressViewStyle, tag, tint } from '@expo/ui/swift-ui/modifiers';
import { hapticForScene } from '@/theme/hapticsMap';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { usePreferencesStore } from '@/stores/preferencesStore';
import { useThemeColors } from '@/theme/ThemeContext';
import { useFormTint } from '@/hooks/useFormTint';
import { FONT_SCALE_OPTIONS } from '@/constants/settings';
import { LIGHT_THEME_OPTIONS, DARK_THEME_OPTIONS } from '@/constants/app';
import { DEFAULT_CUSTOM_PRIMARY } from '@/theme/colors';

/** menu 样式 Picker 修饰符（模块级常量，避免每渲染新建） */
const pickerStyleMenu = pickerStyle('menu');

export default function DisplaySettingsPage() {
  const hydrated = usePreferencesStore((s) => s.hasHydrated);
  // 未水合时返回轻量占位，避免整页白屏闪烁
  if (!hydrated) return <DisplayHydratedPlaceholder />;
  return <DisplaySettingsForm />;
}

/** 偏好水合完成前的轻量加载占位 */
function DisplayHydratedPlaceholder() {
  const { colors } = useThemeColors();
  return (
    <ThemedHost style={{ flex: 1, alignItems: 'center', justifyContent: 'center' }}>
      <ProgressView modifiers={[progressViewStyle('circular'), tint(colors.primary)]} />
    </ThemedHost>
  );
}

/** 十六进制主色校验：#RGB / #RRGGBB / #RRGGBBAA（取 RGB 六位），返回大写规范形式或 null */
function normalizeHexInput(raw: string): string | null {
  const v = raw.trim().replace(/^#?/, '#');
  if (/^#[0-9a-fA-F]{8}$/.test(v)) return v.slice(0, 7).toUpperCase();
  if (/^#[0-9a-fA-F]{6}$/.test(v)) return v.toUpperCase();
  if (/^#[0-9a-fA-F]{3}$/.test(v)) {
    return ('#' + v.slice(1).split('').map((c) => c + c).join('')).toUpperCase();
  }
  return null;
}

function DisplaySettingsForm() {
  const preferences = usePreferencesStore((s) => s.preferences);
  const setPreference = usePreferencesStore((s) => s.setPreference);
  const formTint = useFormTint();
  const systemIsDark = useColorScheme() === 'dark';

  const handleFollowSystemChange = useCallback((v: boolean) => {
    hapticForScene('toggle');
    setPreference('followSystemDarkMode', v);
    // 关闭"跟随系统"时，立即以当前系统外观作为手动模式的初值，
    // 避免用户一关掉跟随就白屏/黑屏跳变。
    if (!v) {
      setPreference('darkMode', systemIsDark);
    }
  }, [setPreference, systemIsDark]);

  // 常驻「深色模式」开关：跟随系统时显示当前系统外观（系统变深即同步为开）；
  // 手动开启则退出跟随系统，进入手动模式。
  const effectiveDark = preferences.followSystemDarkMode
    ? systemIsDark
    : preferences.darkMode;

  const handleDarkModeChange = useCallback((v: boolean) => {
    hapticForScene('toggle');
    setPreference('darkMode', v);
    if (preferences.followSystemDarkMode) {
      setPreference('followSystemDarkMode', false);
    }
  }, [preferences.followSystemDarkMode, setPreference]);

  const handleFontScaleChange = useCallback((v: string | number | null) => {
    hapticForScene('toggle');
    const scale = parseFloat(String(v));
    if (!Number.isNaN(scale)) setPreference('fontScale', scale);
  }, [setPreference]);

  // ── 主题选择（lightTheme/darkTheme/customPrimaryColor 引擎全通，2026-08-28 暴露）──
  // 本地白名单清洗兜底：非法值回落默认主题，保证 Picker selection 恒为现有 tag
  //（expo-ui Picker 遇未知 selection 直接崩，见 haptics.tsx 2026-08-27 真机案例）
  const safeTheme = (raw: string, allowed: readonly string[], fallback: string) =>
    allowed.includes(raw) ? raw : fallback;
  const safeLightTheme = safeTheme(
    preferences.lightTheme,
    LIGHT_THEME_OPTIONS.map((t) => t.key),
    'default',
  );
  const safeDarkTheme = safeTheme(
    preferences.darkTheme,
    DARK_THEME_OPTIONS.map((t) => t.key),
    'default',
  );

  const handleLightThemeChange = useCallback((v: string) => {
    hapticForScene('toggle');
    setPreference('lightTheme', v as typeof preferences.lightTheme);
  }, [setPreference]);

  const handleDarkThemeChange = useCallback((v: string) => {
    hapticForScene('toggle');
    setPreference('darkTheme', v as typeof preferences.darkTheme);
  }, [setPreference]);

  // 自定义主色：仅任一端选了「自定义」主题时出现
  const isCustomTheme = safeLightTheme === 'custom' || safeDarkTheme === 'custom';

  return (
    <ThemedHost style={{ flex: 1 }}>
      <Form modifiers={formTint}>
        <Section
          title="主题"
          footer={<Text>「默认」= 初始内置配色，设置页行图标保持五颜六色；选任一具体主题后图标与强调色统一跟随主色。分组卡片、底栏与顶栏使用系统材质，不随主题变化。深色端可选「纯黑」（AMOLED）。</Text>}
        >
          <Picker
            label="浅色主题"
            selection={safeLightTheme}
            onSelectionChange={handleLightThemeChange}
            modifiers={[pickerStyleMenu]}
          >
            {LIGHT_THEME_OPTIONS.map((t) => (
              <Text key={t.key} modifiers={[tag(t.key)]}>{t.label}</Text>
            ))}
          </Picker>
          <Picker
            label="深色主题"
            selection={safeDarkTheme}
            onSelectionChange={handleDarkThemeChange}
            modifiers={[pickerStyleMenu]}
          >
            {DARK_THEME_OPTIONS.map((t) => (
              <Text key={t.key} modifiers={[tag(t.key)]}>{t.label}</Text>
            ))}
          </Picker>
          {isCustomTheme && <CustomPrimaryColorRow value={preferences.customPrimaryColor} />}
        </Section>

        <Section
          title="外观"
          footer={<Text>「深色模式」在跟随系统时随系统自动同步；手动切换后即退出跟随。</Text>}
        >
          <Toggle
            label="深色模式"
            systemImage="moon.fill"
            isOn={effectiveDark}
            onIsOnChange={handleDarkModeChange}
          >
            <Text>黑底白字；系统变深色时自动跟随开启</Text>
          </Toggle>
          <Toggle
            label="跟随系统外观"
            systemImage="iphone"
            isOn={preferences.followSystemDarkMode}
            onIsOnChange={handleFollowSystemChange}
          >
            <Text>界面颜色自动跟随系统浅色 / 深色设置</Text>
          </Toggle>
        </Section>

        <Section
          title="阅读字号"
          footer={<Text>调整帖子正文与回复的字号，即时生效。</Text>}
        >
          <Picker
            label="正文字号"
            systemImage="textformat.size"
            selection={String(preferences.fontScale)}
            onSelectionChange={handleFontScaleChange}
          >
            {FONT_SCALE_OPTIONS.map((opt) => (
              <Text key={opt.value} modifiers={[tag(opt.value)]}>
                {opt.label}
              </Text>
            ))}
          </Picker>
        </Section>

        <Section
          title="动效"
          footer={<Text>入场动画：信息流与帖内首屏的级联渐入。按压缩放：列表行与卡片的按压回弹。系统「减弱动态效果」开启时两者自动停用。</Text>}
        >
          <Toggle
            label="入场动画"
            systemImage="sparkles"
            isOn={preferences.entranceAnimation}
            onIsOnChange={(v) => { hapticForScene('toggle'); setPreference('entranceAnimation', v); }}
          />
          <Toggle
            label="按压缩放效果"
            systemImage="arrow.down.right.and.arrow.up.left"
            isOn={preferences.pressScaleEffect}
            onIsOnChange={(v) => { hapticForScene('toggle'); setPreference('pressScaleEffect', v); }}
          />
        </Section>

        <Section title="工具栏选项">
          {/* 该开关实际只影响导航栏前景（标题/返回箭头）与状态栏样式，
              不改变工具栏背景色，故文案按实际作用命名以避免误导 */}
          <Toggle
            label="导航栏使用主色调"
            systemImage="paintpalette.fill"
            isOn={preferences.toolbarPrimaryColor}
            onIsOnChange={(v) => { hapticForScene('toggle'); setPreference('toolbarPrimaryColor', v); }}
          >
            <Text>将导航栏标题与图标着色为主色调，并联动状态栏样式</Text>
          </Toggle>
          {preferences.toolbarPrimaryColor && (
            <Toggle
              label="状态栏深色字体"
              systemImage="textformat"
              isOn={preferences.statusBarFontDark}
              onIsOnChange={(v) => { hapticForScene('toggle'); setPreference('statusBarFontDark', v); }}
            />
          )}
        </Section>
      </Form>
    </ThemedHost>
  );
}

/**
 * 自定义主色行：expo-ui ColorPicker（SwiftUI 原生取色器）。
 * supportsOpacity=false → 回调恒为 #RRGGBB；拖动即落库，getThemeColors
 * 消费侧 normalizeHex 兜底，坏值静默回落默认主色。
 */
function CustomPrimaryColorRow({ value }: { value: string }) {
  const setPreference = usePreferencesStore((s) => s.setPreference);

  const handleColorChange = useCallback((v: string) => {
    const normalized = normalizeHexInput(v);
    if (!normalized) return;
    setPreference('customPrimaryColor', normalized);
  }, [setPreference]);

  return (
    <ColorPicker
      label="自定义主色"
      selection={value || DEFAULT_CUSTOM_PRIMARY}
      supportsOpacity={false}
      onSelectionChange={handleColorChange}
    />
  );
}
