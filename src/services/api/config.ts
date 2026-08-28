// ============================================================
// TiebaLite React Native — API Configuration
// Unified configuration, aligned with Kotlin TiebaLite.
//
// Tieba API requires a stable client/device profile across requests.
// ============================================================

import { kvGetSync, kvSetSync } from '@/services/storage/unifiedDb';
import { getBduss, getStoken } from './authState';

// ---------- Base URLs ----------
/** Core Tieba JSON API (old client) */
export const C_TIEBA = 'https://c.tieba.baidu.com/';

/** Tieba protobuf/content API (v12.x official client) */
export const TIEBAC = 'https://tiebac.baidu.com/';

/** Tieba web pages */
export const TIEBA_WEB = 'https://tieba.baidu.com/';

// ---------- API Version — matches Kotlin client versions ----------
export const CLIENT_VERSION = '12.41.7.1';       // V11 / general
// 评估结论：本地接口形态为 v12 protobuf/JSON（scr_w、CommonRequest 等旧格式字段），
// 对齐 aiotieba const.LEGACY_VERSION = "12.64.1.1"（LATEST 22.6.5.1 属新版客户端，
// 签名/参数格式不同，强行对齐会破坏现有接口契约）。
export const CLIENT_VERSION_V12 = '12.64.1.1';   // 对齐 aiotieba LEGACY_VERSION（proto 通道）
/** aiotieba LATEST_VERSION：百度官方客户端现行版本。JSON common 参数与登录
 * 均已实测被服务端要求（旧版本号 110001），统一走此版本。 */
export const AIOTIEBA_VERSION = '22.6.5.1';
export const CLIENT_TYPE = '2'; // Tieba API client type used by this protocol

// ---------- Common Headers ----------
export const COMMON_HEADERS: Record<string, string> = {
  // UA 与 _client_version 同版本（8-28）：此前 UA=tieba/12.41.7.1 而
  // _client_version=22.6.5.1，版本不一致=非真实客户端组合，opAgree 等
  // 高风控接口的 3280004 候选差异；aiotieba 通道即 tieba/{version} 形态。
  'User-Agent': `tieba/${AIOTIEBA_VERSION}`,
  'Accept-Language': 'zh-CN,zh;q=0.9',
  Accept: 'application/json',
  'Accept-Encoding': 'gzip, deflate',
  Connection: 'keep-alive',
  Charset: 'UTF-8',
};

// ---------- Device Info ----------
const API_DEVICE_MODEL = 'SM-G9910';
const API_DEVICE_BRAND = 'samsung';
const API_OS_VERSION = '31';

/** Get the stable device model used for Tieba API requests. */
export function getDeviceModel(): string {
  return API_DEVICE_MODEL;
}

/** Get the stable device brand used for Tieba API requests. */
export function getDeviceBrand(): string {
  return API_DEVICE_BRAND;
}

/** Get the stable OS version used for Tieba API requests. */
export function getOsVersion(): string {
  return API_OS_VERSION;
}

// ---------- Client ID Generation ----------
export function generateClientId(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

let _clientId: string | null = null;
export function getClientId(): string {
  if (!_clientId) {
    _clientId = kvGetSync('@tiebalite:client_id');
    if (!_clientId) {
      _clientId = generateClientId();
      kvSetSync('@tiebalite:client_id', _clientId);
    }
  }
  return _clientId;
}
export function setClientId(id: string): void {
  _clientId = id;
  kvSetSync('@tiebalite:client_id', id);
}

// ---------- CUID Generation ----------
// 评估结论：cuid 与 _client_id 复用同一 UUID 会增加风控关联。
// cuid 采用贴吧客户端形态 "wappc_<毫秒>_<随机id>"，独立持久化。
export function generateCuid(): string {
  const ms = Date.now();
  const id = Math.floor(Math.random() * 0x7fffffff).toString(16);
  return `wappc_${ms}_${id}`;
}

let _cuid: string | null = null;
export function getCuid(): string {
  if (!_cuid) {
    _cuid = kvGetSync('@tiebalite:cuid');
    if (!_cuid) {
      _cuid = generateCuid();
      kvSetSync('@tiebalite:cuid', _cuid);
    }
  }
  return _cuid;
}
export function setCuid(id: string): void {
  _cuid = id;
  kvSetSync('@tiebalite:cuid', id);
}

// ---------- Common Request Parameters ----------
/**
 * Build standard query/form params sent with every JSON API request.
 * Mirrors Kotlin OFFICIAL_TIEBA_API CommonParamInterceptor chain:
 *   defaultCommonParamInterceptor + CommonParamInterceptor(many)
 *
 * Key: Kotlin timestamp = System.currentTimeMillis() which is MILLISECONDS.
 * Sending seconds causes server-side time-based validation failures.
 */

/** yyyyMdd 形态 event_day（对齐 Kotlin SimpleDateFormat("yyyyMdd")）——单实现，两处共用 */
export function formatEventDay(d: Date = new Date()): string {
  return `${d.getFullYear()}${d.getMonth() + 1}${d.getDate()}`;
}

// ---------- 模拟设备屏幕参数 ----------
// proto 请求 scr_w/scr_h/scr_dip 统一入口（round-54 收敛，proto.ts 内 7 处
// 魔法数统一引用；pbFloor 原 1080×2400@3.0 与其余 6 处不一致，疑似从其它
// 设备模板复制，一并统一；若有真机验证偏差，改这三处常量即可回退）。
export const SCR_W = 1170;   // iPhone 14 Pro 逻辑宽度 @3x
export const SCR_H = 2532;   // iPhone 14 Pro 逻辑高度 @3x
export const SCR_DIP = 3;    // iOS scale factor

export function buildCommonParams(): Record<string, string> {
  const clientId = getClientId();
  const cuid = getCuid();
  const nowMillis = Date.now();

  const params: Record<string, string> = {
    // defaultCommonParamInterceptor (shared by all APIs)
    BDUSS: getBduss() || '',
    _client_id: clientId,
    _client_type: CLIENT_TYPE,
    _os_version: getOsVersion(),
    model: getDeviceModel(),
    net_type: '1',
    _phone_imei: clientId,
    timestamp: nowMillis.toString(),           // MILLISECONDS — Kotlin System.currentTimeMillis()

    // OfficialTiebaApi extra params
    active_timestamp: nowMillis.toString(),
    android_id: '',                              // Tieba API common param
    baiduid: '',                                 // from Server Set-Cookie, empty initially
    brand: getDeviceBrand(),
    c3_aid: cuid,                                // 风控相关字段统一走独立 cuid
    cmode: '1',
    cuid,
    cuid_galaxy2: cuid,
    cuid_gid: '',
    event_day: formatEventDay(),
    extra: '',
    first_install_time: (nowMillis - 86400_000 * 30).toString(),
    framework_ver: '3340042',
    from: 'tieba',
    is_teenager: '0',
    last_update_time: (nowMillis - 86400_000).toString(),
    mac: '02:00:00:00:00:00',
    oaid: '{"id":"","oaid":"","aaid":"","vaid":""}',  // OAID JSON (Kotlin OAID().toJson())
    sample_id: clientId,
    sdk_ver: '2.34.0',
    start_scheme: '',
    start_type: '1',
    naws_game_ver: '1038000',              // 对齐权威仓库 tag 44 字段命名
    _client_version: AIOTIEBA_VERSION,     // 2026-08-27：旧 12.41.7.1 被服务端实测拒绝（110001）
    // V12-specific params (Kotlin OFFICIAL_PROTOBUF_TIEBA_V12_API CommonParamInterceptor)
    personalized_rec_switch: '1',
    z_id: '',
    device_score: '50',
  };

  // Auth
  const stoken = getStoken();
  if (stoken) params.stoken = stoken;

  return params;
}

// ---------- Common params for protobuf requests (form body) ----------
/**
 * Build CommonRequest object for embedding inside protobuf data.
 * Mirrors Kotlin buildCommonRequest() in ProtobufRequest.kt.
 *
 * round-54：v11 分支（buildProtoCommonRequest('v11')）零调用删除 —— protoClient
 * 22 个调用点全 v12；签名收敛为无参。
 */
export function buildProtoCommonRequest(): Record<string, unknown> {
  const clientId = getClientId();
  const cuid = getCuid();
  const nowMillis = Date.now();              // 毫秒 — 对齐 Kotlin System.currentTimeMillis()
  const model = getDeviceModel();
  const bduss = getBduss() || '';
  const stoken = getStoken() || '';

  // Shared fields — MUST use camelCase names (protobufjs JSON descriptor convention)
  const base: Record<string, unknown> = {
    _clientType: 2,
    _clientVersion: CLIENT_VERSION_V12,
    _clientId: clientId,
    _phoneImei: clientId,
    cuid,                                    // 独立 cuid（wappc_ 形态）
    _timestamp: nowMillis,              // Kotlin System.currentTimeMillis() — 毫秒
    model,
    BDUSS: bduss,
    netType: 1,
    pversion: '1.0.3',
    _osVersion: getOsVersion(),
    brand: getDeviceBrand(),
    legoLibVersion: '3.0.0',
    stoken,
    cuidGalaxy2: cuid,
    cuidGid: '',
    oaid: '',
    c3Aid: cuid,
    sampleId: clientId,
    isTeenager: 0,
  };

  return {
    ...base,
    from: '1020031h',                    // Kotlin V12 proto CommonRequest
    activeTimestamp: nowMillis,           // 毫秒 — 对齐 Kotlin
    androidId: '',                        // Tieba API common param
    cmode: 1,
    eventDay: formatEventDay(),
    extra: '',
    firstInstallTime: nowMillis - 86400_000 * 30,  // 毫秒
    frameworkVer: '3340042',
    lastUpdateTime: nowMillis - 86400_000,          // 毫秒
    personalizedRecSwitch: 1,
    qType: 0,
    scrDip: SCR_DIP,
    scrH: SCR_H,
    scrW: SCR_W,
    sdkVer: '2.34.0',
    startScheme: '',
    startType: 1,
    nawsGameVer: '1038000',             // tag 44 — 对齐权威仓库 naws_game_ver
    userAgent: `tieba/${CLIENT_VERSION_V12}`,
    zId: '',
  };
}

// ---------- Cookie Keys ----------
export const COOKIE_KEY_BDUSS = 'BDUSS';
export const COOKIE_KEY_STOKEN = 'STOKEN';
export const COOKIE_KEY_TBS = 'tbs';

// ---------- Signing ----------
export const SIGN_SECRET = 'tiebaclient!!!';

// ---------- Pagination ----------
export const DEFAULT_PAGE_SIZE = 30;
export const FORUM_PAGE_SIZE = 30;

// ---------- Timeout ----------
export const DEFAULT_TIMEOUT = 15000;
export const UPLOAD_TIMEOUT = 60000;
