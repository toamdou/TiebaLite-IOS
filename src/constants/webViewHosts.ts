/**
 * WebView 可信域名白名单（thermo 2026-08-26 Z5-C：收敛 login.tsx 与
 * webview.tsx 两份重叠清单为单一出处）。
 *
 * - WEBVIEW_TRUSTED_HOSTS：内置浏览器可内嵌加载的贴吧相关域名。
 * - LOGIN_EXTRA_HOSTS：登录流程额外放行的通行证/静态资源域。
 * 匹配规则：hostname 等于宿或以其为后缀（`.host`）。
 */

export const WEBVIEW_TRUSTED_HOSTS = [
  'tieba.baidu.com',
  'tiebac.baidu.com',
  'static.tieba.baidu.com',
  'tb1.bdstatic.com',
  'passport.baidu.com',
  'wappass.baidu.com',
  'wapp.baidu.com',
] as const;

/** 登录 WebView 在内置浏览器白名单之外额外信任的域名。 */
export const LOGIN_EXTRA_HOSTS = ['tb.himg.baidu.com'] as const;

export const LOGIN_TRUSTED_HOSTS: readonly string[] = [
  ...WEBVIEW_TRUSTED_HOSTS,
  ...LOGIN_EXTRA_HOSTS,
];

export function isTrustedHost(rawUrl: string, hosts: readonly string[]): boolean {
  try {
    const url = new URL(rawUrl);
    return hosts.some(
      (host) => url.hostname === host || url.hostname.endsWith(`.${host}`),
    );
  } catch {
    return false;
  }
}
