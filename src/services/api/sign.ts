// ============================================================
// TiebaLite React Native - Request Signing Utility
// Mirrors the Tieba client SortAndSignInterceptor behavior:
//   1. Sort parameter keys alphabetically
//   2. Concatenate key=value pairs
//   3. Append secret key "tiebaclient!!!"
//   4. MD5 hash the result
// ============================================================

import md5 from 'md5';
import { SIGN_SECRET } from './config';

// api/index barrel 继续导出 md5（既有消费面不变）
export { md5 };

// thermo 2026-08-26（Z6-A）：此前手写的 ~200 行纯 JS RFC1321 MD5 实现
// 已替换为社区维护的 `md5` 包（同步 API，与下方同步签名链兼容；
// expo-crypto 的 digestStringAsync 为异步，不适用）。输出同为 32 位
// 小写 hex——`md5` 包默认即返回小写 hex，与旧实现逐字节一致。

/**
 * Sort parameter keys alphabetically and return key=value pairs as a string.
 * Follows the Baidu Tieba client's SortAndSignInterceptor behavior.
 *
 * @param params - The request parameters (query or body) to sign.
 * @param secret - The secret key to append before hashing.
 * @returns The MD5 sign hex string (lowercase, 32 chars).
 */
export function signParams(
  params: Record<string, string | number | boolean | undefined>,
  secret: string = SIGN_SECRET
): string {
  // Filter out undefined values and convert all to strings
  const entries: [string, string][] = [];
  for (const [key, value] of Object.entries(params)) {
    if (value !== undefined && value !== null) {
      entries.push([key, String(value)]);
    }
  }

  // Sort by UTF-16 code unit order（round-54：localeCompare 受本地化影响，
  // 与 Kotlin/Java String 默认字节序排序不一致会算出错误 sign）
  entries.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));

  // Build query string: key1=value1key2=value2...（**无分隔符**，2026-08-27 修正：
  // 与 aiotieba compute_sign / 官方 SortAndSignInterceptor 逐字节一致；
  // 旧实现 join('&') 与服务端不符，sign 恒错——登录 110001 根因之一，
  // 三组输入已用 Python 参考实现对照验证）
  const queryString = entries.map(([k, v]) => `${k}=${v}`).join('');

  // Append secret and hash
  const signInput = queryString + secret;

  return md5(signInput).toLowerCase();
}

/**
 * Generate the sign parameter for a set of request params
 * and return the sign key-value pair to append.
 *
 * @param params - Request parameters to sign.
 * @param secret - Optional override secret key.
 * @returns An object { sign: '...' } ready to be merged into query params.
 */
export function generateSign(
  params: Record<string, string | number | boolean | undefined>,
  secret?: string
): { sign: string } {
  return { sign: signParams(params, secret) };
}
