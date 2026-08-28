/**
 * Unified Cookie header builder for JSON, search and protobuf clients.
 */

import { getBduss, getStoken, getUid, getZid } from './authState';
import { getCuid, getDeviceModel } from './config';

export interface CookieOptions {
  includeAuth?: boolean;
  includeSearch?: boolean;
  protoVariant?: 'v11' | 'v12';
  baiduId?: string;
}

export function buildCookieHeader(options: CookieOptions = {}): string {
  const bduss = getBduss();
  const stoken = getStoken();
  const uid = getUid();
  const zid = getZid();
  const cuid = getCuid();
  const model = getDeviceModel();
  const parts: string[] = [];

  if (options.protoVariant) {
    if (options.protoVariant === 'v12') {
      // 对齐 Kotlin：Cookie 一律 `name=value` 等号风格（旧版 `ka:open` 冒号
      // 风格是遗留写法，Kotlin 全仓搜不到 `ka:open`）；v12 不挂 BDUSS/STOKEN。
      return `ka=open; CUID=${cuid}; TBBRAND=${model}`;
    }
    return `CUID=${cuid};ka=open;TBBRAND=${model};`;
  }

  if (options.includeSearch) {
    parts.push(
      `CUID=${cuid}`,
      `TBBRAND=${model}`,
      `cuid_galaxy2=${cuid}`,
      'SP_FW_VER=3.340.42',
      'SG_FW_VER=1.38.0',
    );
    if (bduss) parts.push(`BDUSS=${bduss}`);
    if (stoken) parts.push(`STOKEN=${stoken}`);
    parts.push(`BAIDU_WISE_UID=${uid || cuid}`, 'USER_JUMP=-1');
    if (bduss) parts.push(`BDUSS_BFESS=${bduss}`);
    if (options.baiduId) {
      parts.push(`BAIDUID=${options.baiduId}`, `BAIDUID_BFESS=${options.baiduId}`);
    }
    parts.push('mo_originid=2');
    if (zid) parts.push(`BAIDUZID=${zid}`);
    return parts.join('; ');
  }

  if (bduss) parts.push(`BDUSS=${bduss}`);
  if (stoken) parts.push(`STOKEN=${stoken}`);
  return parts.join('; ');
}
