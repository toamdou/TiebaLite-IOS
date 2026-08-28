import { useCallback } from 'react';
import { Form, Section, Button, Text, VStack } from '@expo/ui/swift-ui';
import { font, foregroundStyle, frame, padding } from '@expo/ui/swift-ui/modifiers';
import { useFormTint } from '@/hooks/useFormTint';
import { Image } from 'expo-image';
import { hapticForScene } from '@/theme/hapticsMap';
import { APP_VERSION, APP_NAME } from '@/constants/app';
import { openLink } from '@/utils/linkOpener';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { Spacing } from '@/theme';

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
    </ThemedHost>
  );
}
