/**
 * releaseService — 检查更新：拉取 GitHub Releases 的 latest。
 *
 * 安全约束（发请求前一律校验）：只允许 https；host 必须命中白名单
 * （GitHub），并显式拒绝 localhost / 回环 / 私有 / 保留地址——避免任何
 * 情况下被指向本机或内网服务。
 */

import Constants from 'expo-constants';
import { APP_VERSION } from '@/constants/app';

/** 仓库 Releases API（latest） */
const RELEASES_LATEST_API = 'https://api.github.com/repos/toamdou/TiebaLite-IOS/releases/latest';
/** 仓库 Releases 的 atom feed（API 限流时的兜底数据源） */
const RELEASES_ATOM_FEED = 'https://github.com/toamdou/TiebaLite-IOS/releases.atom';
/** 仓库 Releases 页面（打不开 html_url 时的兜底跳转目标） */
export const RELEASES_PAGE_URL = 'https://github.com/toamdou/TiebaLite-IOS/releases';

const ALLOWED_HOSTS = new Set(['api.github.com', 'github.com', 'www.github.com']);

/** localhost / 回环 / 私有 / 保留地址（IPv4 字面量 + 常见内网域名后缀 + IPv6 字面量） */
function isPrivateOrReservedHost(host: string): boolean {
  const h = host.toLowerCase().replace(/^\[|\]$/g, '');
  if (
    h === 'localhost' ||
    h === '0.0.0.0' ||
    h.endsWith('.localhost') ||
    h.endsWith('.local') ||
    h.endsWith('.internal') ||
    h.endsWith('.home.arpa')
  ) {
    return true;
  }
  if (h === '::1' || h === '::' || h.startsWith('fe80:') || h.startsWith('fc') || h.startsWith('fd')) {
    return true;
  }
  const v4 = h.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (v4) {
    const a = Number(v4[1]);
    const b = Number(v4[2]);
    if (a === 0 || a === 10 || a === 127) return true;
    if (a === 169 && b === 254) return true; // link-local
    if (a === 172 && b >= 16 && b <= 31) return true;
    if (a === 192 && b === 168) return true;
    if (a === 100 && b >= 64 && b <= 127) return true; // CGNAT
    if (a === 198 && (b === 18 || b === 19)) return true; // benchmarking
    if (a >= 224) return true; // multicast / reserved
  }
  return false;
}

/** 校验 URL 可安全访问（https + GitHub 白名单 + 非私网），返回规范化 URL */
export function assertAllowedReleaseUrl(raw: string): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error('更新地址无效');
  }
  if (url.protocol !== 'https:') throw new Error('更新地址仅允许 https');
  const host = url.hostname.toLowerCase();
  if (isPrivateOrReservedHost(host)) throw new Error(`更新地址指向内网/本机（${host}）`);
  if (!ALLOWED_HOSTS.has(host)) throw new Error(`更新地址 host 不在白名单（${host}）`);
  return url;
}

export interface ReleaseInfo {
  /** tag 去掉前缀 v 的版本号 */
  version: string;
  tag: string;
  name: string;
  /** Release 说明（用户写的日志，markdown 原文） */
  notes: string;
  publishedAt: string | null;
  /** Release 页面地址（已校验） */
  url: string;
  prerelease: boolean;
}

/** 当前应用版本（expo 配置里的 version 优先，回退常量） */
export function currentAppVersion(): string {
  const raw = Constants.expoConfig?.version ?? APP_VERSION;
  return String(raw).replace(/^v/i, '');
}

/** a 是否比 b 新（按数字段比较；预发布后缀视为不大于同号正式版） */
export function isNewerVersion(a: string, b: string): boolean {
  const seg = (v: string) =>
    v
      .replace(/^v/i, '')
      .split(/[.+\-]/)
      .map((p) => parseInt(p, 10))
      .map((n) => (Number.isFinite(n) ? n : 0));
  const [x, y] = [seg(a), seg(b)];
  const len = Math.max(x.length, y.length);
  for (let i = 0; i < len; i += 1) {
    const [xi, yi] = [x[i] ?? 0, y[i] ?? 0];
    if (xi !== yi) return xi > yi;
  }
  return false;
}

/** 校验并回退到仓库 Releases 页面 */
function safePageUrl(raw: string): string {
  try {
    return assertAllowedReleaseUrl(raw || RELEASES_PAGE_URL).toString();
  } catch {
    return RELEASES_PAGE_URL;
  }
}

/** Release 说明（atom 侧是转义过的 HTML）→ 纯文本 */
function htmlToText(escapedHtml: string): string {
  const html = escapedHtml
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&');
  return html
    .replace(/<br\s*\/?>/gi, '\n')
    .replace(/<\/(h[1-6]|p|div|ul|ol)>/gi, '\n')
    .replace(/<\/li>/gi, '\n')
    .replace(/<li[^>]*>/gi, '· ')
    .replace(/<[^>]+>/g, '')
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

/**
 * 走 GitHub API 拿最新 Release（信息最全：预发布标记、原始 markdown 日志）。
 * 未鉴权时受 60 次/小时的 IP 限流约束，失败由 atom 兜底。
 */
async function fetchFromApi(signal?: AbortSignal): Promise<ReleaseInfo> {
  const url = assertAllowedReleaseUrl(RELEASES_LATEST_API);
  const res = await fetch(url.toString(), {
    headers: { Accept: 'application/vnd.github+json' },
    signal,
  });
  if (!res.ok) throw new Error(`GitHub 返回 ${res.status}`);
  const json = (await res.json()) as Record<string, unknown>;
  const tag = typeof json.tag_name === 'string' ? json.tag_name : '';
  return {
    version: (tag || String(json.name ?? '')).replace(/^v/i, ''),
    tag,
    name: typeof json.name === 'string' && json.name ? json.name : tag,
    notes: typeof json.body === 'string' ? json.body.trim() : '',
    publishedAt: typeof json.published_at === 'string' ? json.published_at : null,
    url: safePageUrl(typeof json.html_url === 'string' ? json.html_url : ''),
    prerelease: json.prerelease === true,
  };
}

/** 兜底：Releases 的 atom feed（不打 API，无速率限制） */
async function fetchFromAtom(signal?: AbortSignal): Promise<ReleaseInfo> {
  const url = assertAllowedReleaseUrl(RELEASES_ATOM_FEED);
  const res = await fetch(url.toString(), { headers: { Accept: 'application/atom+xml' }, signal });
  if (!res.ok) throw new Error(`GitHub 返回 ${res.status}`);
  const xml = await res.text();
  const entry = xml.match(/<entry>([\s\S]*?)<\/entry>/)?.[1];
  if (!entry) throw new Error('未找到 Release');
  const text = (re: RegExp) => entry.match(re)?.[1]?.trim() ?? '';
  const tag = text(/<title>([\s\S]*?)<\/title>/);
  const href = entry.match(/<link[^>]*rel="alternate"[^>]*href="([^"]+)"/)?.[1] ?? '';
  return {
    version: tag.replace(/^v/i, ''),
    tag,
    name: tag,
    notes: htmlToText(text(/<content[^>]*>([\s\S]*?)<\/content>/)),
    publishedAt: text(/<updated>([\s\S]*?)<\/updated>/) || null,
    url: safePageUrl(href),
    prerelease: false,
  };
}

/** 拉取最新 Release：API 优先，限流/失败时退回 atom feed */
export async function fetchLatestRelease(signal?: AbortSignal): Promise<ReleaseInfo> {
  try {
    return await fetchFromApi(signal);
  } catch (apiError) {
    try {
      return await fetchFromAtom(signal);
    } catch {
      throw apiError;
    }
  }
}
