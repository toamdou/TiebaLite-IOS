/**
 * SignViewModel - Zustand state and actions for the foreground one-click
 * sign flow. The store facade in src/stores/signStore.ts re-exports this.
 */

import * as Notifications from 'expo-notifications';
import { create, type StoreApi, type UseBoundStore } from 'zustand';
import { hapticForScene } from '@/theme/hapticsMap';
import { useAuthStore } from '@/stores/authStore';
import { usePreferencesStore } from '@/stores/preferencesStore';
import { useForumStore } from '@/stores/forumStore';
import { ensureNotificationPermissionAsync } from '@/services/NotificationPoller';
import { setTbsSync } from '@/services/storage/AuthSQLiteStorage';
import { syncBackgroundSnapshot } from '@/services/nativeBackground';
import { showToast } from '@/components/ui/Toast';
import {
  finishSignLiveActivity,
  startSignLiveActivity,
  updateSignLiveActivity,
} from '@/services/liveActivity';
import {
  cancelAutoSign as cancelAutoSignTask,
  checkAutoSignScheduled as checkAutoSignScheduledTask,
  scheduleAutoSign as scheduleAutoSignTask,
} from '@/services/sign/BackgroundSignService';
import type { SignProgressItem, SignStatus } from '@/services/sign/signTypes';

// runSignBatch 惰性加载：它静态引 api barrel（sign/mSign→axios 图）与
// forumFollowed（关注列表网络层）。本 ViewModel 经 signStore 被首页
// index.tsx 静态引用，进首帧模块图——runSignBatch 只在用户点签到时才需要。
// eslint-disable-next-line @typescript-eslint/no-require-imports -- 启动热路径裁剪
const lazyRunSignBatch = () =>
  require('@/services/sign/runSignBatch') as typeof import('@/services/sign/runSignBatch');

/**
 * 提取错误消息：兼容 Error 实例、`throw 'str'`（字符串）与
 * `{ message: string }` 对象；不可提取时回退 fallback。
 */
function extractErrorMessage(e: unknown, fallback: string): string {
  if (e instanceof Error) return e.message || fallback;
  if (typeof e === 'string' && e.length > 0) return e;
  if (e !== null && typeof e === 'object' && 'message' in e) {
    const message = (e as { message?: unknown }).message;
    if (typeof message === 'string' && message.length > 0) return message;
  }
  return fallback;
}

export interface SignState {
  isSigning: boolean;
  status: SignStatus;
  totalCount: number;
  successCount: number;
  failCount: number;
  currentIndex: number;
  totalExp: number;
  progressList: SignProgressItem[];
  error: string | null;
  isCancelled: boolean;
  _notifId: string | null;
  _liveActivityId: string | null;

  startSign(): Promise<void>;
  cancelSign(): void;
  reset(): void;
  scheduleAutoSign(time: string): Promise<void>;
  cancelAutoSign(): Promise<void>;
  checkAutoSignScheduled(): Promise<boolean>;
}

export function createSignViewModel(): UseBoundStore<StoreApi<SignState>> {
  return create<SignState>((set, get) => {
    async function finishSign(
      cancelled: boolean,
      liveActivityId: string | null,
      progressNotifId: string | null,
    ): Promise<void> {
      const state = get();

      if (liveActivityId) {
        await finishSignLiveActivity(liveActivityId, {
          success: state.successCount,
          fail: state.failCount,
          exp: state.totalExp,
          phase: cancelled ? 'cancelled' : 'completed',
        });
      }

      if (progressNotifId) {
        try {
          await Notifications.dismissNotificationAsync(progressNotifId);
        } catch {}
      }

      set({
        status: 'completed',
        isSigning: false,
        _liveActivityId: null,
        _notifId: null,
      });

      if (state.failCount === 0 && state.successCount > 0) {
        await hapticForScene('action-success');
      } else if (state.successCount > 0) {
        await hapticForScene('action-warning');
      } else {
        await hapticForScene('action-fail');
      }

      if (state.successCount > 0 || state.failCount > 0) {
        // 前台一键签到：结果用 app 内 toast 提示、不再弹系统通知横幅
        //（用户要求"弹出来的通知也应当是 toast"；后台自动签到仍走
        // sendSignCompleteNotification 系统通知，见 BackgroundSignService）。
        const body =
          state.failCount > 0
            ? `成功 ${state.successCount} 个吧，失败 ${state.failCount} 个，+${state.totalExp} 经验`
            : `成功签到 ${state.successCount} 个吧，+${state.totalExp} 经验`;
        showToast(body);
      }

      try {
        // markForumSigned 已同时更新 followedForums 的 isSign 位，
        // 不再做第二遍 map + setState 全量覆盖（避免与并发写入竞争）。
        const forumStore = useForumStore.getState();
        const progressList = state.progressList;
        let signedIds = 0;
        for (const progress of progressList) {
          if (progress.status === 'success') {
            forumStore.markForumSigned(progress.forumId, progress.exp ?? 0);
            signedIds++;
          }
        }
        // 关注页勾号权威保证（2026-08-28 真机：签到成功但关注页无勾号）——
        // markForumSigned 只更新已挂载的内存列表；列表未加载/磁盘缓存态下
        // 匹配空转。签到完成后失效磁盘缓存并强制重拉服务端（forumGuide
        // is_sign=今天已签），关注列表整体与服务端对齐。
        if (signedIds > 0) {
          // 失效关注列表磁盘缓存（同 forumStore.followForum 契约），
          // 再强制重拉服务端权威数据
          require('@/services/forumFollowed')
            .invalidateFollowedForumsCache?.();
          void forumStore.loadFollowedForums();
        }
        if (__DEV__) console.warn(`[store] markSigned matched=${signedIds}`);
      } catch {
        // Forum store may not be loaded - that's fine
      }
    }

    return {
      isSigning: false,
      status: 'idle',
      totalCount: 0,
      successCount: 0,
      failCount: 0,
      currentIndex: 0,
      totalExp: 0,
      progressList: [],
      error: null,
      isCancelled: false,
      _notifId: null,
      _liveActivityId: null,

      startSign: async () => {
        if (get().isSigning) return;

        set({
          isSigning: true,
          status: 'loading',
          isCancelled: false,
          successCount: 0,
          failCount: 0,
          currentIndex: 0,
          totalExp: 0,
          progressList: [],
          error: null,
          _liveActivityId: null,
          _notifId: null,
        });

        try {
          const account = useAuthStore.getState().account;
          if (!account || !account.tbs) {
            set({
              status: 'error',
              error: '未登录或登录信息已过期，请重新登录',
              isSigning: false,
            });
            return;
          }

          const tbs = account.tbs;
          setTbsSync(tbs, account.uid);
          syncBackgroundSnapshot();

          // 显示位置二选一（设置项）：灵动岛 Live Activity / 通知栏横幅。
          const prefs = usePreferencesStore.getState().preferences;
          const useIsland = prefs.signDisplayMode !== 'notification' && prefs.liveActivitySignEnabled;
          const useBanner = prefs.signDisplayMode === 'notification';
          const silent = prefs.signSilent ?? false;

          const { runSignBatch } = lazyRunSignBatch();
          const result = await runSignBatch({
            tbs,
            shouldCancel: () => get().isCancelled,
            onProgress: async (snapshot) => {
              set({
                status: 'signing',
                totalCount: snapshot.totalCount,
                successCount: snapshot.successCount,
                failCount: snapshot.failCount,
                currentIndex: snapshot.currentIndex,
                totalExp: snapshot.totalExp,
                progressList: snapshot.progressList,
              });
            },
            progressNotif: useBanner
              ? {
                  start: async (total) => {
                    const notifId = `sign-progress-${Date.now()}`;
                    if (await ensureNotificationPermissionAsync(false)) {
                      try {
                        await Notifications.scheduleNotificationAsync({
                          identifier: notifId,
                          content: {
                            title: '正在签到',
                            body: `0 / ${total} 个吧`,
                            sound: undefined,
                            badge: 0,
                            interruptionLevel: silent ? 'passive' : 'active',
                            data: { type: 'sign_progress' },
                          },
                          trigger: null,
                        });
                        set({ _notifId: notifId });
                        return notifId;
                      } catch {}
                    }
                    return null;
                  },
                  update: async (notifId, done, total) => {
                    if (!notifId) return;
                    if (!(await ensureNotificationPermissionAsync(false))) return;
                    try {
                      await Notifications.dismissNotificationAsync(notifId);
                      await Notifications.scheduleNotificationAsync({
                        identifier: notifId,
                        content: {
                          title: '正在签到',
                          body: `${done} / ${total} 个吧`,
                          sound: undefined,
                          badge: 0,
                          interruptionLevel: silent ? 'passive' : 'active',
                          data: { type: 'sign_progress' },
                        },
                        trigger: null,
                      });
                    } catch {}
                  },
                }
              : undefined,
            liveActivity: useIsland
              ? {
                  start: async (total) => {
                    const id = await startSignLiveActivity({
                      done: 0,
                      total,
                      currentForumName: '',
                      success: 0,
                      fail: 0,
                      exp: 0,
                    });
                    set({ _liveActivityId: id });
                    return id;
                  },
                  update: async (id, snapshot) => {
                    await updateSignLiveActivity(
                      id,
                      {
                        done: snapshot.successCount + snapshot.failCount,
                        total: snapshot.totalCount,
                        currentForumName: snapshot.currentForumName,
                        success: snapshot.successCount,
                        fail: snapshot.failCount,
                        exp: snapshot.totalExp,
                      },
                      false,
                    );
                  },
                }
              : undefined,
          });

          if (result.allAlreadySigned || result.noSignable) {
            // 对齐 Kotlin OKSignService.onFinish：total==0 时区分
            // text_oksign_no_signable（没有可签到的吧）与全部已签。
            const body = result.noSignable
              ? '没有可签到的吧'
              : '今天所有吧都已签到过了';
            if (await ensureNotificationPermissionAsync(false)) {
              await Notifications.scheduleNotificationAsync({
                content: {
                  title: '一键签到',
                  body,
                  sound: usePreferencesStore.getState().preferences.signSilent ? undefined : 'default',
                  interruptionLevel: usePreferencesStore.getState().preferences.signSilent ? 'passive' : 'active',
                },
                trigger: null,
              });
            }
            await Notifications.setBadgeCountAsync(0);
            await hapticForScene('action-success');
            set({
              status: 'completed',
              isSigning: false,
              totalCount: 0,
              successCount: 0,
              failCount: 0,
              _liveActivityId: null,
              _notifId: null,
            });
            return;
          }

          await finishSign(result.cancelled, result.liveActivityId, result.progressNotifId);
        } catch (e: unknown) {
          const liveActivityId = get()._liveActivityId;
          if (liveActivityId) {
            await finishSignLiveActivity(liveActivityId, {
              success: get().successCount,
              fail: get().failCount,
              exp: get().totalExp,
              phase: 'error',
            });
          }
          const notifId = get()._notifId;
          if (notifId) {
            try {
              await Notifications.dismissNotificationAsync(notifId);
            } catch {}
          }
          set({
            status: 'error',
            error: extractErrorMessage(e, '签到过程中出现未知错误'),
            isSigning: false,
            _liveActivityId: null,
            _notifId: null,
          });
        }
      },

      cancelSign: () => {
        set({ isCancelled: true });
      },

      reset: () => {
        set({
          isSigning: false,
          status: 'idle',
          totalCount: 0,
          successCount: 0,
          failCount: 0,
          currentIndex: 0,
          totalExp: 0,
          progressList: [],
          error: null,
          isCancelled: false,
          _notifId: null,
          _liveActivityId: null,
        });
      },

      scheduleAutoSign: async (time: string) => {
        await scheduleAutoSignTask(time);
      },

      cancelAutoSign: async () => {
        await cancelAutoSignTask();
      },

      checkAutoSignScheduled: async () => {
        return checkAutoSignScheduledTask();
      },
    };
  });
}
