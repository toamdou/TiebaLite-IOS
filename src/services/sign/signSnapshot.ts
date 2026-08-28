// ============================================================
// signSnapshot — 签到 Live Activity 共享文案/进度构建器（跨域契约）
//
// 通知/LiveActivity 域与签到域共享的唯一样板：
//   - SignLiveActivityPhase：Live Activity 相位（含 'cancelled'）
//   - SignLiveActivityState：跨桥 state 契约（TiebaNative.startLiveActivity
//     等四个 Live Activity 方法的参数类型，TiebaNative.ts 引用本文件）
//   - buildSignSnapshot()：liveActivity.ts 的 buildState 与设置页
//     LiveActivityPreview 都消费同一构建器，杜绝双实现漂移
//   - 常量收敛在此一处：单吧预估时长（3800ms；Preview 倒计时魔数 3.2s 已
//     消除）、主题色、活动名、存储键
// 备注：签到域代理约定不修改本文件（只读/import 使用）。
// ============================================================

export type SignLiveActivityPhase = 'signing' | 'completed' | 'error' | 'cancelled';

export interface SignLiveActivitySnapshot {
  done: number;
  total: number;
  currentForumName?: string;
  success: number;
  fail: number;
  exp: number;
  phase: SignLiveActivityPhase;
}

/** 跨桥 Live Activity state 契约（原生锁屏/灵动岛渲染的数据字典）。 */
export interface SignLiveActivityState {
  title: string;
  subtitle: string;
  body?: string;
  currentForum: string;
  status: string;
  progress: number;
  date?: number;
  imageName: string;
  tintColorHex: string;
  leading?: string;
  trailing?: string;
  extra?: {
    currentForum: string;
    success: string;
    fail: string;
    exp: string;
  };
  /** 锁屏右侧胶囊/灵动岛徽标文案（与 status 同源；预览与桥共用同一值） */
  pill: string;
  /** 相位主题色（预览渲染与桥保持一致） */
  accent: string;
}

// 单吧预估耗时：锁定屏"预计 x:xx"与倒计时共用（原 liveActivity 的 3800ms
// 与 LiveActivityPreview 的 3.2s 幻数为双实现，统一收敛为本常量）。
export const SIGN_ESTIMATED_MS_PER_SIGN = 3800;
// 预计结束时间钳制：最短 6 秒（避免剩最后一吧瞬间倒计时归零），最长 30 分钟。
export const SIGN_ESTIMATED_MIN_MS = 6000;
export const SIGN_ESTIMATED_MAX_MS = 30 * 60 * 1000;

export const SIGN_LIVE_ACTIVITY_STORAGE_KEY = 'tiebalite_sign_live_activity_id';
export const SIGN_LIVE_ACTIVITY_NAME = 'TiebaLiteSign';
export const SIGN_LIVE_ACTIVITY_TINT_COLOR = '#3B82F6';
export const SIGN_LIVE_ACTIVITY_ACCENTS = {
  signing: '#60A5FA',
  completed: '#30D158',
  interrupted: '#FF6B5E',
} as const;

function clampProgress(value: number): number {
  if (!Number.isFinite(value)) return 0;
  return Math.min(Math.max(value, 0), 1);
}

/**
 * 进度/结果行唯一模板：「已完成 x/y · 成功 a · 失败 b」，已获得经验时追加
 * 「 · 获得 e 经验」。
 * buildSignSnapshot 的 body（锁屏/灵动岛）与 LiveActivityPreview 的 meta
 * （设置页预览）共用本函数，杜绝双实现漂移——两处文案必须同步修改时只改这里。
 */
export function buildMetaText(
  done: number,
  total: number,
  success: number,
  fail: number,
  exp: number,
): string {
  const parts = [`已完成 ${done}/${total}`, `成功 ${success}`, `失败 ${fail}`];
  if (exp > 0) parts.push(`获得 ${exp} 经验`);
  return parts.join(' · ');
}

/**
 * 由签到进度快照构建 Live Activity 桥 state。
 * liveActivity.ts 与 LiveActivityPreview 都消费本构建器；
 * 相位语义：signing=进行中、completed=完成、error/cancelled=中断。
 */
export function buildSignSnapshot(snapshot: SignLiveActivitySnapshot): SignLiveActivityState {
  const { phase, done, total, success, fail, exp } = snapshot;
  const ratio = total > 0 ? clampProgress(done / total) : 1;
  const remaining = Math.max(total - done, 0);
  const estimatedEnd = Date.now() + Math.min(
    Math.max(remaining * SIGN_ESTIMATED_MS_PER_SIGN, SIGN_ESTIMATED_MIN_MS),
    SIGN_ESTIMATED_MAX_MS,
  );
  const signing = phase === 'signing';
  const completed = phase === 'completed';
  const interrupted = phase === 'error' || phase === 'cancelled';

  const status = signing ? `${done}/${total}` : completed ? '完成' : '中断';
  const accent = interrupted
    ? SIGN_LIVE_ACTIVITY_ACCENTS.interrupted
    : completed
      ? SIGN_LIVE_ACTIVITY_ACCENTS.completed
      : SIGN_LIVE_ACTIVITY_ACCENTS.signing;

  return {
    title: signing ? '一键签到' : completed ? '签到完成' : '签到已中断',
    subtitle: signing
      ? snapshot.currentForumName
        ? `正在签到 ${snapshot.currentForumName}`
        : '正在准备签到'
      : completed
        ? `成功 ${success} 个${fail > 0 ? `，失败 ${fail} 个` : ''}`
        : '签到进程已停止',
    body: signing || (completed && exp > 0)
      ? buildMetaText(done, total, success, fail, exp)
      : undefined,
    currentForum: snapshot.currentForumName ?? '',
    status,
    pill: status,
    progress: ratio,
    date: signing ? estimatedEnd : undefined,
    imageName: signing
      ? 'checkmark.circle.fill'
      : completed
        ? 'checkmark.seal.fill'
        : 'xmark.circle.fill',
    tintColorHex: SIGN_LIVE_ACTIVITY_TINT_COLOR,
    accent,
    leading: signing ? '签到' : undefined,
    trailing: signing ? `${done}/${total}` : undefined,
    extra: signing
      ? {
          currentForum: snapshot.currentForumName ?? '',
          success: String(success),
          fail: String(fail),
          exp: String(exp),
        }
      : undefined,
  };
}