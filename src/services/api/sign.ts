// ============================================================
// TiebaLite React Native - Request Signing Utility
// Mirrors the Tieba client SortAndSignInterceptor behavior:
//   1. Sort parameter keys alphabetically
//   2. Concatenate key=value pairs
//   3. Append secret key "tiebaclient!!!"
//   4. MD5 hash the result
// ============================================================

import { TiebaNative } from '../../../modules/tieba-native/src/TiebaNative';
import { SIGN_SECRET } from './config';

// 2026-08-29：MD5 下沉原生（CryptoKit Insecure.MD5，tieba-native md5Hex）。
// 此前顺序：手写 ~200 行纯 JS RFC1321 → `md5` 包（Z6-A）。输出同为 32 位
// 小写 hex，逐字节一致；哈希挪出 JS 线程，滚动中连续请求不再占用 hermes。
const md5 = (input: string): string => TiebaNative.md5Hex(input);

// api/index barrel 继续导出 md5（既有消费面不变）
export { md5 };

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
