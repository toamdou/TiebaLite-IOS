// ============================================================
// TiebaLite RN — Protobuf Multipart API Client
//
// Handles POST requests to tiebac.baidu.com with multipart/form-data
// body containing protobuf-encoded request data.
//
// Mirrors Kotlin:
//   RetrofitTiebaApi.OFFICIAL_PROTOBUF_TIEBA_API (tiebac.baidu.com)
//   buildProtobufRequestBody() → multipart form body
//   CommonParamInterceptor → adds common params to form fields
//   SortAndSignInterceptor → signs form fields
//
// iOS native transport — protobuf encode/decode, multipart and URLSession
// all run inside the TiebaNative module.
// ============================================================

import { TIEBAC, buildProtoCommonRequest, COMMON_HEADERS, getCuid, DEFAULT_TIMEOUT, CLIENT_VERSION_V12 } from './config';
import { buildCookieHeader } from './cookies';
import { TiebaNative } from '../../../modules/tieba-native/src/TiebaNative';
import { getStoken, getUid } from './authState';
import {
  encodeHotThreadListRequest,
  encodeTopicListRequest,
  encodeFrsPageRequest,
  encodePbPageRequest,
  encodePbFloorRequest,
  encodeProfileRequest,
  encodeSearchSugRequest,
  // New APIs
  encodeGetBawuInfoRequest,
  encodeGetMemberInfoRequest,
  encodeForumRuleDetailRequest,
  encodeGeneralTabListRequest,
  encodePersonalizedRequest,
  encodeUserLikeRequest,
  encodeUserPostRequest,
  encodeGetUserInfoRequest,
  encodeGetForumDetailRequest,
  encodeGetDislikeListRequest,
} from './proto';
import type {
  ProtoCommonRequest,
  DecodedHotThreadListResponse,
  DecodedTopicListResponse,
  DecodedFrsPageResponse,
  DecodedPbPageResponse,
  DecodedPbFloorResponse,
  DecodedProfileResponse,
  DecodedSearchSugResponse,
  // New APIs
  DecodedGetBawuInfoResponse,
  DecodedGetMemberInfoResponse,
  DecodedForumRuleDetailResponse,
  DecodedGeneralTabListResponse,
  DecodedPersonalizedResponse,
  DecodedUserLikeResponse,
  DecodedUserPostResponse,
  DecodedGetUserInfoResponse,
  DecodedGetForumDetailResponse,
  DecodedGetDislikeListResponse,
} from './proto';
import { TiebaApiError, TiebaErrorCode, handleAuthExpired } from './interceptors';

// -----------------------------------------------------------
// Generic protobuf POST
// -----------------------------------------------------------

let protoDecoderReady = false;

/**
 * 把 protos.json descriptor 传给 native 注册表，供 native 解码器使用。
 * 编码已移到 JS（protobufjs），但解码仍在 native（protoPost 的
 * TiebaNative.protoPost），没有 descriptor 会抛
 * "Protobuf message not found" 错误。只初始化一次。
 */
function ensureProtoDecoderReady(): void {
  if (protoDecoderReady) return;
  TiebaNative.protoInitialize(
    JSON.stringify(require('./protos.json') as Record<string, unknown>),
  );
  protoDecoderReady = true;
}

/**
 * POST a protobuf-encoded request to the Tieba protobuf API.
 *
 * @param path - API path (e.g., '/c/f/forum/hotThreadList')
 * @param cmd - cmd query param (e.g., '309661')
 * @param protoCommon - CommonRequest for embedding in protobuf data
 * @param encodeFn - Function to encode the specific request protobuf
 */
async function protoPost<T>(
  path: string,
  cmd: string,
  protoCommon: ProtoCommonRequest,
  encodeFn: (common: ProtoCommonRequest) => string,
  responseTypePath: string,
  opts?: {
    extraHeaders?: Record<string, string>;
    signal?: AbortSignal;
  },
): Promise<T> {
  // round-54：v11 分支删除（22 个调用点全 v12）；native 侧 protoPost 的
  // isV12 形参保持 true 常量，不改变原生行为。
  const isV12 = true;

  // 解码仍在 native 完成，需要把 protos.json descriptor 传入 native 注册表
  // （proto.ts 的 JS 编码不再调用 protoInitialize，这里补上，确保解码可用）
  ensureProtoDecoderReady();

  // 1. Build form fields — V12 通道（OFFICIAL_PROTOBUF_TIEBA_V12_API）：
  //    Form body 只含 buildProtobufRequestBody() 添加的内容（无 common 参数、
  //    无 sign）。服务器要求 multipart 至少 1 个 form 字段，故恒带 stoken
  //    （Kotlin 即使 needSToken=false 也如此处理；needSToken 参数已随 v11 删除）。
  const formFields: [string, string][] = [];
  const stoken = getStoken();
  if (stoken) formFields.push(['stoken', stoken]);

  // 2. Encode the request protobuf data (native codec)
  const protoData = encodeFn(protoCommon);

  const uid = getUid();
  const cookieStr = buildCookieHeader({ protoVariant: 'v12' });

  // 6. Send POST request matching Kotlin OFFICIAL_PROTOBUF_TIEBA_V12_API headers
  //    Kotlin V12: CLIENT_TYPE header IS included ("2")
  //    User-Agent: getUserAgent("tieba/12.52.1.0") = browser UA + " tieba/12.52.1.0"
  const url = `${TIEBAC.replace(/\/$/, '')}${path}?cmd=${cmd}`;
  // Tieba API protocol uses these client UA strings; keep them stable for server-side compatibility.
  const v12UserAgent = `Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/135.0.0.0 Mobile Safari/537.36 tieba/${CLIENT_VERSION_V12}`;
  const headers: Record<string, string> = {
    'User-Agent': v12UserAgent,
    'Accept-Language': COMMON_HEADERS['Accept-Language'] ?? 'zh-CN,zh;q=0.9',
    'x_bd_data_type': 'protobuf',
    Charset: 'UTF-8',
    client_user_token: uid || '',
    Cookie: cookieStr,
    cuid: getCuid(),
    cuid_galaxy2: getCuid(),
    cuid_gid: '',
    cuid_galaxy3: getCuid(),
    c3_aid: getCuid(),
    client_type: '2',
  };

  // Merge per-request extra headers (e.g. forum_name for frsPage)
  if (opts?.extraHeaders) {
    Object.assign(headers, opts.extraHeaders);
  }

  // 手动 Accept-Encoding / Connection 头删除：URLSession 自管 gzip 解压与
  // 连接复用；手动传 "gzip, deflate" 时若服务端按 deflate 响应，原生层不会
  // 自动解压导致解码失败。
  const externalSignal = opts?.signal ?? null;
  const requestId = `proto-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const onExternalAbort = () => TiebaNative.cancelProtoRequest(requestId);
  if (externalSignal?.aborted) {
    throw new TiebaApiError('Protobuf API request cancelled', -1, -1);
  }
  externalSignal?.addEventListener('abort', onExternalAbort, { once: true });
  try {
    const decoded = await TiebaNative.protoPost(
      url,
      headers,
      formFields,
      protoData,
      isV12,
      responseTypePath,
      requestId,
      DEFAULT_TIMEOUT,
    );
    // proto 通道不经过 axios interceptor，这里补 NOT_LOGIN 清理逻辑。
    // 2026-08-27：触发前先打点（url + 错误码）——曾误触发全毁登出
    // （clearAuthCredentials 现只清内存），日志用于定位是哪路接口报 1。
    const protoErr = (decoded as any)?.error;
    const protoErrCode = protoErr ? Number(protoErr.error_code ?? protoErr.errorCode ?? 0) : 0;
    if (protoErrCode === TiebaErrorCode.NOT_LOGIN) {
      if (__DEV__) {
        console.warn(`[auth] proto NOT_LOGIN 触发（温和登出）: url=${url} code=${protoErrCode} msg=${protoErr?.error_msg ?? ''}`);
      }
      handleAuthExpired();
    }
    return decoded as T;
  } catch (error: any) {
    const message = String(error?.message ?? error?.name ?? '');
    if (externalSignal?.aborted || /cancelled/i.test(message)) {
      throw new TiebaApiError('Protobuf API request cancelled', -1, -1);
    }
    if (/timed out|timeout/i.test(message)) {
      throw new TiebaApiError('Protobuf API request timed out', 408, 408);
    }
    throw error;
  } finally {
    externalSignal?.removeEventListener('abort', onExternalAbort);
  }
}

// -----------------------------------------------------------
// Public API — Hot Thread List
// -----------------------------------------------------------

/**
 * Fetch hot thread list with topics and tabs.
 *
 * Mirrors Kotlin:
 *   TiebaApi.getInstance().hotThreadListFlow(tabCode)
 *   → POST /c/f/forum/hotThreadList?cmd=309661
 *
 * The response is ONE protobuf containing { topicList, threadInfo, hotThreadTabInfo }
 * — unlike the old JSON API which returned tab_list only.
 */
export async function protoHotThreadList(
  tabCode: string = 'all',
): Promise<DecodedHotThreadListResponse> {
  const protoCommon = buildProtoCommonRequest();

  return protoPost<DecodedHotThreadListResponse>(
    '/c/f/forum/hotThreadList',
    '309661',
    protoCommon,
    (common) => encodeHotThreadListRequest(common, tabCode),
    'tieba.hotThreadList.HotThreadListResponse',
  );
}

// -----------------------------------------------------------
// Public API — Topic List
// -----------------------------------------------------------

/**
 * Fetch hot topic list.
 *
 * Mirrors Kotlin:
 *   TiebaApi.getInstance().topicListFlow()
 *   → POST /c/f/recommend/topicList?cmd=309289
 */
export async function protoTopicList(): Promise<DecodedTopicListResponse> {
  const protoCommon = buildProtoCommonRequest();

  return protoPost<DecodedTopicListResponse>(
    '/c/f/recommend/topicList',
    '309289',
    protoCommon,
    encodeTopicListRequest,
    'tieba.topicList.TopicListResponse',
  );
}

// -----------------------------------------------------------
// Public API — FrsPage (Forum Thread List)
// -----------------------------------------------------------

/**
 * Fetch forum thread list (protobuf).
 *
 * Mirrors Kotlin:
 *   TiebaApi.getInstance().frsPage(forumName, page, loadType, sortType, goodClassifyId)
 *   → POST /c/f/frs/page?cmd=301001
 */
export async function protoFrsPage(opts: {
  kw: string;
  pn: number;
  sortType: number;
  isGood?: boolean;
  goodClassifyId?: number;
  loadType?: number;
}): Promise<DecodedFrsPageResponse> {
  const protoCommon = buildProtoCommonRequest();
  // Kotlin: @Header("forum_name") forumName.urlEncode()
  const encodedKw = encodeURIComponent(opts.kw);

  return protoPost<DecodedFrsPageResponse>(
    '/c/f/frs/page',
    '301001',
    protoCommon,
    (common) => encodeFrsPageRequest(common, opts),
    'tieba.frsPage.FrsPageResponse',
    { extraHeaders: { forum_name: encodedKw } },
  );
}

// -----------------------------------------------------------
// Public API — PbPage (Thread Detail + Replies)
// -----------------------------------------------------------

/**
 * Fetch thread detail and replies (protobuf).
 *
 * Mirrors Kotlin:
 *   TiebaApi.getInstance().pbPageFlow(threadId, page, postId, seeLz, back, sortType, forumId, stType, mark, lastPostId)
 *   → POST /c/f/pb/page?cmd=302001&format=protobuf
 */
export async function protoPbPage(opts: {
  kz: number | string;
  pn: number;
  pid?: number | string;
  seeLz?: boolean;
  back?: boolean;
  sortType?: number;
  forumId?: number | string;
  stType?: string;
  mark?: number;
  lastPid?: number | string;
}, signal?: AbortSignal): Promise<DecodedPbPageResponse> {
  const protoCommon = buildProtoCommonRequest();

  return protoPost<DecodedPbPageResponse>(
    '/c/f/pb/page',
    '302001&format=protobuf',
    protoCommon,
    (common) => encodePbPageRequest(common, opts),
    'tieba.pbPage.PbPageResponse',
    { signal },
  );
}

// -----------------------------------------------------------
// Public API — Profile (User Profile)
// -----------------------------------------------------------

/**
 * Fetch user profile (protobuf).
 *
 * Mirrors Kotlin:
 *   TiebaApi.getInstance().userProfileFlow(uid)
 *   → POST /c/u/user/profile?cmd=303012&format=protobuf
 */
export async function protoProfile(opts: {
  selfUid: number | string;
  targetUid: number | string;
  isSelf: boolean;
}): Promise<DecodedProfileResponse> {
  const protoCommon = buildProtoCommonRequest();

  return protoPost<DecodedProfileResponse>(
    '/c/u/user/profile',
    '303012&format=protobuf',
    protoCommon,
    (common) => encodeProfileRequest(common, opts),
    'tieba.profile.ProfileResponse',
  );
}

// -----------------------------------------------------------
// Public API — PbFloor (楼中楼 / Sub-posts)
// -----------------------------------------------------------

/**
 * Fetch sub-posts (楼中楼) for a given floor (protobuf).
 *
 * Mirrors Kotlin:
 *   TiebaApi.getInstance().pbFloorFlow(threadId, postId, forumId, page, subPostId)
 *   → POST /c/f/pb/floor?cmd=302002&format=protobuf
 */
export async function protoPbFloor(opts: {
  kz: number | string;
  pid: number | string;
  pn: number;
  forumId?: number | string;
  subPostId?: number | string;
}, signal?: AbortSignal): Promise<DecodedPbFloorResponse> {
  const protoCommon = buildProtoCommonRequest();

  return protoPost<DecodedPbFloorResponse>(
    '/c/f/pb/floor',
    '302002&format=protobuf',
    protoCommon,
    (common) => encodePbFloorRequest(common, opts),
    'tieba.pbFloor.PbFloorResponse',
    { signal },
  );
}

// -----------------------------------------------------------
// Public API — SearchSug (搜索联想)
// -----------------------------------------------------------

/**
 * Fetch search suggestions (protobuf).
 *
 * Mirrors Kotlin:
 *   TiebaApi.getInstance().searchSuggestionsFlow(keyword, isForum)
 *   → POST /c/s/searchSug?cmd=309438&format=protobuf
 */
export async function protoSearchSug(opts: {
  word: string;
  isForum?: boolean;
}, signal?: AbortSignal): Promise<DecodedSearchSugResponse> {
  const protoCommon = buildProtoCommonRequest();

  return protoPost<DecodedSearchSugResponse>(
    '/c/s/searchSug',
    '309438&format=protobuf',
    protoCommon,
    (common) => encodeSearchSugRequest(common, opts),
    'tieba.searchSug.SearchSugResponse',
    { signal },
  );
}

// -----------------------------------------------------------
// Public API — GetBawuInfo (吧务信息)
// -----------------------------------------------------------

export async function protoGetBawuInfo(opts: {
  forumId: number | string;
}): Promise<DecodedGetBawuInfoResponse> {
  const protoCommon = buildProtoCommonRequest();

  return protoPost<DecodedGetBawuInfoResponse>(
    '/c/f/forum/getBawuInfo',
    '301007',
    protoCommon,
    (common) => encodeGetBawuInfoRequest(common, opts),
    'tieba.getBawuInfo.GetBawuInfoResponse',
  );
}

// -----------------------------------------------------------
// Public API — GetMemberInfo (会员信息)
// -----------------------------------------------------------

export async function protoGetMemberInfo(opts: {
  forumId: number | string;
}): Promise<DecodedGetMemberInfoResponse> {
  const protoCommon = buildProtoCommonRequest();

  return protoPost<DecodedGetMemberInfoResponse>(
    '/c/f/forum/getMemberInfo',
    '301004',
    protoCommon,
    (common) => encodeGetMemberInfoRequest(common, opts),
    'tieba.getMemberInfo.GetMemberInfoResponse',
  );
}

// -----------------------------------------------------------
// Public API — ForumRuleDetail (吧规详情)
// -----------------------------------------------------------

export async function protoForumRuleDetail(opts: {
  forumId: number | string;
}): Promise<DecodedForumRuleDetailResponse> {
  const protoCommon = buildProtoCommonRequest();

  return protoPost<DecodedForumRuleDetailResponse>(
    '/c/f/forum/forumRuleDetail',
    '309690',
    protoCommon,
    (common) => encodeForumRuleDetailRequest(common, opts),
    'tieba.forumRuleDetail.ForumRuleDetailResponse',
  );
}

// -----------------------------------------------------------
// Public API — GeneralTabList (通用Tab列表)
// -----------------------------------------------------------

export async function protoGeneralTabList(opts: {
  forumId: number | string;
  tabType?: number;
  pn?: number;
  rn?: number;
  sortType?: number;
  tabName?: string;
  tabId?: number;
}, signal?: AbortSignal): Promise<DecodedGeneralTabListResponse> {
  const protoCommon = buildProtoCommonRequest();

  return protoPost<DecodedGeneralTabListResponse>(
    '/c/f/frs/generalTabList',
    '309622',
    protoCommon,
    (common) => encodeGeneralTabListRequest(common, opts),
    'tieba.generalTabList.GeneralTabListResponse',
    { signal },
  );
}

// -----------------------------------------------------------
// Public API — Personalized (个性化推荐)
// -----------------------------------------------------------

export async function protoPersonalized(opts: {
  loadType?: number;
  pn?: number;
  needTags?: number;
  pageThreadCount?: number;
  preAdThreadCount?: number;
  sugCount?: number;
  tagCode?: number;
  qType?: number;
  needForumlist?: number;
  newNetType?: number;
  newInstall?: number;
  requestTimes?: number;
  invokeSource?: string;
  scrDip?: number;
  scrH?: number;
  scrW?: number;
}, signal?: AbortSignal): Promise<DecodedPersonalizedResponse> {
  const protoCommon = buildProtoCommonRequest();

  return protoPost<DecodedPersonalizedResponse>(
    // Kotlin：/c/f/excellent/personalized?cmd=309264。2026-08-27 实测：沿用
    // /c/f/recommend/personalized 时服务端返回空字节（body={}、连 error 都不回），
    // 推荐页恒空白；对齐 Kotlin 路径后正常。userLike 同款问题一并对齐。
    '/c/f/excellent/personalized',
    '309264',
    protoCommon,
    (common) => encodePersonalizedRequest(common, opts),
    'tieba.personalized.PersonalizedResponse',
    { signal },
  );
}

// -----------------------------------------------------------
// Public API — UserLike (用户关注动态)
// -----------------------------------------------------------

export async function protoUserLike(opts: {
  loadType?: number;
  pageTag?: string;
  lastRequestUnix?: number;
}, signal?: AbortSignal): Promise<DecodedUserLikeResponse> {
  const protoCommon = buildProtoCommonRequest();

  return protoPost<DecodedUserLikeResponse>(
    // Kotlin：/c/f/concern/userlike?cmd=309474。与 personalized 同批对齐（见上）。
    '/c/f/concern/userlike',
    '309474',
    protoCommon,
    (common) => encodeUserLikeRequest(common, opts),
    'tieba.userLike.UserLikeResponse',
    { signal },
  );
}

// -----------------------------------------------------------
// Public API — UserPost (用户帖子)
// -----------------------------------------------------------

export async function protoUserPost(opts: {
  uid: number | string;
  rn?: number;
  isThread?: number | boolean;
  needContent?: number;
  pn?: number;
  scrW?: number;
  scrH?: number;
  scrDip?: number;
  qType?: number;
  isViewCard?: number;
  subtype?: number;
}, signal?: AbortSignal): Promise<DecodedUserPostResponse> {
  const protoCommon = buildProtoCommonRequest();

  return protoPost<DecodedUserPostResponse>(
    // Kotlin OfficialProtobufTiebaApi.userPostFlow: POST /c/u/feed/userpost?cmd=303002&format=protobuf
    //（旧实现误写 /c/u/user/userPost，服务端回 110001"未知错误"→ 用户主页"贴子"tab 恒报"出错了"）
    '/c/u/feed/userpost',
    '303002&format=protobuf',
    protoCommon,
    (common) => encodeUserPostRequest(common, opts),
    'tieba.userPost.UserPostResponse',
    { signal },
  );
}

// -----------------------------------------------------------
// Public API — GetUserInfo (用户信息)
// -----------------------------------------------------------

export async function protoGetUserInfo(opts: {
  uid: number | string;
  scrW?: number;
}, signal?: AbortSignal): Promise<DecodedGetUserInfoResponse> {
  const protoCommon = buildProtoCommonRequest();

  return protoPost<DecodedGetUserInfoResponse>(
    // Kotlin: /c/u/user/getuserinfo?cmd=303024&format=protobuf（全小写；登录取资料也走这）
    '/c/u/user/getuserinfo',
    '303024&format=protobuf',
    protoCommon,
    (common) => encodeGetUserInfoRequest(common, opts),
    'tieba.getUserInfo.GetUserInfoResponse',
    { signal },
  );
}

// -----------------------------------------------------------
// Public API — GetForumDetail (吧详情)
// -----------------------------------------------------------

export async function protoGetForumDetail(opts: {
  forumId: number | string;
}): Promise<DecodedGetForumDetailResponse> {
  const protoCommon = buildProtoCommonRequest();

  return protoPost<DecodedGetForumDetailResponse>(
    '/c/f/forum/getforumdetail',
    '303021&format=protobuf',
    protoCommon,
    (common) => encodeGetForumDetailRequest(common, opts),
    'tieba.getForumDetail.GetForumDetailResponse',
  );
}

// -----------------------------------------------------------
// Public API — GetDislikeList (屏蔽吧列表, cmd=309692)
// -----------------------------------------------------------

export async function protoGetDislikeList(opts: {
  userId: number | string;
  pn?: number;
  rn?: number;
}, signal?: AbortSignal): Promise<DecodedGetDislikeListResponse> {
  const protoCommon = buildProtoCommonRequest();
  const uid = getUid();

  return protoPost<DecodedGetDislikeListResponse>(
    '/c/u/user/getDislikeList',
    '309692',
    protoCommon,
    (common) => encodeGetDislikeListRequest(common, {
      userId: opts.userId || uid || 0,
      pn: opts.pn ?? 1,
      rn: opts.rn ?? 20,
    }),
    'tieba.getDislikeList.GetDislikeListResponse',
    { signal },
  );
}
