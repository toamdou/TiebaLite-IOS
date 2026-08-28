import { create } from 'zustand';

/**
 * 媒体播放互斥 + 离屏暂停总线（帖内视频 / 语音）。
 *
 * - `activate`/`deactivate`：任何媒体开始播放时抢占总线，同一时刻全屏只
 *   播一个。抢占语义为「后激活者胜」——activate 直接覆写 activeKey，
 *   无类型优先级（注释对齐实现；此前写的「视频优先」与实际不符，已修正，
 *   见全量审查 #10）；互斥由各媒体组件监听 activeKey 自行暂停。
 * - `setVisibleKeys`：列表层（LegendList onViewableItemsChanged）报告当前
 *   可视媒体 key 集合；播放中的媒体发现自己不在可视集时自行暂停——
 *   离线停止解码/发声，是 expo-video 57 移除 isVisible prop 后的手动替代。
 * - `visibleKeys === null` 表示列表层尚未接入可见性（如楼中楼页），
 *   此时不强制暂停（视为全部可见）。
 */
interface MediaBusState {
  activeKey: string | null;
  visibleKeys: ReadonlySet<string> | null;
  activate: (key: string) => void;
  deactivate: (key: string) => void;
  setVisibleKeys: (keys: ReadonlySet<string> | null) => void;
}

export const useMediaBus = create<MediaBusState>((set) => ({
  activeKey: null,
  visibleKeys: null,
  activate: (key) => set({ activeKey: key }),
  deactivate: (key) =>
    set((s) => (s.activeKey === key ? { activeKey: null } : s)),
  // 滚动时高频调用：内容相同则返回原 state（同引用），不给订阅者发通知。
  setVisibleKeys: (keys) =>
    set((s) => {
      if (keys === s.visibleKeys) return s;
      const join = (k: ReadonlySet<string> | null) =>
        k == null ? null : [...k].sort().join('|');
      return join(keys) === join(s.visibleKeys) ? s : { visibleKeys: keys };
    }),
}));