/**
 * 崩溃与卡顿日志页 —— Release 构建采集的诊断日志浏览/导出。
 *
 * 结构：ScrollView 行列表（勾选框 + 类型图标 + 时间标题 + 大小）、
 * 底部操作条（导出所选 / 删除所选，选中时浮现）、预览 Modal（等宽文本 +
 * 单条分享）。日志由原生侧采集写入 Application Support/TiebaLogs/
 * （闪退/信号崩溃/主线程卡死/JS 错误四类），此处只读不采。
 * 原生模块缺失（旧二进制）时列表恒空、操作静默无效，不会抛错。
 */

import { useCallback, useEffect, useState } from 'react';
import {
  Alert,
  Modal,
  Platform,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { Stack } from 'expo-router';
import { File, Paths } from 'expo-file-system';
import * as Sharing from 'expo-sharing';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { SymbolView } from '@/components/ui/SymbolView';
import { EmptyState } from '@/components/ui/EmptyState';
import { useThemeColors } from '@/theme/ThemeContext';
import { typographyStyles } from '@/theme/typography';
import {RadiusStyle} from '@/theme/spacing';
import { hapticForScene } from '@/theme/hapticsMap';
import {
  clearDiagnosticLogs,
  deleteDiagnosticLogs,
  listDiagnosticLogs,
  readDiagnosticLog,
  type DiagnosticLogEntry,
} from '../../../modules/tieba-system/src';

const TYPE_META: Record<string, { label: string; icon: string }> = {
  crash: { label: '闪退', icon: 'exclamationmark.triangle.fill' },
  signal: { label: '信号崩溃', icon: 'bolt.fill' },
  hang: { label: '卡死', icon: 'hourglass' },
  jserror: { label: 'JS 错误', icon: 'curlybraces' },
};

function metaOf(name: string): { label: string; icon: string } {
  const prefix = name.split('-')[0];
  return TYPE_META[prefix] ?? { label: '日志', icon: 'doc.text' };
}

/** crash-2026-08-26_14-03-22.log → 「2026-08-26 14:03:22」；不合规范名原样回退 */
function displayTitle(name: string): string {
  const m = name.match(/^([a-z]+)-(\d{4}-\d{2}-\d{2})_(\d{2})-(\d{2})-(\d{2})\.log$/i);
  if (!m) return name.replace(/\.log$/i, '');
  return `${m[2]} ${m[3]}:${m[4]}:${m[5]}`;
}

function formatSize(bytes: number): string {
  if (bytes >= 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  if (bytes >= 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  return `${bytes} B`;
}

/** 把若干日志合并写进缓存目录的一个 txt 并拉起系统分享面板 */
async function shareMerged(names: string[], readOne: (n: string) => Promise<string>) {
  const ordered = [...names].sort();
  const parts: string[] = [];
  for (const name of ordered) {
    parts.push(`───── ${name} ─────\n\n${await readOne(name)}`);
  }
  const file = new File(Paths.cache, `TiebaLogs-export-${Date.now()}.txt`);
  file.write(parts.join('\n\n'));
  await Sharing.shareAsync(file.uri, {
    mimeType: 'text/plain',
    dialogTitle: '导出诊断日志',
  });
}

export default function DiagnosticLogsPage() {
  const { colors } = useThemeColors();
  const insets = useSafeAreaInsets();
  const [entries, setEntries] = useState<DiagnosticLogEntry[] | null>(null);
  const [selected, setSelected] = useState<ReadonlySet<string>>(new Set());
  const [preview, setPreview] = useState<{ name: string; content: string } | null>(null);
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    const list = await listDiagnosticLogs();
    setEntries(list);
    // 收缩勾选集：已被删除/轮转掉的文件从选中态剔除
    setSelected((prev) => {
      const alive = new Set(list.map((e) => e.name));
      const next = new Set([...prev].filter((n) => alive.has(n)));
      return next.size === prev.size ? prev : next;
    });
  }, []);

  useEffect(() => {
    void load();
  }, [load]);

  const toggleSelect = useCallback((name: string) => {
    hapticForScene('toggle');
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(name)) next.delete(name);
      else next.add(name);
      return next;
    });
  }, []);

  const openPreview = useCallback(async (entry: DiagnosticLogEntry) => {
    const content = await readDiagnosticLog(entry.name);
    if (!content) {
      Alert.alert('无法读取', '该日志内容为空或已被清理。');
      return;
    }
    setPreview({ name: entry.name, content });
  }, []);

  const handleExportSelected = useCallback(async () => {
    if (busy || selected.size === 0 || !entries) return;
    setBusy(true);
    try {
      const ordered = entries.filter((e) => selected.has(e.name)).map((e) => e.name);
      await shareMerged(ordered, readDiagnosticLog);
      hapticForScene('action-success');
    } catch {
      Alert.alert('导出失败', '分享面板未能打开，请重试。');
    } finally {
      setBusy(false);
    }
  }, [busy, selected, entries]);

  const handleDeleteSelected = useCallback(() => {
    if (busy || selected.size === 0) return;
    Alert.alert('删除所选日志', `将删除选中的 ${selected.size} 条日志，不可恢复。`, [
      { text: '取消', style: 'cancel' },
      {
        text: '删除',
        style: 'destructive',
        onPress: () => {
          setBusy(true);
          void deleteDiagnosticLogs([...selected])
            .then(load)
            .catch(() => {})
            .finally(() => {
              setBusy(false);
              hapticForScene('action-success');
            });
        },
      },
    ]);
  }, [busy, selected, load]);

  const handleClearAll = useCallback(() => {
    if (busy) return;
    Alert.alert('清空全部日志', '将删除所有已保存的诊断日志，不可恢复。', [
      { text: '取消', style: 'cancel' },
      {
        text: '清空',
        style: 'destructive',
        onPress: () => {
          setBusy(true);
          void clearDiagnosticLogs()
            .then(load)
            .catch(() => {})
            .finally(() => {
              setBusy(false);
              hapticForScene('action-success');
            });
        },
      },
    ]);
  }, [busy, load]);

  const handleShareSingle = useCallback(async () => {
    if (!preview || busy) return;
    setBusy(true);
    try {
      await shareMerged([preview.name], readDiagnosticLog);
    } catch {
      Alert.alert('导出失败', '分享面板未能打开，请重试。');
    } finally {
      setBusy(false);
    }
  }, [preview, busy]);

  return (
    <View style={[styles.container, { backgroundColor: colors.background }]}>
      <Stack.Screen
        options={{
          title: '崩溃与卡顿日志',
          headerRight:
            entries && entries.length > 0
              ? () => (
                  <Pressable
                    onPress={handleClearAll}
                    hitSlop={8}
                    accessibilityRole="button"
                    accessibilityLabel="清空全部日志"
                  >
                    <SymbolView name="trash" size={19} tintColor={colors.text} />
                  </Pressable>
                )
              : undefined,
        }}
      />

      {entries === null ? null : entries.length === 0 ? (
        <EmptyState
          title="暂无日志"
          description="Release 构建下发生闪退、信号崩溃、卡死或 JS 错误时会自动记录在这里"
          icon="doc.text"
        />
      ) : (
        <ScrollView contentContainerStyle={styles.list}>
          {entries.map((entry) => {
            const checked = selected.has(entry.name);
            const meta = metaOf(entry.name);
            return (
              <Pressable
                key={entry.name}
                onPress={() => void openPreview(entry)}
                style={({ pressed }) => [
                  styles.row,
                  { backgroundColor: colors.card, borderColor: colors.borderCard, opacity: pressed ? 0.75 : 1 },
                ]}
                accessibilityRole="button"
                accessibilityLabel={`${meta.label}日志 ${displayTitle(entry.name)}`}
              >
                <Pressable
                  onPress={(e) => {
                    e.stopPropagation?.();
                    toggleSelect(entry.name);
                  }}
                  style={styles.checkbox}
                  hitSlop={6}
                  accessibilityRole="checkbox"
                  accessibilityState={{ checked }}
                  accessibilityLabel={`选择 ${displayTitle(entry.name)}`}
                >
                  <SymbolView
                    name={checked ? 'checkmark.circle.fill' : 'circle'}
                    size={22}
                    tintColor={checked ? colors.primary : colors.textTertiary}
                  />
                </Pressable>
                <SymbolView name={meta.icon} size={17} tintColor={colors.warning} />
                <View style={styles.rowTexts}>
                  <Text numberOfLines={1} style={[styles.rowTitle, { color: colors.text }]}>
                    {displayTitle(entry.name)}
                  </Text>
                  <Text numberOfLines={1} style={[styles.rowSub, { color: colors.textSecondary }]}>
                    {`${meta.label} · ${formatSize(entry.size)}`}
                  </Text>
                </View>
                <SymbolView name="chevron.right" size={11} weight="semibold" tintColor={colors.textTertiary} />
              </Pressable>
            );
          })}
          <Text style={[styles.hint, { color: colors.textTertiary }]}>
            {'仅 Release 构建自动采集；最多保留 20 个文件 / 14 天 / 总量 5MB。点行查看全文，点圆圈勾选。'}
          </Text>
        </ScrollView>
      )}

      {/* 底部操作条：有选中项时浮现 */}
      {selected.size > 0 && (
        <View
          style={[
            styles.actionBar,
            {
              backgroundColor: colors.card,
              borderColor: colors.borderCard,
              paddingBottom: insets.bottom + 10,
            },
          ]}
        >
          <Pressable
            onPress={() => void handleExportSelected()}
            disabled={busy}
            style={({ pressed }) => [
              styles.actionBtn,
              { backgroundColor: colors.primary, opacity: busy ? 0.5 : pressed ? 0.85 : 1 },
            ]}
            accessibilityRole="button"
            accessibilityLabel="导出所选日志"
          >
            <Text style={[styles.actionBtnText, { color: colors.textOnPrimary }]}>
              {`导出所选（${selected.size}）`}
            </Text>
          </Pressable>
          <Pressable
            onPress={handleDeleteSelected}
            disabled={busy}
            style={({ pressed }) => [
              styles.actionBtn,
              { backgroundColor: colors.chip, opacity: busy ? 0.5 : pressed ? 0.85 : 1 },
            ]}
            accessibilityRole="button"
            accessibilityLabel="删除所选日志"
          >
            <Text style={[styles.actionBtnText, { color: colors.danger }]}>删除所选</Text>
          </Pressable>
        </View>
      )}

      {/* 全文预览 */}
      <Modal visible={preview !== null} animationType="slide" onRequestClose={() => setPreview(null)}>
        <View style={[styles.modalContainer, { backgroundColor: colors.background, paddingTop: insets.top + 6 }]}>
          <View style={styles.modalHeader}>
            <Pressable onPress={() => setPreview(null)} hitSlop={8}>
              <Text style={[styles.modalClose, { color: colors.primary }]}>关闭</Text>
            </Pressable>
            <Text numberOfLines={1} style={[styles.modalTitle, { color: colors.text }]}>
              {preview ? displayTitle(preview.name) : ''}
            </Text>
            <Pressable onPress={() => void handleShareSingle()} hitSlop={8} accessibilityLabel="分享此日志">
              <SymbolView name="square.and.arrow.up" size={19} tintColor={colors.primary} />
            </Pressable>
          </View>
          <ScrollView style={styles.modalBody} contentContainerStyle={styles.modalContent}>
            <Text selectable style={[styles.logText, { color: colors.text }]}>
              {preview?.content ?? ''}
            </Text>
          </ScrollView>
        </View>
      </Modal>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
  },
  list: {
    padding: 10,
    paddingBottom: 120,
    gap: 8,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    borderWidth: StyleSheet.hairlineWidth,
    ...RadiusStyle.input,
    paddingHorizontal: 12,
    paddingVertical: 11,
  },
  checkbox: {
    width: 24,
    alignItems: 'center',
  },
  rowTexts: {
    flex: 1,
    gap: 2,
  },
  rowTitle: {
    ...typographyStyles.subheadBold,
  },
  rowSub: {
    ...typographyStyles.caption1,
  },
  hint: {
    ...typographyStyles.caption1,
    textAlign: 'center',
    paddingHorizontal: 24,
    marginTop: 4,
    lineHeight: 17,
  },
  actionBar: {
    position: 'absolute',
    left: 10,
    right: 10,
    bottom: 0,
    flexDirection: 'row',
    gap: 10,
    paddingTop: 10,
    paddingHorizontal: 10,
    borderTopWidth: StyleSheet.hairlineWidth,
  },
  actionBtn: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: 13,
    ...RadiusStyle.chip,
  },
  actionBtnText: {
    fontSize: 15,
    fontWeight: '600',
  },
  modalContainer: {
    flex: 1,
  },
  modalHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 12,
    paddingHorizontal: 16,
    paddingVertical: 10,
  },
  modalClose: {
    fontSize: 15,
    fontWeight: '600',
  },
  modalTitle: {
    flex: 1,
    textAlign: 'center',
    fontSize: 14,
    fontWeight: '600',
  },
  modalBody: {
    flex: 1,
  },
  modalContent: {
    padding: 14,
    paddingBottom: 40,
  },
  logText: {
    fontFamily: Platform.select({ ios: 'Menlo' }),
    fontSize: 11,
    lineHeight: 17,
  },
});
