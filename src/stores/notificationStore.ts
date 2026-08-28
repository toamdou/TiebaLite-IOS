// ============================================================
// notificationStore — 对齐 Kotlin NewTiebaApi
//
// Kotlin:
//   msg():      POST /c/s/msg {bookmark=1}           — 通知数统计
//   replyMe():  POST /c/u/feed/replyme {pn}           — 回复我的
//   atMe():     POST /c/u/feed/atme {pn}              — @我的
//   agreeMe():  POST /c/u/feed/agreeme {pn}           — 赞我的
//
// 全部需要登录 (FORCE_LOGIN: true)
// ============================================================

import { create } from 'zustand';
import type { NotificationCount } from '@/types';

export interface NotificationState {
  counts: NotificationCount;
  activeTab: 'reply' | 'at' | 'agree';

  /**
   * 拉取最新通知计数。成功返回 counts 并写入 store；失败返回 null（counts
   * 保持旧值）——调用方据此决定是否重置通知基线：加载失败时基线不动，
   * 避免服务端偶发失败把基线清零造成重复提醒。
   */
  loadNotificationCounts(): Promise<NotificationCount | null>;
  setActiveTab(tab: 'reply' | 'at' | 'agree'): void;
}

const INITIAL_COUNTS: NotificationCount = { reply: 0, at: 0, agree: 0, total: 0 };

export const useNotificationStore = create<NotificationState>((set) => ({
  counts: { ...INITIAL_COUNTS },
  activeTab: 'reply',

  loadNotificationCounts: async () => {
    try {
      // 调用点惰性加载：本 store 经 (tabs)/_layout 进首帧模块图，静态引
      // api barrel 会把 nitro-fetch+protobufjs 端点图拖进冷启动 TTI。
      // eslint-disable-next-line @typescript-eslint/no-require-imports -- 启动热路径裁剪
      const { msg } = require('@/services/api') as typeof import('@/services/api');
      const counts = await msg();
      set({ counts });
      return counts;
    } catch (error) {
      console.error('[NotificationStore] Failed to load counts:', error);
      return null;
    }
  },

  setActiveTab: (tab: 'reply' | 'at' | 'agree') => {
    set({ activeTab: tab });
  },
}));