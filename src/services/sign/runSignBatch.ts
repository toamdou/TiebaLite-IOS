/**
 * Foreground one-click sign runner. Keeps mSign fallback, per-forum serial
 * signing, slow-mode delays, progress throttling, and failure handling in one
 * place. (The native background auto-sign runs entirely in Swift, see
 * TiebaBackgroundSync.)
 */

import { sign, mSign } from '@/services/api';
import { getPreferences } from '@/services/storage/PreferencesStorage';
import { getUidSync } from '@/services/storage/AuthSQLiteStorage';
import { fetchAllFollowedForums } from '@/services/forumFollowed';
import { AUTO_SIGN_MIN_INTERVAL_MS } from '@/constants/app';
import type { SignResult } from '@/types';
import {
  DEFAULT_USE_OFFICIAL_SIGN,
  type RunSignBatchOptions,
  type RunSignBatchResult,
  type SignBatchProgress,
  type SignProgressItem,
} from './signTypes';

/** Progress notification update cadence (every 3 forums). */
const NOTIFICATION_UPDATE_EVERY = 3;
/** Live Activity update cadence (every forum, throttled by ActivityKit bridge). */
const LIVE_ACTIVITY_UPDATE_EVERY = 1;

/**
 * Baidu Tieba returns error_code 1101 for a forum already signed today (e.g. by
 * the native background auto-sign running just before the user opened the app).
 * It is a successful state, never a failure — otherwise a stale followed list
 * misreports "失败 N". Mirrors the Swift classification in TiebaBackgroundSync.
 */
const ALREADY_SIGNED_ERROR_CODE = 1101;

/** True when a sign result means "this forum is signed today". */
function signedToday(result: SignResult | null | undefined): boolean {
  return (
    result != null &&
    (result.isSuccess || result.errorCode === ALREADY_SIGNED_ERROR_CODE)
  );
}

async function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export async function runSignBatch(options: RunSignBatchOptions): Promise<RunSignBatchResult> {
  const { tbs, shouldCancel, onProgress, progressNotif, liveActivity } = options;
  const allForums = await fetchAllFollowedForums();
  const unsigned = allForums.filter((f) => !f.isSign);
  const totalCount = unsigned.length;
  let successCount = 0;
  let failCount = 0;
  let totalExp = 0;
  let cancelled = false;
  let progressList: SignProgressItem[] = unsigned.map((f) => ({
    forumId: f.forumId,
    forumName: f.forumName,
    status: 'pending' as const,
  }));

  let liveActivityId: string | null = null;
  let progressNotifId: string | null = null;

  const buildResult = (): RunSignBatchResult => ({
    successCount,
    failCount,
    totalExp,
    progressList,
    totalCount,
    cancelled,
    // 对齐 Kotlin OKSignService.onFinish：total==0 时区分「没有可签到的吧」
    // （已关注列表为空）与「全部已签」（列表有吧但无需再签）。
    allAlreadySigned: totalCount === 0 && allForums.length > 0,
    noSignable: allForums.length === 0,
    liveActivityId,
    progressNotifId,
  });

  const updateItem = (forumId: string, patch: Partial<SignProgressItem>): void => {
    progressList = progressList.map((item) =>
      item.forumId === forumId ? { ...item, ...patch } : item,
    );
  };

  const snapshot = (currentForumName?: string): SignBatchProgress => ({
    totalCount,
    successCount,
    failCount,
    currentIndex: successCount + failCount,
    totalExp,
    progressList,
    currentForumName,
  });

  const emitProgress = async (currentForumName?: string) => {
    if (onProgress) await onProgress(snapshot(currentForumName));
  };

  if (totalCount === 0) {
    return buildResult();
  }

  if (progressNotif) {
    progressNotifId = await progressNotif.start(totalCount);
  }
  if (liveActivity) {
    liveActivityId = await liveActivity.start(totalCount);
  }

  const prefs = await getPreferences();
  const useOfficialSign = prefs.useOfficialSign ?? DEFAULT_USE_OFFICIAL_SIGN;
  const failAutoStop = prefs.failAutoStop ?? true;
  const slowMode = prefs.slowSignMode ?? false;

  let remaining = [...unsigned];

  // Official batch path. Slow mode intentionally falls back to serial signing
  // so its per-forum delays remain effective.
  if (useOfficialSign && !slowMode) {
    try {
      // Kotlin OKSigner sends user_id = AccountUtil.getUid() on msign;
      // getUidSync() 是 RN 侧 AccountUtil.getUid() 等价物（AuthSQLiteStorage 的
      // uid 缓存，前台签到时为当前活跃账号 uid）；缓存取不到时回落 ''（原行为）。
      // Kotlin additionally trims the batch to forums with
      // levelId >= getForumListBean.level && signData.size < getForumListBean.msignStepNum;
      // RN has no /c/f/forum/getforumlist equivalent, so the user-level
      // threshold (mSignLevel/mSignMax) is unavailable — submit all unsigned.
      const results = await mSign(unsigned.map((f) => f.forumId), tbs, getUidSync() || undefined);
      const handledIds = new Set(
        results.filter((r) => signedToday(r)).map((r) => r.forumId),
      );
      results.forEach((r) => {
        if (signedToday(r)) successCount++;
        else {
          failCount++;
          // 失败诊断（2026-08-28 关注后一键签到失败排查）：错误码/文案
          // 此前只进未读 UI 态，Metro 不可见；打印以区分 1101 键名解析
          // 问题、关注同步延迟拒绝、或账号级限制。
          if (__DEV__) {
            console.warn(
              `[sign] ERR forum=${r.forumId ?? r.forumName ?? '?'} code=${r.errorCode ?? '?'} msg=${r.errorMsg ?? '(无)'}`,
            );
          }
        }
      });
      results.forEach((r) => {
        updateItem(r.forumId, {
          status: signedToday(r) ? 'success' : 'failed',
          exp: r.exp,
          signRank: r.signRank,
          errorMsg: r.errorMsg,
        });
      });
      totalExp = results.reduce((sum, r) => sum + (r.exp ?? 0), 0);
      remaining = unsigned.filter((f) => !handledIds.has(f.forumId));
      await emitProgress();
      if (progressNotif && progressNotifId) {
        // 批量接口一次返回全部结果：立即刷新横幅进度，避免卡在 0/N。
        void progressNotif
          .update(progressNotifId, successCount + failCount, totalCount)
          .catch(() => {});
      }
      if (liveActivity && liveActivityId) {
        void liveActivity.update(liveActivityId, snapshot()).catch(() => {});
      }
      if (shouldCancel?.()) {
        cancelled = true;
        return buildResult();
      }
      if (failAutoStop && failCount > 0) {
        return buildResult();
      }
    } catch {
      // mSign failed entirely - fall through to individual signing
    }
  }

  for (let i = 0; i < remaining.length; i++) {
    if (shouldCancel?.()) {
      cancelled = true;
      break;
    }

    const forum = remaining[i];
    updateItem(forum.forumId, { status: 'signing' });

    let result: SignResult | null = null;
    try {
      // fid 必传：对齐 Kotlin OfficialTiebaApi.signFlow(fid, kw, tbs)，
      // 贴吧服务端按 fid 归属签到结果（仅 kw 在吧名变更时会签错吧）。
      result = await sign(forum.forumName, tbs, forum.forumId);
      updateItem(forum.forumId, {
        status: signedToday(result) ? 'success' : 'failed',
        exp: result?.exp,
        signRank: result?.signRank,
        errorMsg: result?.errorMsg,
      });
      if (signedToday(result)) successCount++;
      else failCount++;
      totalExp += result?.exp ?? 0;
    } catch {
      updateItem(forum.forumId, { status: 'failed', errorMsg: '网络请求失败' });
      failCount++;
    }

    await emitProgress(forum.forumName);

    const done = successCount + failCount;
    if (progressNotif && progressNotifId && done % NOTIFICATION_UPDATE_EVERY === 0) {
      // 不阻塞签到循环：通知/ActivityKit IPC 在模拟器上可能耗时数秒，
      // await 会把整个串行签到拖慢一个数量级（后台签到不能影响签到本身）。
      void progressNotif.update(progressNotifId, done, totalCount).catch(() => {});
    }
    if (liveActivity && liveActivityId && done % LIVE_ACTIVITY_UPDATE_EVERY === 0) {
      void liveActivity.update(liveActivityId, snapshot(forum.forumName)).catch(() => {});
    }

    if (failAutoStop && !signedToday(result)) break;

    const signDelay = slowMode
      ? Math.floor(Math.random() * 4500) + 3500 // 3500-8000ms (matching Kotlin)
      : AUTO_SIGN_MIN_INTERVAL_MS;
    if (i < remaining.length - 1) {
      await delay(signDelay);
    }
  }

  return buildResult();
}
