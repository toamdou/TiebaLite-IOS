/**
 * UpdateDialog — 「检查更新」结果弹窗（关于页触发）。
 *
 * 显示：最新版本号 + 发布说明（日志）；当前已是最新时显示的就是当前版本的日志。
 * 按钮：在浏览器中打开 Release 页面（外部浏览器，走 linkOpener 的 external 分支）、关闭。
 *
 * 实现说明：RN Modal（与 ThreadJumpDialog 同款）——SwiftUI 宿主/Alert 在嵌套
 * matchContents 下 present 会白屏（8-25 真机结论），RN 层无此问题且不影响顶栏。
 */

import { useCallback, useMemo } from 'react';
import { Modal, ScrollView, StyleSheet, View } from 'react-native';
import { Text } from '../ui/CompatText';

import { RadiusStyle, Shadows } from '@/theme';
import { useThemeColors } from '@/theme/ThemeContext';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { hapticForScene } from '@/theme/hapticsMap';
import { openLink } from '@/utils/linkOpener';
import { useUpdateStore } from '@/stores/updateStore';

export interface UpdateDialogProps {
  visible: boolean;
  onClose: () => void;
}

/** markdown 轻量清洗：弹窗按纯文本展示，去掉标题井号与强调符号 */
function lightenMarkdown(md: string): string {
  return md
    .replace(/^#{1,6}\s*/gm, '')
    .replace(/\*\*(.+?)\*\*/g, '$1')
    .replace(/__(.+?)__/g, '$1')
    .replace(/`{1,3}([^`]+)`{1,3}/g, '$1')
    .replace(/^\s*[-*+]\s+/gm, '· ')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/** 2026-09-01T14:13:52Z → 2026-09-01 */
function formatDate(iso: string | null): string {
  if (!iso) return '';
  const m = iso.match(/^(\d{4})-(\d{2})-(\d{2})/);
  return m ? `${m[1]}-${m[2]}-${m[3]}` : '';
}

export function UpdateDialog({ visible, onClose }: UpdateDialogProps) {
  const { colors } = useThemeColors();
  const status = useUpdateStore((s) => s.status);
  const release = useUpdateStore((s) => s.release);
  const hasUpdate = useUpdateStore((s) => s.hasUpdate);
  const currentVersion = useUpdateStore((s) => s.currentVersion);
  const error = useUpdateStore((s) => s.error);

  const notes = useMemo(() => (release?.notes ? lightenMarkdown(release.notes) : ''), [release?.notes]);
  const title = useMemo(() => {
    if (status === 'checking') return '正在检查更新…';
    if (status === 'error') return '检查更新失败';
    if (!release) return '检查更新';
    return hasUpdate ? `发现新版本 v${release.version}` : `已是最新版本 v${currentVersion}`;
  }, [status, release, hasUpdate, currentVersion]);

  const handleOpenRelease = useCallback(() => {
    hapticForScene('press');
    if (release?.url) openLink(release.url, false);
  }, [release?.url]);

  return (
    <Modal visible={visible} transparent animationType="fade" onRequestClose={onClose}>
      <View style={styles.backdrop}>
        <View style={[styles.card, { backgroundColor: colors.card }, Shadows.floating]}>
          <Text style={[styles.title, { color: colors.text }]}>{title}</Text>

          {status === 'done' && release ? (
            <Text style={[styles.meta, { color: colors.textSecondary }]}>
              {`${hasUpdate ? `最新 v${release.version}` : `当前 v${currentVersion}`}${
                formatDate(release.publishedAt) ? ` · 发布于 ${formatDate(release.publishedAt)}` : ''
              }`}
            </Text>
          ) : null}

          {status === 'error' ? (
            <Text style={[styles.meta, { color: colors.textSecondary }]}>
              {error ?? '网络异常，请稍后重试'}
            </Text>
          ) : null}

          {status === 'done' && notes ? (
            <ScrollView style={styles.notesScroll} contentContainerStyle={styles.notesContent}>
              <Text style={[styles.notes, { color: colors.textSecondary }]}>{notes}</Text>
            </ScrollView>
          ) : null}

          <View style={styles.actions}>
            {status === 'done' && release ? (
              <HdrPressable
                effect="subtle"
                onPress={handleOpenRelease}
                style={[styles.button, { backgroundColor: colors.primary }]}
              >
                <Text style={[styles.buttonText, { color: '#FFF' }]}>在浏览器中打开</Text>
              </HdrPressable>
            ) : null}
            <HdrPressable
              effect="subtle"
              onPress={() => {
                hapticForScene('press');
                onClose();
              }}
              style={[styles.button, { backgroundColor: colors.background }]}
            >
              <Text style={[styles.buttonText, { color: colors.text }]}>关闭</Text>
            </HdrPressable>
          </View>
        </View>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  backdrop: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(0,0,0,0.35)',
    padding: 24,
  },
  card: {
    width: '100%',
    maxWidth: 420,
    maxHeight: '78%',
    padding: 20,
    gap: 10,
    ...RadiusStyle.card,
  },
  title: { fontSize: 17, fontWeight: '600' },
  meta: { fontSize: 13, lineHeight: 18 },
  notesScroll: { flexGrow: 0, marginTop: 2 },
  notesContent: { paddingBottom: 2 },
  notes: { fontSize: 13, lineHeight: 19 },
  actions: { flexDirection: 'row', justifyContent: 'flex-end', gap: 10, marginTop: 6 },
  button: { paddingHorizontal: 16, paddingVertical: 9, ...RadiusStyle.capsule },
  buttonText: { fontSize: 14, fontWeight: '600' },
});
