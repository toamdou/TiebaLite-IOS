/**
 * readableError — 「任意抛出值 → 可读文本」全库唯一实现。
 *
 * 收敛此前五处异构副本（thermo 2026-08-26 Z7-A）：
 * - sanitizeError ×3（AuthSecureStorage / NotificationPoller / endpoints/auth）
 * - SignViewModel.extractErrorMessage（额外支持 `throw 'str'` 字符串）
 * - ImageViewer.errorMessageOf（额外探测对象上的 message 字段）
 *
 * 本实现为三者语义的超集：Error.message → 字符串抛出值 → 对象 message 字段
 * → fallback。日志/告警场景传 fallback='操作失败' 类文案；排查场景不传
 * （回退 String(e)，保留原始信息）。
 */
export function readableError(error: unknown, fallback?: string): string {
  if (error instanceof Error) {
    const message = error.message;
    if (message) return message;
  } else if (typeof error === 'string' && error.length > 0) {
    return error;
  } else if (error !== null && typeof error === 'object' && 'message' in error) {
    const message = (error as { message?: unknown }).message;
    if (typeof message === 'string' && message.length > 0) return message;
  }
  return fallback ?? String(error);
}
