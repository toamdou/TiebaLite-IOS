// ============================================================
// TiebaLite React Native — Nitro-Fetch 传输层（全面替换 axios）
//
// 原 axios 四实例 + 拦截器链（common headers → common params →
// auth Cookie → sign → form 序列化 → 响应 tieba 错误码检查 + 限流重试）
// 等价重写为 nitro-fetch（原生 URLSession）上的同序管道：
//
//   buildRequest（拦截器链等价，纯 JS 构造）
//   → rawSend（AbortController 超时 + 外部 signal 联动取消）
//   → 非 2xx 归一 → JSON 解析 → tieba 错误码检查 + 限流指数退避重试
//
// 对外形状保持 axios 兼容：AxiosResponse/AxiosInstance 同名类型，
// 全部调用点统一 res.data / res.headers 解构，零改动。
// 行为对照（原 interceptors.ts，本文件重写，不依赖 axios 生命周期）：
// - POST form：body 合并 common params → 签名 → URL 编码字符串
// - GET：query 合并 common params → 签名 → encodeURIComponent 拼 URL
// - auth Cookie：buildCookieHeader()（BDUSS/STOKEN）
// - 取消（外部 signal）→ TiebaApiError(-1,-1) 'Request cancelled'
// - 超时/网络异常 → TiebaApiError(0,-1) 'Network error: ...'
// - HTTP 403/404/5xx → 专属可读错误
// - 限流（3250002/1101011）→ 500ms→1000ms 退避重试 2 次（重发已烘焙请求）
// - 2xx body tieba 错误码非 0 → NOT_LOGIN 触发 handleAuthExpired，余抛错
//
// 与 axios 的刻意差异（更正确，注释说明）：
// - 不手动发送 Accept-Encoding/Connection（URLSession 自管 gzip 解压与
//   连接复用；protoClient 同款教训：手动 "gzip, deflate" 时服务端按
//   deflate 响应则原生不解压）
// - multipart 上传不手动设 Content-Type（boundary 由原生构造）
// - nitro-fetch 惰性 require：过渡期（NitroFetch pod 未链接进二进制）
//   包 import 即抛 ModuleNotFoundError（createHybridObject('NitroFetch')
//   找不到原生模块），惰性加载 + null 兜底避免拖崩整个 api 层；
//   pod install 后即恢复原生传输。
// ============================================================

import { TiebaApiError, TiebaErrorCode, getTiebaError, handleAuthExpired } from './interceptors';
import {
  buildCommonParams,
  COMMON_HEADERS,
  DEFAULT_TIMEOUT,
  TIEBAC,
  TIEBA_WEB,
  UPLOAD_TIMEOUT,
} from './config';
import { buildCookieHeader } from './cookies';
import { getUidSync } from '@/services/storage/AuthSQLiteStorage';
import { generateSign } from './sign';
import { kvGetSync, kvSetSync } from '@/services/storage/unifiedDb';

// -----------------------------------------------------------
// 兼容类型（原名保留，调用点零改动）
// -----------------------------------------------------------

export interface NitroHttpResponse<T = unknown> {
  data: T;
  status: number;
  statusText: string;
  /** key 已小写化；set-cookie 多值时为 string[] */
  headers: Record<string, string | string[]>;
  config: unknown;
}

/** 兼容别名：语义与原 axios AxiosResponse 相同（调用点统一 res.data 解构） */
export type AxiosResponse<T = any> = NitroHttpResponse<T>;

export interface HttpRequestOptions {
  params?: Record<string, string | number | boolean | undefined>;
  signal?: AbortSignal;
  headers?: Record<string, string>;
}

export interface HttpClient {
  get<T = unknown>(url: string, options?: HttpRequestOptions): Promise<AxiosResponse<T>>;
  post<T = unknown>(
    url: string,
    data?: Record<string, string | number | boolean | undefined> | FormData | string,
    options?: HttpRequestOptions,
  ): Promise<AxiosResponse<T>>;
}

/** 兼容别名：原 axios AxiosInstance 语义 */
export type AxiosInstance = HttpClient;

// -----------------------------------------------------------
// 内部：请求构建（拦截器链等价）
// -----------------------------------------------------------

type ParamRec = Record<string, string | number | boolean | undefined>;

type Variant = 'signed' | 'web' | 'upload' | 'search' | 'raw';

interface BuildArgs {
  baseURL: string;
  path: string;
  method: 'GET' | 'POST';
  variant: Variant;
  timeoutMs: number;
  params?: ParamRec;
  data?: Record<string, string | number | boolean | undefined> | FormData | string;
  headers?: Record<string, string>;
  signal?: AbortSignal;
}

interface BuiltRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
  body?: string | FormData | null;
}

/** k=v 编码（axios buildURL 同款：encodeURIComponent per key/value） */
export function encodeParams(params: ParamRec | undefined): string {
  const parts: string[] = [];
  for (const [k, v] of Object.entries(params ?? {})) {
    if (v === undefined || v === null) continue;
    parts.push(`${encodeURIComponent(k)}=${encodeURIComponent(String(v))}`);
  }
  return parts.join('&');
}

/**
 * 合并 auth 参数 + 签名（2026-08-28 恢复全集）：
 * 8-27 曾简化为「仅 BDUSS/_client_version + sign」，但服务端对 opAgree
 * 等高风险写接口按「真实客户端设备指纹」判定（官方/Kotlin MINI 集群
 * 带 client_id/cuid/timestamp/CUID/ST 上报组全套）；缺指纹的请求命中
 * 风控 3280004「操作太频繁」（官方 App 同账号可赞、我们全部失败）。
 * 现恢复 buildCommonParams 全集 + ST 参数组（对齐 Kotlin StParamInterceptor：
 * 随机 100-850，仅 100..120 段全空）+ 显式业务字段，再统一签名。
 */
function buildStParams(): Record<string, string> {
  const num = Math.floor(Math.random() * 751) + 100; // 100..850，同 Kotlin
  if (num >= 100 && num <= 120) return { stErrorNums: '0' };
  return {
    stErrorNums: '1',
    stMethod: '1',
    stMode: '1',
    stTimesNum: '1',
    stTime: String(num),
    stSize: String(Math.round((Math.random() * 8 + 0.4) * num)),
  };
}

function signedParams(specific: ParamRec | undefined): ParamRec {
  const merged: ParamRec = {
    ...buildCommonParams(),
    ...buildStParams(),
    ...(specific ?? {}),
  };
  merged.sign = generateSign(merged).sign;
  return merged;
}

/** 合并调用点 headers（调用点优先，大小写不敏感覆盖） */
function mergeHeaders(base: Record<string, string>, extra?: Record<string, string>): Record<string, string> {
  const merged: Record<string, string> = { ...base };
  for (const [k, v] of Object.entries(extra ?? {})) {
    const lk = k.toLowerCase();
    for (const mk of Object.keys(merged)) {
      if (mk.toLowerCase() === lk) delete merged[mk];
    }
    merged[k] = v;
  }
  return merged;
}

function hasHeader(headers: Record<string, string>, name: string): boolean {
  const lk = name.toLowerCase();
  return Object.keys(headers).some((k) => k.toLowerCase() === lk);
}

/** 过滤 URLSession 自管头（见文件头注释） */
function dropTransportHeaders(headers: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(headers)) {
    const lk = k.toLowerCase();
    if (lk === 'accept-encoding' || lk === 'connection') continue;
    out[k] = v;
  }
  return out;
}

function buildUrl(baseURL: string, path: string, query?: string): string {
  const base = baseURL.replace(/\/$/, '');
  return query ? `${base}${path}?${query}` : `${base}${path}`;
}

function buildRequest(args: BuildArgs): BuiltRequest {
  if (args.variant === 'search') {
    // 搜索专用链（对齐旧 searchClient request interceptor）
    const keyword = typeof args.params?.word === 'string' ? args.params.word : '';
    const headers: Record<string, string> = {
      'User-Agent': 'tieba/12.35.1.0 skin/default',
      Host: 'tieba.baidu.com',
      Pragma: 'no-cache',
      'Cache-Control': 'no-cache',
      Accept: 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'X-Requested-With': 'com.baidu.tieba',
      'Sec-Fetch-Site': 'same-origin',
      'Sec-Fetch-Mode': 'cors',
      'Sec-Fetch-Dest': 'empty',
      Referer: `https://tieba.baidu.com/mo/q/hybrid/search?keyword=${encodeURIComponent(keyword)}&_webview_time=${Date.now()}`,
      ...(args.headers ?? {}),
    };
    const cookie = buildCookieHeader({ includeSearch: true, baiduId: getBaiduId() });
    if (cookie) headers['Cookie'] = cookie;
    return {
      url: buildUrl(args.baseURL, args.path, encodeParams(args.params)),
      method: args.method,
      headers,
    };
  }

  let headers = dropTransportHeaders(mergeHeaders(COMMON_HEADERS, args.headers));
  const cookie = buildCookieHeader();
  if (cookie && !hasHeader(headers, 'cookie')) headers['Cookie'] = cookie;
  // client_user_token（对齐 Kotlin：addstore/rmstore/opAgree 等写接口统一
  // 带该 header，值为 uid；缺失时服务端回"操作失败"——2026-08-27 真机
  // 收藏按钮报错根因）。
  if (args.variant === 'signed') {
    // force_login: 对齐 Kotlin HttpConstant（FORCE_LOGIN="force_login"、
    // FORCE_LOGIN_TRUE="true"），Kotlin 每个写接口 @Headers 都带；我们此前
    // 全缺。opAgree 3280004「操作太频繁」排查候选差异之一（8-28）。
    if (!hasHeader(headers, 'force-login')) headers['force_login'] = 'true';
    if (!hasHeader(headers, 'client_user_token')) {
      const uid = getUidSync();
      if (uid) headers['client_user_token'] = uid;
    }
  }

  if (args.variant === 'raw') {
    // 裸请求（登录专用）：不注入 common params / sign / auth cookie，
    // headers 与 body 由调用方显式全权——aiotieba login 同构
    // （见 auth.ts fetchAccountLogin 重写注释，2026-08-27 实测生效）。
    return {
      url: buildUrl(args.baseURL, args.path, encodeParams(args.params)),
      method: args.method,
      headers: dropTransportHeaders(args.headers ?? {}),
      body: typeof args.data === 'string' ? args.data : null,
    };
  }

  if (args.variant === 'web' && args.method === 'POST' && args.data && !(args.data instanceof FormData)) {
    // web 表单 POST（forumGuide/msign，对齐 aiotieba pack_web_form_request）：
    // tieba.baidu.com 主机、无 common params / sign，cookie 认证；
    // 旧 C_TIEBA+signed 路径已被服务端实测 110001。
    if (!hasHeader(headers, 'content-type')) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    return {
      url: buildUrl(args.baseURL, args.path, encodeParams(args.params)),
      method: args.method,
      headers,
      body: encodeParams(args.data as ParamRec),
    };
  }

  if (args.variant === 'upload') {
    // multipart：body 直传 FormData，boundary 由原生 URLSession 构造
    return {
      url: buildUrl(args.baseURL, args.path),
      method: args.method,
      headers,
      body: args.data instanceof FormData ? args.data : null,
    };
  }

  if (args.variant === 'signed' && args.method === 'POST' && args.data && !(args.data instanceof FormData)) {
    // form POST：body 合并 common + 签名 + URL 编码（对齐旧拦截器链）
    const signed = signedParams(args.data as ParamRec);
    // 开发期诊断：读合并后的最终表单（2026-08-27 修正——旧日志读调用方
    // 原始 data，BDUSS 是 signedParams 合成字段所以恒显 NO，误导排障）
    if (__DEV__) {
      const q = signed as ParamRec;
      // stoken 带长度与首尾预览（不打印全文，防泄漏）：定位"无效 stoken"
      // 是过期还是存储残缺（2026-08-28 stoken 恢复实验）。
      const stokenBrief = (v?: string) =>
        v ? `${v.length}字符[${v.slice(0, 3)}…${v.slice(-2)}]` : 'NO';
      console.log(
        `[req] POST ${args.path} | uid=${getUidSync() ? 'YES' : 'NO'} | ` +
        `stoken=${stokenBrief(q?.stoken as string)} | tbs=${(q?.tbs as string) ? 'YES' : 'NO'} | ` +
        `BDUSS=${(q?.BDUSS as string) ? 'YES' : 'NO'} | user_token_header=${hasHeader(headers, 'client_user_token') ? 'YES' : 'NO'}`,
      );
    }
    if (!hasHeader(headers, 'content-type')) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    return {
      url: buildUrl(args.baseURL, args.path, encodeParams(args.params)),
      method: args.method,
      headers,
      body: encodeParams(signed),
    };
  }

  // GET / web / signed GET：query（web 无 common 合并与签名）
  const query = args.variant === 'signed'
    ? encodeParams(signedParams(args.params))
    : encodeParams(args.params);
  return {
    url: buildUrl(args.baseURL, args.path, query),
    method: args.method,
    headers,
  };
}

// -----------------------------------------------------------
// 内部：发送 + 错误归一
// -----------------------------------------------------------

// nitro-fetch 惰性加载：过渡期 native 未链接时包 import 即抛，
// 惰性 require + null 兜底避免拖崩 api 层（见文件头注释）。
let nitroFetchFn: ((typeof import('react-native-nitro-fetch'))['fetch']) | null | undefined;
let nitroDiagLogged = false;

function getNitroFetch(): (typeof import('react-native-nitro-fetch'))['fetch'] | null {
  if (nitroFetchFn === undefined) {
    try {
      // eslint-disable-next-line @typescript-eslint/no-require-imports -- 惰性加载（见文件头注释）
      const mod = require('react-native-nitro-fetch') as typeof import('react-native-nitro-fetch');
      nitroFetchFn = mod.fetch ?? null;
    } catch {
      nitroFetchFn = null;
    }
    // 开发期活性诊断：一行确认 nitro 原生传输是否真的在跑（用户反馈"网络慢"，
    // 疑原生未链接走降级；若 native 缺失这里径直 MISSING，所有请求都会失败）
    if (__DEV__ && !nitroDiagLogged) {
      nitroDiagLogged = true;
      console.warn(`[nitro] transport=${typeof nitroFetchFn === 'function' ? 'nitro-fetch OK' : 'MISSING/降级'}`);
    }
  }
  return nitroFetchFn;
}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

type PlainResponseHeaders = Record<string, string | string[]>;

interface RawResponse {
  status: number;
  statusText: string;
  headers: PlainResponseHeaders;
  text: string;
}

function responseHeadersToObject(headers: {
  forEach(cb: (value: string, key: string) => void): void;
  getSetCookie(): string[];
}): PlainResponseHeaders {
  const out: PlainResponseHeaders = {};
  const setCookies = headers.getSetCookie?.() ?? [];
  headers.forEach((value, key) => {
    const lk = key.toLowerCase();
    if (lk === 'set-cookie') {
      out[lk] = setCookies.length > 0 ? setCookies : [value];
    } else {
      out[lk] = value;
    }
  });
  return out;
}

async function rawSend(
  built: BuiltRequest,
  timeoutMs: number,
  externalSignal?: AbortSignal,
): Promise<RawResponse> {
  const send = getNitroFetch();
  if (!send) {
    // nitro-fetch 原生侧未链接（NitroFetch pod 未装）：等同网络不可用
    throw new TiebaApiError(
      'Network error: Unable to reach Tieba servers. Check your connection.',
      0, -1,
    );
  }

  // 超时 + 外部取消：AbortController 联动（nitro-fetch 桥接原生 cancelRequest）
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  let externalAbort: (() => void) | undefined;
  if (externalSignal) {
    if (externalSignal.aborted) {
      clearTimeout(timer);
      throw new TiebaApiError('Request cancelled', -1, -1);
    }
    externalAbort = () => controller.abort();
    externalSignal.addEventListener('abort', externalAbort, { once: true });
  }

  try {
    const startedAt = Date.now();
    const res = await send(built.url, {
      method: built.method,
      headers: built.headers,
      ...(built.body != null ? { body: built.body } : {}),
      signal: controller.signal,
    });
    // 慢请求诊断：>2s 的请求进 Metro，一批日志即可看出卡点是网络、签名
    // 还是特定 endpoint（2026-08-27 用户反馈"网络访问很慢"）。
    const elapsed = Date.now() - startedAt;
    if (__DEV__ && elapsed > 2000) {
      console.warn(`[net] slow ${built.method} ${built.url.split('?')[0]} ${elapsed}ms`);
    }
    const text = await res.text();
    return {
      status: res.status,
      statusText: res.statusText,
      headers: responseHeadersToObject(res.headers),
      text,
    };
  } catch (e: any) {
    // 外部取消 → cancelled；其余（超时/网络/原生异常）→ 与旧
    // networkErrorInterceptor 的 "有 request 无 response" 分支等价
    if (externalSignal?.aborted) {
      throw new TiebaApiError('Request cancelled', -1, -1);
    }
    if (e instanceof TiebaApiError) throw e;
    throw new TiebaApiError(
      'Network error: Unable to reach Tieba servers. Check your connection.',
      0, -1,
    );
  } finally {
    clearTimeout(timer);
    if (externalSignal && externalAbort) {
      externalSignal.removeEventListener('abort', externalAbort);
    }
  }
}

/** HTTP 非 2xx 归一（对齐旧 networkErrorInterceptor 的 error.response 分支） */
function mapHttpError(status: number, statusText: string): TiebaApiError {
  if (status === 403) {
    return new TiebaApiError('Access denied (403). Check BDUSS validity.', 403, 403);
  }
  if (status === 404) {
    return new TiebaApiError('API endpoint not found (404).', 404, 404);
  }
  if (status >= 500) {
    return new TiebaApiError(
      `Tieba server error (${status}). Please try again later.`,
      status,
      0,
    );
  }
  return new TiebaApiError(
    `HTTP ${status}: ${statusText || `Request failed with status code ${status}`}`,
    status,
    0,
  );
}

/** 空 body → ''；JSON 解析失败保留原文（HTML/纯文本响应）—— 对齐 axios 默认 transformResponse */
function parseBody(text: string): unknown {
  if (!text) return '';
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

async function transact<T>(args: BuildArgs): Promise<AxiosResponse<T>> {
  const built = buildRequest(args);
  let attempt = 0;
  for (;;) {
    const raw = await rawSend(built, args.timeoutMs, args.signal);
    if (raw.status < 200 || raw.status >= 300) {
      throw mapHttpError(raw.status, raw.statusText);
    }

    const data = parseBody(raw.text) as T;

    if (args.variant === 'search') {
      // 搜索通道不检查 tieba 业务错误码（对齐旧 searchClient），只捕获 BAIDUID
      captureBaiduId(raw.headers);
      return { data, status: raw.status, statusText: raw.statusText, headers: raw.headers, config: built };
    }

    // tieba 业务错误码（HTTP 常为 200）：限流退避重试 2 次（重发已烘焙请求）
    const tiebaErr = getTiebaError(data);
    if (tiebaErr) {
      if (tiebaErr.isRateLimited && attempt < 2) {
        attempt += 1;
        await sleep(500 * Math.pow(2, attempt - 1)); // 500ms → 1000ms
        continue;
      }
      if (tiebaErr.code === TiebaErrorCode.NOT_LOGIN) {
        // 2026-08-27：触发前打点定位元凶（曾误触发全毁登出，现只温和登出）
        if (__DEV__) {
          const bodySample =
            typeof data === 'object' && data !== null
              ? JSON.stringify((data as { error_msg?: string }).error_msg ?? data).slice(0, 200)
              : String(data).slice(0, 200);
          console.warn(
            `[auth] json NOT_LOGIN 触发（温和登出）: ${built.url} code=${tiebaErr.errorCode} msg=${tiebaErr.message} body=${bodySample}`,
          );
        }
        handleAuthExpired();
      }
      throw tiebaErr;
    }

    return { data, status: raw.status, statusText: raw.statusText, headers: raw.headers, config: built };
  }
}

// -----------------------------------------------------------
// BAIDUID 持久化（对齐旧 searchClient response interceptor）
// -----------------------------------------------------------

const BAIDUID_KEY = '@tiebalite:baiduid';

/** 仅当服务端曾返回过真 BAIDUID 时才返回，否则返回空（对齐 Kotlin：首次请求不带 BAIDUID） */
export function getBaiduId(): string {
  return kvGetSync(BAIDUID_KEY) ?? '';
}

function captureBaiduId(headers: PlainResponseHeaders): void {
  const setCookie = headers['set-cookie'];
  const all = Array.isArray(setCookie) ? setCookie : [setCookie].filter((v): v is string => typeof v === 'string');
  for (const c of all) {
    const match = c.match(/BAIDUID=([^;]+)/i);
    if (match) {
      kvSetSync(BAIDUID_KEY, match[1]);
    }
  }
}

// -----------------------------------------------------------
// 实例（原 axios 实例同形状）
// -----------------------------------------------------------

function createHttpClient(opts: { baseURL: string; timeoutMs: number; variant: Variant }): HttpClient {
  return {
    get<T = unknown>(path: string, options?: HttpRequestOptions): Promise<AxiosResponse<T>> {
      return transact<T>({
        ...opts,
        path,
        method: 'GET',
        params: options?.params,
        headers: options?.headers,
        signal: options?.signal,
      });
    },
    post<T = unknown>(
      path: string,
      data?: Record<string, string | number | boolean | undefined> | FormData | string,
      options?: HttpRequestOptions,
    ): Promise<AxiosResponse<T>> {
      return transact<T>({
        ...opts,
        path,
        method: 'POST',
        data,
        headers: options?.headers,
        signal: options?.signal,
      });
    },
  };
}

/** 核心 JSON API Client（tiebac.baidu.com）—— 完整链（common params + sign + Cookie）。
 *  2026-08-27 主机迁移：c.tieba 已被服务端弃用（110001/空 200 实测），
 *  tiebac 为官方客户端现行主机（登录成功实证）。 */
export const tiebaClient: HttpClient = createHttpClient({ baseURL: TIEBAC, timeoutMs: DEFAULT_TIMEOUT, variant: 'signed' });

/** Hybrid API Client（tiebac.baidu.com）—— 同完整链 */
export const tiebacClient: HttpClient = createHttpClient({ baseURL: TIEBAC, timeoutMs: DEFAULT_TIMEOUT, variant: 'signed' });

/** Web API Client（tieba.baidu.com）—— 仅 common headers + Cookie，无 common params/sign */
export const tiebaWebClient: HttpClient = createHttpClient({ baseURL: TIEBA_WEB, timeoutMs: DEFAULT_TIMEOUT, variant: 'web' });

/** Upload Client —— FormData 直传 + Cookie，长超时（2026-08-27 主机迁移：C_TIEBA 已废） */
export const uploadClient: HttpClient = createHttpClient({ baseURL: TIEBAC, timeoutMs: UPLOAD_TIMEOUT, variant: 'upload' });

/** Search Client（tieba.baidu.com /mo/q/search/*）—— 搜索专用头 + includeSearch Cookie + BAIDUID 捕获 */
export const searchClient: HttpClient = createHttpClient({ baseURL: TIEBA_WEB, timeoutMs: DEFAULT_TIMEOUT, variant: 'search' });

// -----------------------------------------------------------
// Convenience request helpers（签名不变）
// -----------------------------------------------------------

/**
 * GET on the main Tieba API client（signed query）。
 */
export async function apiGet<T = unknown>(
  url: string,
  params?: Record<string, string | number | boolean | undefined>,
  signal?: AbortSignal,
): Promise<AxiosResponse<T>> {
  return tiebaClient.get<T>(url, { params, signal });
}

/**
 * POST on the main Tieba API client. Body object 经 common params + sign
 * 合并后序列化为 URL 编码字符串（对齐旧 serializeFormBodyInterceptor）。
 */
export async function apiPost<T = unknown>(
  url: string,
  data?: Record<string, string | number | boolean | undefined>,
  params?: Record<string, string | number | boolean | undefined>,
  signal?: AbortSignal,
): Promise<AxiosResponse<T>> {
  return tiebaClient.post<T>(url, data ?? {}, {
    params,
    signal,
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
    },
  });
}

/**
 * GET on the Tiebac (hybrid) client（signed query）。
 */
export async function apiGetHybrid<T = unknown>(
  url: string,
  params?: Record<string, string | number | boolean | undefined>,
  signal?: AbortSignal,
): Promise<AxiosResponse<T>> {
  return tiebacClient.get<T>(url, { params, signal });
}

/**
 * GET on the Tieba Web client（tieba.baidu.com）—— 无 common params/sign，
 * 仅 common headers + auth cookie（对齐旧 tiebaWebClient）。
 */
export async function apiGetWeb<T = unknown>(
  url: string,
  params?: Record<string, string | number | boolean | undefined>,
  signal?: AbortSignal,
): Promise<AxiosResponse<T>> {
  return tiebaWebClient.get<T>(url, { params, signal });
}

/**
 * Web 通道表单 POST（tieba.baidu.com，无 common params/sign，cookie 认证）。
 * 对齐 aiotieba pack_web_form_request（Hybrid 接口专用：forumGuide/msign）。
 */
export async function apiWebPost<T = unknown>(
  url: string,
  data: Record<string, string | number | boolean | undefined>,
  headers?: Record<string, string>,
  signal?: AbortSignal,
): Promise<AxiosResponse<T>> {
  return tiebaWebClient.post<T>(url, data, { headers, signal });
}

/** tiebac 主机裸 POST（登录/tbs 唯一通道）：c.tieba 主机已实测被服务端拒绝。
 *  2026-08-27：rawClient/apiRawPost（C_TIEBA 版）已删除（零消费面，死链）。 */
export const rawTiebacClient: HttpClient = createHttpClient({
  baseURL: TIEBAC,
  timeoutMs: DEFAULT_TIMEOUT,
  variant: 'raw',
});

export async function apiRawTiebacPost<T = unknown>(
  url: string,
  body: string,
  headers?: Record<string, string>,
): Promise<AxiosResponse<T>> {
  return rawTiebacClient.post<T>(url, body, { headers });
}

/**
 * POST multipart/form-data upload（FormData 直传，boundary 由原生构造）。
 */
export async function apiUpload<T = unknown>(
  url: string,
  formData: FormData,
  params?: Record<string, string | number | boolean | undefined>,
  signal?: AbortSignal,
): Promise<AxiosResponse<T>> {
  return uploadClient.post<T>(url, formData, { params, signal });
}