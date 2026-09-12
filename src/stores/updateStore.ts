/**
 * updateStore — 检查更新的共享状态（关于页展示 + 启动时自动检测）。
 *
 * 自动检测由设置里的「自动检测更新」开关驱动：启动后调用一次
 * maybeAutoCheck（同一会话内 24h 节流，网络失败静默——不打扰用户）。
 */

import { create } from 'zustand';

import {
  currentAppVersion,
  fetchLatestRelease,
  isNewerVersion,
  type ReleaseInfo,
} from '@/services/update/releaseService';
import { usePreferencesStore } from '@/stores/preferencesStore';

/** 同一会话内自动检测的最小间隔 */
const AUTO_CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000;

interface UpdateState {
  status: 'idle' | 'checking' | 'done' | 'error';
  release: ReleaseInfo | null;
  hasUpdate: boolean;
  /** 当前应用版本（检查时快照，供界面显示） */
  currentVersion: string;
  error: string | null;
  lastCheckedAt: number;
  check: () => Promise<void>;
  maybeAutoCheck: () => void;
}

export const useUpdateStore = create<UpdateState>((set, get) => ({
  status: 'idle',
  release: null,
  hasUpdate: false,
  currentVersion: currentAppVersion(),
  error: null,
  lastCheckedAt: 0,

  check: async () => {
    if (get().status === 'checking') return;
    const currentVersion = currentAppVersion();
    set({ status: 'checking', error: null, currentVersion });
    try {
      const release = await fetchLatestRelease();
      set({
        status: 'done',
        release,
        hasUpdate: isNewerVersion(release.version, currentVersion),
        lastCheckedAt: Date.now(),
      });
    } catch (e) {
      set({
        status: 'error',
        error: e instanceof Error ? e.message : '检查更新失败',
        lastCheckedAt: Date.now(),
      });
    }
  },

  maybeAutoCheck: () => {
    const enabled = usePreferencesStore.getState().preferences.autoCheckUpdate ?? false;
    if (!enabled) return;
    if (Date.now() - get().lastCheckedAt < AUTO_CHECK_INTERVAL_MS) return;
    void get().check();
  },
}));
