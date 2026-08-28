import { Stack, useRouter } from 'expo-router';
import {
  Button,
  ContentUnavailableView,
  Label,
  Spacer,
  VStack,
} from '@expo/ui/swift-ui';
import { buttonBorderShape, buttonStyle } from '@expo/ui/swift-ui/modifiers';

import { ThemedHost } from '@/components/ui/ThemedHost';
import { useThemeColors } from '@/theme/ThemeContext';
import { Spacing } from '@/theme';

/**
 * Catch-all 404 page — renders when no other route matches the URL.
 * Mirrors React Navigation's `path: '*'` wildcard linking config.
 */
export default function NotFoundScreen() {
  const router = useRouter();
  const { colors } = useThemeColors();

  return (
    <ThemedHost style={{ flex: 1 }}>
      <Stack.Screen options={{ title: '找不到页面', headerStyle: { backgroundColor: colors.toolbar } }} />

      <VStack alignment="center" spacing={Spacing.lg}>
        <Spacer />
        <ContentUnavailableView
          systemImage="questionmark.folder"
          title="页面不存在"
          description="你访问的链接可能已失效或不存在"
        />
        <Button
          onPress={() => router.replace('/')}
          modifiers={[buttonStyle('glassProminent'), buttonBorderShape('capsule')]}
        >
          <Label title="返回首页" systemImage="house" />
        </Button>
        <Spacer />
      </VStack>
    </ThemedHost>
  );
}
