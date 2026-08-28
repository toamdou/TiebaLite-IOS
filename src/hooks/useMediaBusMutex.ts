/**
 * useMediaBusMutex — 帖内音视频共享的「媒体总线互斥」hook
 * （thermo 2026-08-26 Z2-E：收敛 ActiveVideo / ActiveAudio 两份同构样板）。
 *
 * 语义（与拆分前逐行为一致）：
 * - activate()/deactivate()：挂载/卸载时把 myKey 注册为总线活动媒体；
 * - 订阅总线：被其他媒体抢占（activeKey !== myKey）或自身滚出可视区
 *   （visibleKeys 存在且不含 myKey）时调用 onPause 暂停播放器。
 */
import { useEffect } from 'react';
import { useMediaBus } from '@/stores/mediaBusStore';

export function useMediaBusMutex(
  myKey: string,
  onPause: () => void,
): { activate: () => void; deactivate: () => void } {
  const activeKey = useMediaBus((s) => s.activeKey);
  const visibleKeys = useMediaBus((s) => s.visibleKeys);

  useEffect(() => {
    if (activeKey !== myKey || (visibleKeys != null && !visibleKeys.has(myKey))) {
      onPause();
    }
    // onPause 由调用方以稳定回调传入（内部只触 player.pause()）
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeKey, myKey, visibleKeys]);

  return {
    activate: () => useMediaBus.getState().activate(myKey),
    deactivate: () => useMediaBus.getState().deactivate(myKey),
  };
}
