import { apiRawTiebacPost } from '../client';
import { TiebaApiError } from '../interceptors';
import { assertProtoSuccess } from './helpers';
import { protoGetUserInfo } from '../protoClient';
import { setTbs, getBduss, getUid } from '../authState';
import { AIOTIEBA_VERSION, SIGN_SECRET } from '../config';
import type { UserInfo } from '@/types';
import md5 from 'md5';
// ============================================================
// Auth — 登录 wire 对齐 aiotieba（Starry-OvO/aiotieba，当前每天被大量
//   用户使用的第三方参考实现，与百度官方客户端同构）
// ============================================================
// 关键事实（2026-08-27 逐字节对照 aiotieba api/login/_api.py）：
//   login:    POST https://tiebac.baidu.com/c/s/login
//             body = _client_version=22.6.5.1 & bdusstoken=<RAW BDUSS> & sign
//             sign  = md5(sorted 键值对逐个 "k=v" **无分隔符**拼接 + "tiebaclient!!!")
//             无 stoken/channel/authsid，无 Cookie 头，无 common/st 参数
//   tbs:      login 响应顶层 anti.tbs 直接可得（aiotieba 无独立 tbs 接口）
//   用户信息: proto getUserInfo（tiebac 通路，登录后真实 uid）
//
// 已证伪路径（一律不重试，避免无谓请求与封号风险）：
//   - c.tieba 主机（Kotlin RetrofitTiebaApi JSON 线）：110001/空 200，主机已废
//   - Kotlin 无签名 wire：110001（签名仍被服务端要求）
//   - /c/s/u：接口已废（空 200）
// （RN signParams 的 join('&') 已同日修正为无分隔符——signed 变体另见 sign.ts。）

/**
 * /c/s/login 响应：成功时顶层扁平 {error_code:"0", user{...}, anti{tbs}}；
 * 宽容兼容 {data:{...}} 嵌套形态。
 */
type LoginBeanLike = {
  error_code?: number | string;
  code?: number;
  user?: UserShape;
  anti?: { tbs?: string };
  data?: { user?: UserShape; anti?: { tbs?: string }; tbs?: string };
};

/** /c/s/login 与 proto 共用的用户形状（宽容多键读取）。 */
type UserShape = {
  uid?: string | number;
  id?: string | number;
  user_id?: string | number;
  name?: string;
  name_show?: string;
  portrait?: string;
};

/** 登录后拉取账号信息（login.tsx 调用；2026-08-27 按 aiotieba 同构重写）。 */
export interface NativeAccountData {
  uid: string;
  name: string;
  nameShow: string;
  portrait: string;
  tbs: string;
}

/**
 * aiotieba compute_sign 同构：sorted(pairs) 逐个 "k=v" **无分隔符**拼接 + salt → md5 hex。
 * （RN 既有 signParams 的 join('&') 与服务端不符，拼接差异直接算错 sign。）
 */
function aiotiebaSign(pairs: Array<[string, string]>): string {
  const sorted = [...pairs].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
  let input = '';
  for (const [key, val] of sorted) input += `${key}=${val}`;
  return md5(input + SIGN_SECRET);
}

/** aiotieba 登录表单：_client_version + bdusstoken(RAW，无 |null) + sign。 */
function tiebacLoginForm(bduss: string): string {
  const pairs: Array<[string, string]> = [
    ['_client_version', AIOTIEBA_VERSION],
    ['bdusstoken', bduss],
  ];
  const encoded = pairs.map(([k, v]) => `${k}=${encodeURIComponent(v)}`);
  return `${encoded.join('&')}&sign=${aiotiebaSign(pairs)}`;
}

/** 登录请求头：仅 Content-Type + UA（aiotieba 零 Cookie；UA 不参与鉴权）。 */
function tiebacLoginHeaders(): Record<string, string> {
  return {
    'Content-Type': 'application/x-www-form-urlencoded',
    'User-Agent': `bdtb for Android ${AIOTIEBA_VERSION}`,
  };
}

/** aiotieba 成败判据：顶层 error_code 非 "0" 即失败；字段缺视为成功。 */
function isApiError(body: { code?: number; error_code?: number | string }): boolean {
  const { code, error_code } = body;
  return (error_code != null && String(error_code) !== '0') || (code != null && code !== 0);
}

/** 开发期诊断：登录失败时落完整响应体（响应不含 BDUSS，无泄密）。 */
function logLoginBody(tag: string, body: unknown): void {
  if (!__DEV__) return;
  let dump: string;
  try {
    dump = JSON.stringify(body);
  } catch {
    dump = String(body);
  }
  console.warn(`[login][${tag}] body=${dump}`);
}

/** 响应体摘要（≤160 字符）：进错误消息，让一次失败在 UI 上自成诊断。 */
function excerpt(body: unknown, max = 160): string {
  if (body == null) return '';
  try {
    const s = JSON.stringify(body);
    return s.length > max ? s.slice(0, max) + '…' : s;
  } catch {
    return String(body);
  }
}

/** 错误描述（TiebaApiError 携带服务端响应体 rawData 时附摘要）。 */
function describeError(e: unknown): string {
  if (e instanceof TiebaApiError) {
    const body = e.rawData;
    return body ? `${e.message} body=${excerpt(body)}` : e.message;
  }
  return e instanceof Error ? e.message : String(e);
}

export async function fetchAccountLogin(bduss: string, sToken: string): Promise<NativeAccountData> {
  // 唯一主路径：POST https://tiebac.baidu.com/c/s/login（aiotieba 同构）。
  // 旧路径（c.tieba 主机、Kotlin 无签名 wire、/c/s/u）均已被服务端实测
  // 拒绝，概不重试——失败即带响应体摘要上报，一次尝试即可定位。
  try {
    return await fetchAccountViaLogin(bduss, sToken);
  } catch (e) {
    const msg = describeError(e);
    if (__DEV__) console.warn('[fetchAccountLogin] /c/s/login 失败:', msg);
    throw new Error(`登录接口失败：${msg}`);
  }
}

/** aiotieba login._api 同构：POST tiebac /c/s/login → 顶层 user + anti.tbs。 */
async function fetchAccountViaLogin(bduss: string, _sToken: string): Promise<NativeAccountData> {
  const res = await apiRawTiebacPost<LoginBeanLike>('/c/s/login', tiebacLoginForm(bduss), tiebacLoginHeaders());
  const body = res.data ?? {};
  if (isApiError(body)) {
    logLoginBody('login', body);
    throw new TiebaApiError(`/c/s/login ${body.error_code ?? body.code}`, 0, Number(body.error_code ?? body.code ?? 0), body);
  }
  const user = (body.user ?? body.data?.user ?? {}) as UserShape;
  const uid = String(user.id ?? user.uid ?? user.user_id ?? '');
  if (!uid) {
    logLoginBody('login', body);
    throw new Error('/c/s/login 响应缺少 user.id');
  }
  const tbs = String(body.anti?.tbs ?? body.data?.anti?.tbs ?? body.data?.tbs ?? '');
  return finishAccountData({
    uid,
    name: String(user.name ?? ''),
    portrait: String(user.portrait ?? ''),
    nameShow: '',
    tbs,
  });
}

/**
 * 用当前 BDUSS 调 /c/s/login 获取 anti.tbs（aiotieba 同构：登录响应自带 tbs，
 * 写操作（签到/点赞/发言）的 tbs 来源）。
 */
export async function fetchTbs(): Promise<string> {
  const bduss = getBduss();
  if (!bduss) return '';
  const res = await apiRawTiebacPost<LoginBeanLike>('/c/s/login', tiebacLoginForm(bduss), tiebacLoginHeaders());
  const body = res.data ?? {};
  const tbs = String(body.anti?.tbs ?? body.data?.anti?.tbs ?? body.data?.tbs ?? '');
  if (tbs) {
    setTbs(tbs);
  } else if (__DEV__) {
    console.warn('[fetchTbs] 响应中无 anti.tbs:', body);
  }
  return tbs;
}

/** 公共收尾：tbs 兜底 + proto 增强（真实 uid 查 nameShow/portrait，best-effort）。 */
async function finishAccountData(base: {
  uid: string;
  name: string;
  portrait: string;
  nameShow: string;
  tbs: string;
}): Promise<NativeAccountData> {
  let tbs = base.tbs;
  if (!tbs) {
    tbs = await fetchTbs().catch(() => '');
  }
  let nameShow = base.nameShow || base.name;
  let portrait = base.portrait;
  // proto getUserInfo（tiebac 通路，已验证）：登录后补 nameShow/portrait；
  // 失败沿用 login 响应值，不阻断登录。
  try {
    const decoded = await protoGetUserInfo({ uid: base.uid });
    assertProtoSuccess(decoded);
    const user = (decoded.data?.user ?? {}) as Record<string, any>;
    if (user.nameShow ?? user.name_show) nameShow = String(user.nameShow ?? user.name_show);
    if (user.portrait) portrait = String(user.portrait);
  } catch (e) {
    if (__DEV__) console.warn('[login] proto getUserInfo 增强失败（可忽略）:', describeError(e));
  }
  return { uid: base.uid, name: base.name, nameShow, portrait, tbs };
}

export async function getUserInfo(): Promise<UserInfo> {
  // proto（tiebac 通路）：未登录时 uid=0 会被服务端拒（110001），
  // 登录取真实 uid（finishAccountData 已先补全 nameShow/portrait）。
  const decoded = await protoGetUserInfo({ uid: getUid() || 0 });
  assertProtoSuccess(decoded);
  return (decoded.data?.user ?? {}) as unknown as UserInfo;
}