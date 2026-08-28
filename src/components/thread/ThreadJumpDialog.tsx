/**
 * Thread Jump Dialog（帖子详情页「跳页」弹窗）— RN Modal + TextInput。
 * 拆自 src/app/thread/[id].tsx（4 抽 1 留拆分，#8）。
 *
 * ⚠️ 实码说明：原 SwiftUI Alert+TextField 挂在嵌套 matchContents 宿主上，
 * present 失败直接白屏（8-25 真机）；RN Modal 无 SwiftUI 层、不影响顶栏
 * 玻璃链路 —— 故保留 RN Modal 实现（扫描报告写的"SWAlert+TextField"已废弃，
 * 以实码为准）。
 */

import { useEffect, useState } from 'react';
import { Alert, Modal, StyleSheet, TextInput, View } from 'react-native';
import { Text } from '../ui/CompatText';

import {Shadows, RadiusStyle} from '@/theme';
import { useThemeColors } from '@/theme/ThemeContext';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { hapticForScene } from '@/theme/hapticsMap';

export interface ThreadJumpDialogProps {
  visible: boolean;
  /** 当前展示页（用于预填 + 同页直接关闭） */
  currentPage: number;
  /** 总页数（0 = 未知，不限制上限） */
  totalPages: number;
  onClose: () => void;
  /** 页码校验通过后回调（父组件负责 load + 滚动 + 失败 toast） */
  onJump: (page: number) => Promise<void>;
}

export function ThreadJumpDialog({
  visible,
  currentPage,
  totalPages,
  onClose,
  onJump,
}: ThreadJumpDialogProps) {
  const { colors } = useThemeColors();
  const [jumpText, setJumpText] = useState('');

  // 每次打开预填当前页
  useEffect(() => {
    if (visible) setJumpText(String(currentPage));
  }, [visible, currentPage]);

  const handleConfirm = async () => {
    const pageNum = parseInt(jumpText.trim(), 10);
    if (!Number.isFinite(pageNum) || pageNum < 1 || (totalPages > 0 && pageNum > totalPages)) {
      Alert.alert('提示', totalPages > 0 ? `请输入 1-${totalPages} 之间的页码` : '请输入有效的页码');
      return;
    }
    if (pageNum === currentPage) {
      onClose();
      return;
    }
    onClose();
    try {
      await onJump(pageNum);
    } catch (e) {
      if (__DEV__) console.warn('[ThreadJumpDialog] jump ERR page=', pageNum, e);
    }
  };

  return (
    <Modal
      transparent
      visible={visible}
      animationType="fade"
      onRequestClose={onClose}
    >
      <View style={styles.jumpOverlay}>
        <View style={[styles.jumpCard, { backgroundColor: colors.card }]}>
          <Text style={[styles.jumpTitle, { color: colors.text }]}>跳转页面</Text>
          <TextInput
            style={[styles.jumpInput, { backgroundColor: colors.surfaceSecondary, color: colors.text }]}
            placeholder={`1-${totalPages > 0 ? totalPages : '?'}`}
            placeholderTextColor={colors.textTertiary}
            keyboardType="number-pad"
            value={jumpText}
            onChangeText={setJumpText}
            autoFocus
          />
          <View style={styles.jumpActions}>
            <HdrPressable
              onPress={() => {
                void hapticForScene('press');
                onClose();
              }}
              style={({ pressed }) => [styles.jumpBtn, { opacity: pressed ? 0.6 : 1 }]}
            >
              <Text style={[styles.jumpBtnText, { color: colors.textSecondary }]}>取消</Text>
            </HdrPressable>
            <HdrPressable
              onPress={() => {
                void hapticForScene('press');
                void handleConfirm();
              }}
              style={({ pressed }) => [styles.jumpBtn, { opacity: pressed ? 0.6 : 1 }]}
            >
              <Text style={[styles.jumpBtnText, { color: colors.primary, fontWeight: '600' }]}>跳转</Text>
            </HdrPressable>
          </View>
        </View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  jumpOverlay: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(0,0,0,0.4)',
  },
  jumpCard: {
    width: 280,
    ...RadiusStyle.card,
    padding: 20,
    gap: 14,
    ...Shadows.card,
  },
  jumpTitle: {
    fontSize: 17,
    fontWeight: '600',
  },
  jumpInput: {
    height: 44,
    ...RadiusStyle.input,
    paddingHorizontal: 12,
    fontSize: 17,
  },
  jumpActions: {
    flexDirection: 'row',
    justifyContent: 'flex-end',
    gap: 8,
  },
  jumpBtn: {
    paddingHorizontal: 16,
    paddingVertical: 8,
  },
  jumpBtnText: {
    fontSize: 17,
  },
});