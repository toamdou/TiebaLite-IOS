import { StyleSheet, View } from 'react-native';
import { Text } from './CompatText';
import { formatDuration } from '@/utils/formatDuration';
import type { SignStatus } from '@/stores/signStore';
import { SymbolView } from '@/components/ui/SymbolView';
import {
  buildMetaText,
  buildSignSnapshot,
  SIGN_ESTIMATED_MIN_MS,
  type SignLiveActivityPhase,
  type SignLiveActivitySnapshot,
} from '@/services/sign/signSnapshot';

interface LiveActivityPreviewProps {
  active: boolean;
  enabled?: boolean;
  done: number;
  total: number;
  currentForumName?: string;
  success: number;
  fail: number;
  exp: number;
  /**
   * 预览状态。接受签到域 SignStatus（oksign 直接透传 store.status，
   * 其中 idle/loading 在预览中按进行前/准备中处理）与 Live Activity 相位
   * （SignLiveActivityPhase，含 'cancelled'——按中断态渲染）。
   */
  status: SignStatus | SignLiveActivityPhase;
}

/** 归一为相位：SignStatus 的 idle/loading 视为"尚未开始"→ signing。 */
function toPreviewPhase(status: SignStatus | SignLiveActivityPhase): SignLiveActivityPhase {
  if (status === 'idle' || status === 'loading') return 'signing';
  return status;
}

/**
 * 剩余耗时文案：估算统一走 SIGN_ESTIMATED_MS_PER_SIGN（与桥同一常量）。
 * 显示下限与 SIGN_ESTIMATED_MIN_MS（6000）对齐——桥把预计结束时间钳在
 * ≥6s，倒计时同样不跌破 0:06（避免剩最后一吧瞬间归零；两处脱节会出现
 * 0:07/0:08 区间只显示不落地的死区）。
 */
function formatCountdown(remainingMs: number): string {
  const seconds = Math.max(Math.ceil(remainingMs / 1000), SIGN_ESTIMATED_MIN_MS / 1000);
  return formatDuration(seconds);
}

export function LiveActivityPreview({
  active,
  enabled = true,
  done,
  total,
  currentForumName,
  success,
  fail,
  exp,
  status,
}: LiveActivityPreviewProps) {
  const phase = toPreviewPhase(status);
  const previewTotal = total > 0 ? total : 12;
  const previewDone = total > 0 ? Math.min(done, total) : 6;
  // 与 liveActivity.ts 桥消费同一构建器：标题/副标题/胶囊/进度/主题色
  // 全部来自 buildSignSnapshot，杜绝双实现漂移。
  const snapshot: SignLiveActivitySnapshot = {
    done: previewDone,
    total: previewTotal,
    currentForumName,
    success,
    fail,
    exp,
    phase,
  };
  const state = buildSignSnapshot(snapshot);
  const interrupted = phase === 'error' || phase === 'cancelled';

  // 进度/结果行唯一模板在 signSnapshot.buildMetaText（与桥 body 同源），
  // 此处只做相位分支：完成态无经验→"今日已完成"、中断→重试提示、其余→模板行。
  const meta = phase === 'completed'
    ? exp > 0
      ? buildMetaText(previewDone, previewTotal, success, fail, exp)
      : '今日签到已完成'
    : interrupted
      ? '稍后可在设置中重试'
      : buildMetaText(previewDone, previewTotal, success, fail, exp);
  // 胶囊：空闲预览固定展示示例值 6/12（"将来运行时长这样"），
  // 激活/完成/中断时展示与桥一致的相位文案（signing=进度、completed=完成、
  // error/cancelled=中断）。
  const pill = active || phase === 'completed' || interrupted
    ? state.pill
    : '6/12';
  const finished = previewDone >= previewTotal;

  return (
    <View style={[styles.container, !enabled && styles.containerDisabled]}>
      {!enabled && (
        <View style={styles.disabledNotice}>
          <Text style={styles.disabledNoticeText}>灵动岛已关闭</Text>
        </View>
      )}
      <View style={styles.lockCard}>
        <View style={styles.lockRow}>
          <View style={[styles.iconBadge, { borderColor: state.accent, backgroundColor: `${state.accent}22` }]}>
            <SymbolView name="checkmark" size={14} weight="bold" tintColor={state.accent} />
          </View>
          <View style={styles.lockText}>
            <Text style={styles.lockTitle} numberOfLines={1}>{state.title}</Text>
            <Text style={styles.lockSubtitle} numberOfLines={1}>{state.subtitle}</Text>
          </View>
          <View style={[styles.pill, { backgroundColor: `${state.accent}22` }]}>
            <Text style={[styles.pillText, { color: state.accent }]}>{pill}</Text>
          </View>
        </View>
        <View style={styles.progressTrack}>
          <View style={[styles.progressFill, { width: `${state.progress * 100}%`, backgroundColor: state.accent }]} />
        </View>
        <View style={styles.lockFooter}>
          <Text style={styles.lockMeta} numberOfLines={1}>{meta}</Text>
          {/* 完成态（进度已满）不再显示"预计 0:08"倒计时 */}
          {active && !finished && state.date && (
            <Text style={[styles.lockCountdown, { color: state.accent }]}>
              预计 {formatCountdown(state.date - Date.now())}
            </Text>
          )}
        </View>
      </View>

      <View style={styles.islandColumn}>
        <View style={styles.islandCompact}>
          <View style={[styles.islandCompactIcon, { borderColor: state.accent }]}>
            <SymbolView name="checkmark" size={8} weight="bold" tintColor={state.accent} />
          </View>
          <View style={styles.islandCompactText}>
            <Text style={styles.islandCompactTitle}>签到</Text>
            <Text style={[styles.islandCompactMeta, { color: state.accent }]}>{pill}</Text>
          </View>
          <View style={[styles.islandRing, { borderColor: `${state.accent}44` }]}>
            <View
              style={[
                styles.islandRingFill,
                {
                  borderTopColor: state.accent,
                  borderRightColor: state.accent,
                  transform: [{ rotate: `${state.progress * 360}deg` }],
                },
              ]}
            />
          </View>
        </View>

        <View style={styles.islandExpanded}>
          <View style={styles.expandedTop}>
            <Text style={styles.expandedTitle} numberOfLines={1}>{state.title}</Text>
            <Text style={[styles.expandedStatus, { color: state.accent }]}>{pill}</Text>
          </View>
          <Text style={styles.expandedSubtitle} numberOfLines={1}>{state.subtitle}</Text>
          <View style={styles.progressTrack}>
            <View style={[styles.progressFill, { width: `${state.progress * 100}%`, backgroundColor: state.accent }]} />
          </View>
        </View>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    gap: 12,
  },
  containerDisabled: {
    opacity: 0.45,
  },
  disabledNotice: {
    alignSelf: 'center',
    backgroundColor: 'rgba(255,255,255,0.12)',
    borderRadius: 999,
    paddingHorizontal: 12,
    paddingVertical: 5,
  },
  disabledNoticeText: {
    color: 'rgba(255,255,255,0.72)',
    fontSize: 11,
    fontWeight: '600',
  },
  lockCard: {
    backgroundColor: '#101623',
    borderRadius: 22,
    borderCurve: 'continuous',
    padding: 16,
    gap: 12,
  },
  lockRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
  },
  iconBadge: {
    width: 34,
    height: 34,
    borderRadius: 17,
    borderWidth: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  lockText: {
    flex: 1,
    gap: 2,
  },
  lockTitle: {
    color: '#FFFFFF',
    fontSize: 16,
    fontWeight: '700',
  },
  lockSubtitle: {
    color: 'rgba(255,255,255,0.68)',
    fontSize: 12,
  },
  pill: {
    borderRadius: 999,
    paddingHorizontal: 10,
    paddingVertical: 4,
  },
  pillText: {
    fontSize: 12,
    fontWeight: '700',
    fontVariant: ['tabular-nums'],
  },
  progressTrack: {
    height: 6,
    borderRadius: 3,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(255,255,255,0.16)',
    overflow: 'hidden',
  },
  progressFill: {
    height: '100%',
    borderRadius: 3,
    borderCurve: 'continuous',
  },
  lockFooter: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 12,
  },
  lockMeta: {
    flex: 1,
    color: 'rgba(255,255,255,0.52)',
    fontSize: 11,
  },
  lockCountdown: {
    fontSize: 12,
    fontWeight: '600',
    fontVariant: ['tabular-nums'],
  },
  islandColumn: {
    gap: 8,
  },
  islandCompact: {
    alignSelf: 'center',
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#000000',
    borderColor: '#2B2B2E',
    borderWidth: 1,
    borderRadius: 24,
    borderCurve: 'continuous',
    paddingHorizontal: 12,
    paddingVertical: 8,
    gap: 8,
    minWidth: 132,
  },
  islandCompactIcon: {
    width: 20,
    height: 20,
    borderRadius: 10,
    borderCurve: 'continuous',
    borderWidth: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  islandCompactText: {
    flex: 1,
  },
  islandCompactTitle: {
    color: '#FFFFFF',
    fontSize: 11,
    fontWeight: '600',
  },
  islandCompactMeta: {
    fontSize: 10,
    fontWeight: '700',
    fontVariant: ['tabular-nums'],
  },
  islandRing: {
    width: 22,
    height: 22,
    borderRadius: 11,
    borderCurve: 'continuous',
    borderWidth: 2,
    alignItems: 'center',
    justifyContent: 'center',
  },
  islandRingFill: {
    width: 14,
    height: 14,
    borderRadius: 7,
    borderCurve: 'continuous',
    borderWidth: 2,
  },
  islandExpanded: {
    backgroundColor: '#000000',
    borderColor: '#2B2B2E',
    borderWidth: 1,
    borderRadius: 34,
    borderCurve: 'continuous',
    paddingHorizontal: 20,
    paddingVertical: 12,
    gap: 6,
  },
  expandedTop: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 12,
  },
  expandedTitle: {
    flex: 1,
    color: '#FFFFFF',
    fontSize: 15,
    fontWeight: '700',
  },
  expandedStatus: {
    fontSize: 13,
    fontWeight: '700',
    fontVariant: ['tabular-nums'],
  },
  expandedSubtitle: {
    color: 'rgba(255,255,255,0.68)',
    fontSize: 11,
  },
});