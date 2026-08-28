// Minimal event bus used by BlockManager writes and the shared
// block-filter cache so list rows don't each poll unified storage.
export type BlockEventsListener = () => void;

const listeners = new Set<BlockEventsListener>();

export function subscribeBlockEvents(listener: BlockEventsListener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function emitBlockEvents(): void {
  // 逐一 try 保护：单一 listener 抛错不中断其余订阅者
  for (const listener of [...listeners]) {
    try {
      listener();
    } catch (error) {
      console.warn('[blockEvents] listener threw:', error);
    }
  }
}
