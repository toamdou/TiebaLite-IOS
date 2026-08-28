/**
 * Thread More Menu — formSheet 呈现的「更多」页面。
 *
 * 全部 ExpoUI（与「我的」板块同构）：页面级 ThemedHost + FieldGroup.Section
 * + ListItem（原生 SwiftUI Form 分组列表）。不用 expo-ui BottomSheet——
 * 其 children 固定在 RNHostView（RN surface），SwiftUI 组件放进去是二级
 * _UIHostingView，8-25 实测整片空白。formSheet 是 iOS 原生底部 sheet 呈现
 * （圆角 + 系统毛玻璃 + 原生拖拽关闭），页面内容则在页面级 Host 下正常
 * 渲染、可点。
 *
 * 动作统一回 thread 页执行（DeviceEventEmitter 'thread-more-action'，
 * 行为与旧 BottomSheet 版本一致，逻辑零复制）。
 */

import { useCallback } from 'react';
import { Alert } from 'react-native';
import { DeviceEventEmitter } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { FieldGroup, ListItem } from '@expo/ui';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { RowIcon } from '@/components/ui/RowIcon';
import { useAuthStore } from '@/stores/authStore';
import { hapticForScene } from '@/theme/hapticsMap';

export default function ThreadMorePage() {
  const { id = '', canDelete = '0', seeLz = '0', isCollected = '0', reverse = '0' } =
    useLocalSearchParams<{
      id: string;
      canDelete?: string;
      seeLz?: string;
      isCollected?: string;
      reverse?: string;
    }>();
  const router = useRouter();
  const isLoggedIn = useAuthStore((s) => s.isLoggedIn);

  /** 动作交给 thread 页执行后返回（保持原行为：toggle 生效、JS 状态一致） */
  const emitAndBack = useCallback(
    (action: string, payload?: Record<string, unknown>) => {
      hapticForScene('press');
      DeviceEventEmitter.emit('thread-more-action', { action, threadId: id, ...payload });
      router.back();
    },
    [id, router],
  );

  const handleCollect = useCallback(() => {
    hapticForScene('press');
    if (!isLoggedIn) {
      Alert.alert('提示', '请先登录');
      return;
    }
    emitAndBack('collect');
  }, [emitAndBack, isLoggedIn]);

  return (
    <ThemedHost style={{ flex: 1 }} ignoreSafeArea="container">
      {/* FieldGroup（SwiftUI Form）必须是页面级 Host 直接后代：可点、可渲染 */}
      <FieldGroup>
        <FieldGroup.Section title="浏览">
          <ListItem
            leading={<RowIcon icon={seeLz === '1' ? 'person.fill' : 'person'} tint="#5856D6" />}
            onPress={() => emitAndBack('seeLz')}
          >
            {seeLz === '1' ? '只看楼主（开启）' : '只看楼主'}
          </ListItem>
          <ListItem
            leading={<RowIcon icon={isCollected === '1' ? 'star.fill' : 'star'} tint="#FFCC00" />}
            onPress={handleCollect}
          >
            {isCollected === '1' ? '已收藏' : '收藏'}
          </ListItem>
          <ListItem
            leading={<RowIcon icon="arrow.up.arrow.down" tint="#AF52DE" />}
            onPress={() => emitAndBack('sort')}
          >
            {reverse === '1' ? '按正序浏览' : '按倒序浏览'}
          </ListItem>
          <ListItem
            leading={<RowIcon icon="arrow.right.to.line" tint="#5856D6" />}
            onPress={() => emitAndBack('jump')}
          >
            跳转页码
          </ListItem>
        </FieldGroup.Section>

        <FieldGroup.Section title="操作">
          <ListItem
            leading={<RowIcon icon="square.and.arrow.up" tint="#0A84FF" />}
            onPress={() => emitAndBack('share')}
          >
            分享
          </ListItem>
          <ListItem
            leading={<RowIcon icon="link" tint="#0A84FF" />}
            onPress={() => emitAndBack('copy')}
          >
            复制链接
          </ListItem>
          <ListItem
            leading={<RowIcon icon="exclamationmark.triangle" tint="#FF9500" />}
            onPress={() => emitAndBack('report')}
          >
            举报
          </ListItem>
          {canDelete === '1' && (
            <ListItem
              leading={<RowIcon icon="trash" tint="#FF3B30" />}
              onPress={() => emitAndBack('delete')}
            >
              删除
            </ListItem>
          )}
        </FieldGroup.Section>
      </FieldGroup>
    </ThemedHost>
  );
}