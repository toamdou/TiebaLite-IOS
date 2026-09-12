import { useCallback, useState } from 'react';
import { Form, Section, Button, Text, VStack } from '@expo/ui/swift-ui';
import { font, foregroundStyle, frame, padding } from '@expo/ui/swift-ui/modifiers';
import { useFormTint } from '@/hooks/useFormTint';
import { Image } from 'expo-image';
import { hapticForScene } from '@/theme/hapticsMap';
import { APP_VERSION, APP_NAME } from '@/constants/app';
import { openLink } from '@/utils/linkOpener';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { Spacing } from '@/theme';
import { useUpdateStore } from '@/stores/updateStore';
import { UpdateDialog } from '@/components/settings/UpdateDialog';
import { RELEASES_PAGE_URL } from '@/services/update/releaseService';

// 仓库链：本应用（RN 重构）← Kotlin 版（fork）← Kotlin 原版（真正原创）
const REPO_APP = 'https://github.com/toamdou/TiebaLite-RN-Swift';
const REPO_KOTLIN_FORK = 'https://github.com/zzc10086/TiebaLite';
const REPO_KOTLIN_ORIGINAL = 'https://github.com/HuanCheng65/TiebaLite';
const REPO_AIOTIEBA = 'https://github.com/Starry-OvO/aiotieba';
const REPO_TBCLIENT = 'https://github.com/n0099/tbclient.protobuf';

export default function AboutPage() {
  const formTint = useFormTint();
  const openRepo = useCallback((url: string) => {
    hapticForScene('press');
    openLink(url);
  }, []);

  const status = useUpdateStore((s) => s.status);
  const release = useUpdateStore((s) => s.release);
  const hasUpdate = useUpdateStore((s) => s.hasUpdate);
  const currentVersion = useUpdateStore((s) => s.currentVersion);
  const error = useUpdateStore((s) => s.error);
  const check = useUpdateStore((s) => s.check);

  const checking = status === 'checking';
  const [dialogVisible, setDialogVisible] = useState(false);
  // 点「检查更新」= 拉一次最新 Release，然后弹窗展示版本与更新日志；
  // 当前已是最新时，弹窗里显示的就是当前这个版本的日志。
  const handleCheck = useCallback(async () => {
    hapticForScene('press');
    try {
      await check();
    } finally {
      setDialogVisible(true);
    }
  }, [check]);
  // 外部浏览器打开（用户要求：跳转系统浏览器，不走内置 SafariVC）
  const openRelease = useCallback((url: string) => {
    hapticForScene('press');
    openLink(url, false);
  }, []);

  return (
    <ThemedHost style={{ flex: 1 }}>
      <Form modifiers={formTint}>
        <Section>
          {/* 首区块：图标 + 标题 + 版本 居中排版 */}
          <VStack
            alignment="center"
            spacing={Spacing.xs}
            modifiers={[frame({ maxWidth: 9999 }), padding({ vertical: Spacing.lg })]}
          >
            <Image
              source={require('@/assets/images/icon.png')}
              style={{ width: 64, height: 64, borderRadius: 14 }}
              contentFit="cover"
            />
            <Text modifiers={[font({ textStyle: 'title', weight: 'bold' })]}>{APP_NAME}</Text>
            <Text modifiers={[font({ textStyle: 'subheadline' }), foregroundStyle({ type: 'hierarchical', style: 'secondary' })]}>
              Version {APP_VERSION}
            </Text>
          </VStack>
        </Section>

        {/* ── 更新：手动检查最新 Release + 展示更新日志 + 外部浏览器打开 ── */}
        <Section
          title="更新"
          footer={
            <Text>
              更新源为 GitHub 仓库（toamdou/TiebaLite-IOS）的 Releases。可在「设置 → 通用 → 自动检测更新」开启启动时自动检查。
            </Text>
          }
        >
          <Button
            label={checking ? '正在检查…' : '检查更新'}
            systemImage="arrow.triangle.2.circlepath"
            onPress={handleCheck}
          />
          {status === 'done' && release ? (
            <Text modifiers={[font({ textStyle: 'subheadline' })]}>
              {hasUpdate
                ? `发现新版本 v${release.version}（当前 v${currentVersion}）`
                : `已是最新版本（v${currentVersion}）`}
            </Text>
          ) : null}
          {status === 'error' ? (
            <Text modifiers={[font({ textStyle: 'footnote' }), foregroundStyle({ type: 'hierarchical', style: 'secondary' })]}>
              检查失败：{error ?? '网络异常'}
            </Text>
          ) : null}
          {release ? (
            <Button
              label="在浏览器中打开 Release 页面"
              systemImage="safari"
              onPress={() => openRelease(release.url || RELEASES_PAGE_URL)}
            />
          ) : null}
        </Section>

        {/* 仓库与致谢：应用链 + 协议对照参考（aiotieba） */}
        <Section
          title="仓库与致谢"
          footer={
            <Text>
              本应用为 React Native 重构版；Kotlin 版（zzc10086/TiebaLite）fork 自 Kotlin 原版（HuanCheng65/TiebaLite），API 协议与交互均以其为参照；协议字段定义参考 aiotieba 项目与 n0099/tbclient.protobuf（贴吧客户端 protobuf 定义合集）。
            </Text>
          }
        >
          <Button
            label="本应用 · toamdou/TiebaLite-RN-Swift"
            systemImage="iphone"
            onPress={() => openRepo(REPO_APP)}
          />
          <Button
            label="Kotlin 版 · zzc10086/TiebaLite"
            systemImage="arrow.triangle.branch"
            onPress={() => openRepo(REPO_KOTLIN_FORK)}
          />
          <Button
            label="Kotlin 原版 · HuanCheng65/TiebaLite"
            systemImage="crown.fill"
            onPress={() => openRepo(REPO_KOTLIN_ORIGINAL)}
          />
          <Button
            label="aiotieba · Starry-OvO/aiotieba"
            systemImage="network"
            onPress={() => openRepo(REPO_AIOTIEBA)}
          />
          <Button
            label="tbclient.protobuf · n0099"
            systemImage="curlybraces"
            onPress={() => openRepo(REPO_TBCLIENT)}
          />
        </Section>
      </Form>
      {/* 更新结果弹窗（最新版号 + 更新日志 + 浏览器打开） */}
      <UpdateDialog visible={dialogVisible} onClose={() => setDialogVisible(false)} />
    </ThemedHost>
  );
}
