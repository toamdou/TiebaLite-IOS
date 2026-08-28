// ============================================================
// TiebaLite RN — Search API Client（nitro-fetch 版）
//
// Mirrors Kotlin HYBRID_TIEBA_API for search endpoints:
//   GET https://tieba.baidu.com/mo/q/search/forum
//   GET https://tieba.baidu.com/mo/q/search/thread
//   GET https://tieba.baidu.com/mo/q/search/user
//
// Critical: BAIDUID cookie is required by tieba.baidu.com.
// Without it the server returns empty results or errors.
//
// Kotlin's CookieInterceptor captures BAIDUID from Set-Cookie headers
// and AddWebCookieInterceptor sends it on subsequent requests.
// We replicate this with persistent storage.
//
// 2026-08-26：axios 实例 → nitro-fetch 传输（client.ts 的 createHttpClient
// 'search' variant：专属头 + includeSearch Cookie + BAIDUID 捕获内置，
// 不检查 tieba 业务错误码，行为对齐旧 searchClient）。对外形状不变
// （searchClient.get(...) → { data, status, headers }），调用点零改动。
// ============================================================

export { searchClient } from './client';