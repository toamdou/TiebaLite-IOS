// ============================================================
// TiebaLite React Native - API Service Layer
// Barrel export for all API modules.
// ============================================================

// ---------- Configuration ----------
export {
  C_TIEBA,
  TIEBAC,
  TIEBA_WEB,
  CLIENT_VERSION,
  CLIENT_TYPE,
  COMMON_HEADERS,
  SIGN_SECRET,
  getDeviceModel,
  getDeviceBrand,
  generateClientId,
  getClientId,
  setClientId,
  buildCommonParams,
  COOKIE_KEY_BDUSS,
  COOKIE_KEY_STOKEN,
  COOKIE_KEY_TBS,
  DEFAULT_PAGE_SIZE,
  FORUM_PAGE_SIZE,
  DEFAULT_TIMEOUT,
  UPLOAD_TIMEOUT,
  getCuid,
  setCuid,
} from './config';

// ---------- Signing ----------
export { md5, signParams, generateSign } from './sign';

// ---------- Cookies ----------
export { buildCookieHeader } from './cookies';
export type { CookieOptions } from './cookies';

// ---------- Interceptors ----------
// 2026-08-26：axios 拦截器（addCommonHeadersInterceptor /
// addCommonParamsInterceptor / addSignInterceptor / addAuthInterceptor /
// errorInterceptor / networkErrorInterceptor）已随 axios 移除 —— 等价
// 逻辑内置于 client.ts 的 nitro-fetch 传输管道（见 client.ts 文件头）。
// 本组只 re-export 纯错误工具与凭据写入。
export {
  setAuthCredentials,
  clearAuthCredentials,
  describeActionFailure,
  TiebaApiError,
  TiebaErrorCode,
} from './interceptors';

// ---------- Auth State (single source; round-54: 绕过 interceptors 再导出链) ----------
export { getBduss, getStoken } from './authState';

// ---------- Client Instances ----------
export {
  tiebaClient,
  tiebacClient,
  tiebaWebClient,
  uploadClient,
  apiGet,
  apiPost,
  apiGetHybrid,
  apiUpload,
} from './client';

export type { AxiosInstance, AxiosResponse } from './client';

// ---------- API Endpoints (all functions) ----------
export {
  // Auth
  getUserInfo,
  fetchTbs,
  // Forums
  forumGuide,
  forumDetail,
  getForumDetail,
  forumRuleDetail,
  // Threads
  pbPage,
  pbFloor,
  // Posts — 发帖/回复/发图已移除
  delPost,
  delThread,
  // Interactions
  agree,
  disagree,
  likeForum,
  unfavolike,
  followUser,
  unfollowUser,
  // Feed
  personalized,
  userLike,
  hotThreadList,
  topicList,
  // Search
  searchForum,
  searchThread,
  searchUser,
  searchPost,
  // Messages
  msg,
  replyMe,
  atMe,
  agreeMe,
  getMoreMsg,
  // Favorites
  threadStore,
  addStore,
  removeStore,
  // Sign-in
  sign,
  mSign,
  // Profile
  profile,
  profileModify,
  uploadPortrait,
  // User Content
  userPost,
  userLikeForum,
  // Misc
  submitDislike,
  checkReportPost,
  topicDetail,
  setUserBlack,
  cancelUserBlack,
  // Social — 粉丝/关注/黑名单/屏蔽吧/吧成员/等级排行/成长任务
  getFans,
  getFollows,
  getBlacklist,
  delBlacklist,
  getDislikeForums,
  getMemberUsers,
  parseMemberUsersHtml,
  getRankUsers,
  parseRankUsersHtml,
  signGrowth,
  assertProtoSuccess,
  postFormAction,
  mapMediaList,
  mapProtoThread,
} from './endpoints';
