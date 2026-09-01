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
import { DeviceEventEmitter } from 'react-native';
import { useLocalSearchParams, useRouter } from 'expo-router';
import { FieldGroup, ListItem } from '@expo/ui';
import { ThemedHost } from '@/components/ui/ThemedHost';
import { RowIcon } from '@/components/ui/RowIcon';
import { useThemeColors } from '@/theme/ThemeContext';
import { hapticForScene } from '@/theme/hapticsMap';

export default function ThreadMorePage() {
  const { id = '', canDelete = '0', seeLz = '0', reverse = '0' } =
    useLocalSearchParams<{
      id: string;
      canDelete?: string;
      seeLz?: string;
      reverse?: string;
    }>();
  const router = useRouter();
  const { colors } = useThemeColors();

  /** 动作交给 thread 页执行后返回（保持原行为：toggle 生效、JS 状态一致） */
  const emitAndBack = useCallback(
    (action: string, payload?: Record<string, unknown>) => {
      hapticForScene('press');
      DeviceEventEmitter.emit('thread-more-action', { action, threadId: id, ...payload });
      router.back();
    },
    [id, router],
  );

  return (
    // 必须 flex:1（2026-09-01 曾去掉改 style{}，内容塌缩被 sheet 纯色背景
    // 盖住——「列表没有完全显示」。高度由 formSheet detents 决定（见
    // _layout.tsx 的 0.3/0.55/0.9），这里撑满 sheet 视口保证完整可滚。
    // ignoreSafeArea="all" + 宿主背景色：页面与底部区域都铺满页面背景
    //（否则 detent 下端透明露底，2026-09-01 用户实测）。
    // 注意：不能给 FieldGroup 外包 RN View——SwiftUI Form 必须是 Host
    // 直接后代（8-25 实证二级 hosting 空白）。
    <ThemedHost style={{ flex: 1, backgroundColor: colors.background }} ignoreSafeArea="all">
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