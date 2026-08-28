// ============================================================
// TiebaLite React Native - Error Handling & Shared Interceptor Logic
//
// 2026-08-26：axios 拦截器函数（addCommonHeadersInterceptor /
// addCommonParamsInterceptor / addSignInterceptor / serializeFormBodyInterceptor /
// addAuthInterceptor / errorInterceptor / networkErrorInterceptor）已随
// client.ts 全面迁移到 nitro-fetch 传输层（client.ts 内部同序管道等价重写），
// 本文件收敛为纯错误工具，供 JSON/搜索/protobuf 通道共用。
// ============================================================

// -----------------------------------------------------------
// Cookie / Auth State
// -----------------------------------------------------------

import { setAuthState } from './authState';
import { clearMemoryOnly } from '@/services/storage/AuthSecureStorage';
import { clearBackgroundSnapshot } from '@/services/nativeBackground';

/**
 * Set authentication credentials for subsequent requests.
 * Called after a successful login.
 */
export function setAuthCredentials(bduss: string, sToken: string): void {
  setAuthState(bduss, sToken);
}

/**
 * Clear in-memory auth state only.
 *
 * 2026-08-27：旧实现 clearAuthState → clearAllAuthSync 会把 Keychain
 * 凭据 + SQLite 活跃账号一并删除——任何接口误报 error_code=1 都会导致
 * 用户"永久"未登录（需重新登录）。现仅清内存（本会话请求降级为游客态），
 * 持久数据保留：下次启动 checkAuth 自动恢复登录。
 */
export function clearAuthCredentials(): void {
  clearMemoryOnly();
}

// ============================================================
// Response Error Handling
// ============================================================

/**
 * Tieba API error codes that should trigger specific handling.
 */
export enum TiebaErrorCode {
  /** User not logged in / session expired */
  NOT_LOGIN = 1,
  /** Need verification code */
  NEED_VERIFY = 2,
  /** Post/topic deleted */
  DELETED = 3,
  /** Permission denied / user blocked */
  PERMISSION_DENIED = 4,
  /** Content filtered / blocked */
  CONTENT_FILTERED = 5,
  /** Rate limited */
  RATE_LIMITED = 3250002,
  /** Operation too frequent */
  TOO_FREQUENT = 1101011,
}

/**
 * Custom error class for Tieba API errors.
 */
export class TiebaApiError extends Error {
  code: number;
  errorCode: number;
  rawData: unknown;

  constructor(message: string, code: number, errorCode: number, rawData?: unknown) {
    super(message);
    this.name = 'TiebaApiError';
    this.code = code;
    this.errorCode = errorCode;
    this.rawData = rawData;
  }

  get isAuthError(): boolean {
    return this.code === TiebaErrorCode.NOT_LOGIN;
  }

  get isRateLimited(): boolean {
    return this.errorCode === TiebaErrorCode.RATE_LIMITED ||
           this.errorCode === TiebaErrorCode.TOO_FREQUENT;
  }

  get isDeleted(): boolean {
    return this.code === TiebaErrorCode.DELETED;
  }
}

/**
 * Unified Tieba error detection for JSON responses and protobuf
 * decoded payloads. Returns null when the payload is a success.
 */
export function getTiebaError(data: unknown): TiebaApiError | null {
  if (!data || typeof data !== 'object') return null;

  const obj = data as Record<string, any>;
  const protoError = obj.error && typeof obj.error === 'object' ? obj.error : null;
  const protoErrorCode = protoError?.error_code ?? protoError?.errorCode;
  const rawErrorCode = obj.error_code ?? obj.errno ?? obj.err_code;
  const errorCode = Number(protoErrorCode ?? rawErrorCode ?? 0);

  if (errorCode !== 0) {
    const protoErrorMsg = protoError?.error_msg ?? protoError?.errorMsg;
    const errorMsg =
      obj.error_msg ??
      (typeof obj.error === 'string' ? obj.error : undefined) ??
      obj.msg ??
      protoErrorMsg;
    return new TiebaApiError(
      errorMsg ?? `API error: ${errorCode}`,
      errorCode,
      errorCode,
      data,
    );
  }

  const rawCode = obj.code;
  if (rawCode !== undefined && rawCode !== null) {
    const code = Number(rawCode);
    if (code !== 0 && code !== 1) {
      return new TiebaApiError(
        obj.message ?? obj.msg ?? `API returned code: ${code}`,
        code,
        code,
        data,
      );
    }
  }

  return null;
}

/**
 * Throw a TiebaApiError for any non-success payload. The nitro-fetch
 * transport (client.ts) passes `handleAuth = true`; protobuf/fallback
 * helpers keep the original behavior by leaving auth cleanup to the
 * transport layer.
 */
export function assertSuccessPayload(data: unknown, handleAuth = true): void {
  const error = getTiebaError(data);
  if (!error) return;
  if (handleAuth && error.code === TiebaErrorCode.NOT_LOGIN) {
    handleAuthExpired();
  }
  throw error;
}

/**
 * Session-expired cleanup without importing the store at module load
 * (avoids a circular dependency with the API layer).
 *
 * 导出供 protoClient 等非 nitro 传输通道调用（proto 请求不经过 client.ts
 * 的 response 管道）。
 */
export function handleAuthExpired(): void {
  try {
    clearAuthCredentials();
    clearBackgroundSnapshot();
    // eslint-disable-next-line @typescript-eslint/no-require-imports -- lazy require avoids API→store circular imports.
    const authStore = require('@/stores/authStore').useAuthStore;
    authStore.setState({ isLoggedIn: false, account: null, error: '登录已过期，请重新登录' });
    // eslint-disable-next-line @typescript-eslint/no-require-imports -- lazy require avoids API→poller circular imports.
    const poller = require('@/services/NotificationPoller');
    poller.stopNotificationPoller?.();
    poller.cancelNativeBackgroundSync?.();
  } catch {
    // Best-effort cleanup; the next user action will prompt for login.
  }
}

/**
 * 验证码降级：将验证码/风控错误转为可读错误，供点赞、签到等写操作在出错时
 * 返回可读信息（不做完整验证码 UI）。
 */
export function describeActionFailure(error: unknown): string {
  if (error instanceof TiebaApiError) {
    if (error.isRateLimited) return '操作过于频繁，请稍后再试';
    if (error.code === TiebaErrorCode.NEED_VERIFY) return '需要验证码，当前设备不支持自动验证，请稍后再试';
    if (error.isDeleted) return '内容已被删除';
    if (error.isAuthError) return '登录已过期，请重新登录';
    return error.message || '操作失败，请稍后再试';
  }
  if (error instanceof Error && error.message) return error.message;
  return '操作失败，请稍后再试';
}