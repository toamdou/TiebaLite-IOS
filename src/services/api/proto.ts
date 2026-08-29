// ============================================================
// TiebaLite RN — Protobuf Helpers (aligned with Kotlin Wire)
//
// 2026-08-29：编码与解码已全部下沉原生（SwiftProtobuf 生成代码，
// modules/tieba-native/ios/ProtoGenerated）：
//   - 编码：JS 对象 JSON → TiebaNative.protoEncode → wire base64（同步）。
//     schema 由生成代码保证，"嵌套 message 被平铺"的旧原生编码器 bug
//     在生成代码架构下结构性消失；protobufjs 依赖已移除。
//   - 解码：protoPost 内 TiebaSwiftProto.decode（无白名单投影，全字段），
//     int64/enum 由描述符归一化回旧形状，映射层零改动。
// ============================================================

// 模拟设备屏幕参数（round-54 收敛：原散落各处的魔法数统一走 config 常量）
import { SCR_W, SCR_H, SCR_DIP } from './config';
import { TiebaNative } from '../../../modules/tieba-native/src/TiebaNative';

type TypeRef = { fullName: string };

/**
 * Create a memoized lazy type accessor. The lookup (and thus the descriptor
 * parse) only happens the first time the returned function is called.
 */
function lazyType(path: string): () => TypeRef {
  let cached: TypeRef | null = null;
  return () => cached || (cached = { fullName: path });
}

// -----------------------------------------------------------
// Type lookups (mirrors Kotlin package paths)
// -----------------------------------------------------------

/** HotThreadList request wrapper */
const HotThreadListRequest = lazyType(
  'tieba.hotThreadList.HotThreadListRequest',
);

/** TopicList request wrapper */
const TopicListRequest = lazyType(
  'tieba.topicList.TopicListRequest',
);

/** FrsPage (forum thread list) */
const FrsPageRequest = lazyType('tieba.frsPage.FrsPageRequest');

/** PbPage (thread detail + replies) */
const PbPageRequest = lazyType('tieba.pbPage.PbPageRequest');

/** Profile (user profile) */
const ProfileRequest = lazyType('tieba.profile.ProfileRequest');

/** PbFloor (sub-post / 楼中楼) */
const PbFloorRequest = lazyType('tieba.pbFloor.PbFloorRequest');

// -----------------------------------------------------------
// Encode helpers
// -----------------------------------------------------------

/**
 * Encode a plain JS object into protobuf base64 (native codec).
 * Mirrors Kotlin `data.encode()`.
 */

function encodeProtobuf(type: TypeRef, data: Record<string, unknown>): string {
  // SwiftProtobuf 原生编码（2026-08-29）：schema 正确性由生成代码保证；
  // JS 对象 JSON（驼峰键）→ wire bytes → base64。未知字段忽略。
  return TiebaNative.protoEncode(type.fullName, JSON.stringify(data));
}

// -----------------------------------------------------------
// Public API — encode request bodies
// -----------------------------------------------------------

/** Common request fields (mirrors Kotlin CommonRequest proto) — camelCase per protobufjs JSON descriptor */
export interface ProtoCommonRequest {
  _clientType?: number;
  _clientVersion?: string;
  _clientId?: string;
  _phoneImei?: string;
  from?: string;
  cuid?: string;
  _timestamp?: number;
  model?: string;
  BDUSS?: string;
  tbs?: string;
  netType?: number;
  _phoneNewimei?: string;
  sign?: string;
  pversion?: string;
  _osVersion?: string;
  brand?: string;
  legoLibVersion?: string;
  applist?: string;
  stoken?: string;
  zId?: string;
  cuidGalaxy2?: string;
  cuidGid?: string;
  oaid?: string;
  c3Aid?: string;
  sampleId?: string;
  scrW?: number;
  scrH?: number;
  scrDip?: number;
  qType?: number;
  isTeenager?: number;
  sdkVer?: string;
  frameworkVer?: string;
  nawsGameVer?: string;
  activeTimestamp?: number;
  firstInstallTime?: number;
  lastUpdateTime?: number;
  eventDay?: string;
  androidId?: string;
  cmode?: number;
  startScheme?: string;
  startType?: number;
  extra?: string;
  userAgent?: string;
  personalizedRecSwitch?: number;
  deviceScore?: string;
}

/**
 * Encode HotThreadList request to protobuf binary.
 * Mirrors Kotlin:
 *   HotThreadListRequest(
 *     HotThreadListRequestData(
 *       common = buildCommonRequest(),
 *       tabCode = tabCode,
 *       tabId = "1"
 *     )
 *   )
 */
export function encodeHotThreadListRequest(
  common: ProtoCommonRequest,
  tabCode: string,
): string {
  return encodeProtobuf(HotThreadListRequest(), {
    data: {
      common,
      tabId: '1',
      tabCode,
    },
  });
}

/**
 * Encode TopicList request to protobuf binary.
 * Mirrors Kotlin:
 *   TopicListRequest(
 *     TopicListRequestData(
 *       common = buildCommonRequest(),
 *       call_from = "newbang",
 *       list_type = "all",
 *       need_tab_list = "0",
 *       fid = 0
 *     )
 *   )
 */
export function encodeTopicListRequest(
  common: ProtoCommonRequest,
): string {
  return encodeProtobuf(TopicListRequest(), {
    data: {
      common,
      callFrom: 'newbang',
      listType: 'all',
      needTabList: '0',
      fid: 0,
    },
  });
}

/**
 * Encode FrsPage request to protobuf binary.
 * Mirrors Kotlin MixedTiebaApiImpl.frsPage():
 *   FrsPageRequest(FrsPageRequestData(
 *     common, kw, pn, rn=90, rn_need=30, q_type=2,
 *     sort_type, st_type="recom_flist", with_group=1, load_type, ...
 *   ))
 */
export function encodeFrsPageRequest(
  common: ProtoCommonRequest,
  opts: {
    kw: string;
    pn: number;
    sortType: number;
    isGood?: boolean;
    goodClassifyId?: number;
    loadType?: number;
  },
): string {
  return encodeProtobuf(FrsPageRequest(), {
    data: {
      common,
      kw: encodeURIComponent(opts.kw), // Kotlin: forumName.urlEncode()
      pn: opts.pn,
      rn: 90,
      rnNeed: 30,
      qType: 2,
      sortType: opts.sortType,
      stType: 'recom_flist',
      withGroup: 1,
      loadType: opts.loadType ?? 0,
      isGood: opts.isGood ? 1 : 0,
      cid: opts.goodClassifyId ?? 0,
      scrW: SCR_W,
      scrH: SCR_H,
      scrDip: SCR_DIP,
      callFrom: 0,
      categoryId: 0,
      ctime: 0,
      dataSize: 0,
      hotThreadId: 0,
      isDefaultNavtab: 0,
      isSelection: 0,
      lastClickTid: 0,
      netError: 0,
      stParam: 0,
      upSchema: '',
      yuelaouLocate: '',
    },
  });
}

/**
 * Encode PbPage request to protobuf binary.
 * Mirrors Kotlin MixedTiebaApiImpl.pbPageFlow():
 *   PbPageRequest(PbPageRequestData(
 *     common, kz, pid, pn, r, lz, rn=15, with_floor=1, floor_rn=4, ...
 *   ))
 */
export function encodePbPageRequest(
  common: ProtoCommonRequest,
  opts: {
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
  },
): string {
  return encodeProtobuf(PbPageRequest(), {
    data: {
      common,
      kz: Number(opts.kz),
      pid: Number(opts.pid ?? 0),
      pn: opts.pn,
      r: opts.sortType ?? 0,
      lz: opts.seeLz ? 1 : 0,
      forumId: Number(opts.forumId ?? 0),
      mark: opts.mark ?? 0,
      lastPid: Number(opts.lastPid ?? 0),
      back: opts.back ? 1 : 0,
      banner: 0,
      broadcastId: 0,
      floorRn: 4,
      floorSortType: 1,
      fromPush: 0,
      fromSmartFrs: 0,
      immersionVideoCommentSource: 0,
      isCommReverse: 0,
      isFoldCommentReq: 0,
      isJumpfloor: 0,
      jumpfloorNum: 0,
      needRepostRecommendForum: 0,
      objLocate: '',
      objParam1: '10',
      objSource: '',
      oriUgcType: 0,
      pbRn: 0,
      qType: 2,
      requestTimes: 0,
      rn: 15,
      sModel: 0,
      scrW: SCR_W,
      scrH: SCR_H,
      scrDip: SCR_DIP,
      similarFrom: 0,
      sourceType: 2,
      stType: opts.stType ?? '',
      threadType: 0,
      weipost: 0,
      withFloor: 1,
    },
  });
}

/**
 * Encode Profile request to protobuf binary.
 * Mirrors Kotlin MixedTiebaApiImpl.userProfileFlow():
 *   ProfileRequest(ProfileRequestData(
 *     common, uid=selfUid, friend_uid=targetUid, is_guest, ...
 *   ))
 */
export function encodeProfileRequest(
  common: ProtoCommonRequest,
  opts: {
    selfUid: number | string;
    targetUid: number | string;
    isSelf: boolean;
  },
): string {
  return encodeProtobuf(ProfileRequest(), {
    data: {
      common,
      uid: Number(opts.selfUid) || undefined,
      friendUid: opts.isSelf ? undefined : Number(opts.targetUid),
      friendUidPortrait: '',
      hasPlist: 1,
      isFromUsercenter: 1,
      isGuest: opts.isSelf ? 0 : 1,
      needPostCount: 1,
      page: 1,
      pn: 1,
      qType: 0,
      rn: 20,
      scrW: SCR_W,
      scrH: SCR_H,
      scrDip: SCR_DIP,
    },
  });
}

// -----------------------------------------------------------
// Public API — decode response bodies
// -----------------------------------------------------------

/** Decoded HotThreadList response (mirrors Kotlin protobuf response) */
export interface DecodedHotThreadListResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    topicList?: Record<string, unknown>[];
    threadInfo?: Record<string, unknown>[];
    hotThreadTabInfo?: Record<string, unknown>[];
  };
}

/** Decoded TopicList response */
export interface DecodedTopicListResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    /** 原生解码器输出驼峰键（描述符由 protobufjs 生成，默认 camelCase）；
     * feed.ts 以 topicList ?? topic_list 双读兜底。 */
    topicList?: Record<string, unknown>[];
    topic_list?: Record<string, unknown>[];
  };
}

// （decode 函数本体在 protoClient.ts；此处只保留响应形状定义）

// -----------------------------------------------------------
// FrsPage decode
// -----------------------------------------------------------

export interface DecodedFrsPageResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    forum?: Record<string, any>;
    threadList?: Record<string, any>[];
    userList?: Record<string, any>[];
    page?: { currentPage?: number; totalPage?: number; totalCount?: number; pageSize?: number; hasMore?: number; hasPrev?: number };
    anti?: { tbs?: string; ifPost?: number; forbidFlag?: number };
    navTabInfo?: Record<string, any>[];
    threadIdList?: (number | string)[];
    forumRule?: { title?: string; hasForumRule?: number };
  };
}

// -----------------------------------------------------------
// PbPage decode
// -----------------------------------------------------------

export interface DecodedPbPageResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    thread?: Record<string, any>;
    postList?: Record<string, any>[];
    firstFloorPost?: Record<string, any>;
    page?: { currentPage?: number; totalPage?: number; totalCount?: number; pageSize?: number; hasMore?: number; hasPrev?: number };
    userList?: Record<string, any>[];
    forum?: Record<string, any>;
    anti?: { tbs?: string; ifPost?: number; forbidFlag?: number; forbidInfo?: string };
  };
}

// -----------------------------------------------------------
// Profile decode
// -----------------------------------------------------------

export interface DecodedProfileResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    user?: Record<string, any>;
  };
}

// -----------------------------------------------------------
// PbFloor encode / decode (楼中楼)
// -----------------------------------------------------------

export function encodePbFloorRequest(
  common: ProtoCommonRequest,
  opts: {
    kz: number | string;
    pid: number | string;
    pn: number;
    forumId?: number | string;
    subPostId?: number | string;
  },
): string {
  return encodeProtobuf(PbFloorRequest(), {
    data: {
      common,
      kz: Number(opts.kz),
      pid: Number(opts.pid),
      pn: opts.pn,
      forumId: Number(opts.forumId ?? 0),
      spid: Number(opts.subPostId ?? 0),
      // round-54：原 1080×2400@3.0 与其余 6 处请求的模拟设备参数不一致
      // （疑似从其它设备模板复制）；统一走 config 的 SCR_W/SCR_H/SCR_DIP
      // （1170×2532@3）。若真机验证需回退，改 config 常量即可。
      scrW: SCR_W,
      scrH: SCR_H,
      scrDip: SCR_DIP,
      isCommReverse: 0,
      oriUgcType: 0,
    },
  });
}

export interface DecodedPbFloorResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    page?: { currentPage?: number; totalPage?: number; totalCount?: number; hasMore?: number };
    post?: Record<string, any>;
    subpostList?: Record<string, any>[];
    thread?: Record<string, any>;
    forum?: Record<string, any>;
    anti?: { tbs?: string };
  };
}

// -----------------------------------------------------------
// SearchSug (搜索联想)
// -----------------------------------------------------------

const SearchSugRequest = lazyType('tieba.searchSug.SearchSugRequest');

export interface DecodedSearchSugResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    /**
     * ⚠️ forum_loc（forumLoc）不在 TiebaProtoCodec.swift 搜索联想白名单
     * （白名单仅有 list/forumList），native 解码投影会剥掉该字段 —— 由
     * Swift 代理负责补白名单；本接口保留权威声明。
     */
    forumLoc?: number;
    list?: string[];
    forumList?: Record<string, any>[];
  };
}

export function encodeSearchSugRequest(
  common: ProtoCommonRequest,
  opts: { word: string; isForum?: boolean },
): string {
  return encodeProtobuf(SearchSugRequest(), {
    data: {
      common,
      word: opts.word,
      isforum: opts.isForum ? '1' : '0',
    },
  });
}

// -----------------------------------------------------------
// GetBawuInfo (吧务信息)
// -----------------------------------------------------------

const GetBawuInfoRequest = lazyType('tieba.getBawuInfo.GetBawuInfoRequest');

export interface DecodedGetBawuInfoResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    bawuTeamInfo?: {
      totalNum?: number;
      bawuTeamList?: {
        roleName?: string;
        roleInfo?: {
          forumId?: number | string;
          userId?: number | string;
          roleId?: number;
          roleName?: string;
          portrait?: string;
          userLevel?: number;
          levelName?: string;
          userName?: string;
          nameShow?: string;
        }[];
      }[];
    };
    managerApplyInfo?: {
      managerLeftNum?: number;
      managerApplyUrl?: string;
      assistLeftNum?: number;
      assistApplyUrl?: string;
    };
    isPrivateForum?: number;
    [key: string]: any;
  };
}

export function encodeGetBawuInfoRequest(
  common: ProtoCommonRequest,
  opts: { forumId: number | string },
): string {
  return encodeProtobuf(GetBawuInfoRequest(), {
    data: { common, forumId: Number(opts.forumId) },
  });
}

// -----------------------------------------------------------
// GetMemberInfo (会员信息)
// -----------------------------------------------------------

const GetMemberInfoRequest = lazyType('tieba.getMemberInfo.GetMemberInfoRequest');

// 权威键（protos_src/GetMemberInfo/*.proto，round-54 重建：
// member_group_info=1 repeated MemberGroupInfo 等；ForumMember 权威字段为
// isLike/userLevel/levelName/curScore/levelupScore —— 曾误写 repeated memberInfo）。
export interface DecodedGetMemberInfoResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    memberGroupInfo?: {
      memberGroupType?: string;
      memberGroupNum?: number;
      memberGroupList?: Record<string, any>[];
    }[];
    forumMemberInfo?: {
      isLike?: number;
      userLevel?: number;
      levelName?: string;
      curScore?: number;
      levelupScore?: number;
    };
    memberGodInfo?: { forumGodList?: Record<string, any>[]; forumGodNum?: number };
    managerApplyInfo?: Record<string, any>;
    isPrivateForum?: number;
    isBawuapplyShow?: number;
    primanagerApplyInfo?: {
      assistLeftNum?: number;
      assistApplyUrl?: string;
      assistApplyStatus?: number;
    };
    [key: string]: any;
  };
}

export function encodeGetMemberInfoRequest(
  common: ProtoCommonRequest,
  opts: { forumId: number | string },
): string {
  return encodeProtobuf(GetMemberInfoRequest(), {
    data: { common, forumId: Number(opts.forumId) },
  });
}

// -----------------------------------------------------------
// ForumRuleDetail (吧规详情)
// -----------------------------------------------------------

const ForumRuleDetailRequest = lazyType('tieba.forumRuleDetail.ForumRuleDetailRequest');

// 权威键（protos_src/ForumRuleDetail/*.proto，round-54 重建：
// forum=2/title=3/preface=4/rules=5(ForumRule[])/bazhu=11 —— 曾凭空捏造
// forumRule/ruleHtml/ruleText/ruleTitle 四键，解码全空）。
export interface DecodedForumRuleDetailResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    forum?: Record<string, any>;
    title?: string;
    preface?: string;
    rules?: {
      title?: string;
      /** PbContent[]（与正文内容同构，UI 走 toContent/mapProtoContent 渲染） */
      content?: Record<string, any>[];
      status?: number;
    }[];
    auditStatus?: number;
    auditOpinion?: string;
    isManager?: number;
    forumRuleId?: number | string;
    publishTime?: string;
    bazhu?: Record<string, any>;
    curTime?: string;
    [key: string]: any;
  };
}

export function encodeForumRuleDetailRequest(
  common: ProtoCommonRequest,
  opts: { forumId: number | string },
): string {
  return encodeProtobuf(ForumRuleDetailRequest(), {
    data: { common, forumId: Number(opts.forumId) },
  });
}

// -----------------------------------------------------------
// GeneralTabList (通用Tab列表)
// -----------------------------------------------------------

const GeneralTabListRequest = lazyType('tieba.generalTabList.GeneralTabListRequest');

export interface DecodedGeneralTabListResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    // 权威键（protos_src/GeneralTabList/GeneralTabListResponseData.proto，
    // package tieba.GeneralTabList）：general_list=1/has_more=2/user_list=3/
    // sort_type=7 —— 曾虚列 tabList/threadList/page。
    // ⚠️ add-protos.js 的 generalTabList 手写补丁仍是旧键（tabList/threadList/
    // userList/page，未在 round-54 重建名单内），与权威源不一致 —— 与本接口
    // 的差异由后续轮次收敛（Swift 投影白名单已按权威键 generalList/userList 配置）。
    generalList?: Record<string, any>[];
    userList?: Record<string, any>[];
    hasMore?: number;
    sortType?: number;
    [key: string]: any;
  };
}

export function encodeGeneralTabListRequest(
  common: ProtoCommonRequest,
  opts: {
    forumId: number | string;
    tabType?: number;
    pn?: number;
    rn?: number;
    sortType?: number;
    tabName?: string;
    tabId?: number;
  },
): string {
  return encodeProtobuf(GeneralTabListRequest(), {
    data: {
      common,
      forumId: Number(opts.forumId),
      tabType: opts.tabType ?? 0,
      pn: opts.pn ?? 1,
      rn: opts.rn ?? 30,
      sortType: opts.sortType ?? 0,
      tabName: opts.tabName ?? '',
      tabId: opts.tabId ?? 0,
    },
  });
}

// -----------------------------------------------------------
// Personalized (个性化推荐)
// -----------------------------------------------------------

const PersonalizedRequest = lazyType('tieba.personalized.PersonalizedRequest');

export interface DecodedPersonalizedResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    // 权威键（protos_src/Personalized.proto）：thread_list=2 + thread_personalized=7；
    // 曾虚列 userList/page/hasMore 谎言字段，实际解码不存在。
    threadList?: Record<string, any>[];
    threadPersonalized?: Record<string, any>[];
    [key: string]: any;
  };
}

/** 推荐流每页条数（对齐 Kotlin personalizedProtoFlow 固定 page_thread_count=11） */
export const PERSONALIZED_PAGE_SIZE = 11;

export function encodePersonalizedRequest(
  common: ProtoCommonRequest,
  opts: {
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
  },
): string {
  return encodeProtobuf(PersonalizedRequest(), {
    data: {
      common,
      loadType: opts.loadType ?? 0,
      pn: opts.pn ?? 1,
      needTags: opts.needTags ?? 0,
      // 对齐 Kotlin personalizedProtoFlow（22.x 客户端行为）：page_thread_count=11、
      // q_type=1、new_net_type=1（原为 0，服务端可能因容量 0 回空列表）
      pageThreadCount: opts.pageThreadCount ?? PERSONALIZED_PAGE_SIZE,
      preAdThreadCount: opts.preAdThreadCount ?? 0,
      sugCount: opts.sugCount ?? 0,
      tagCode: opts.tagCode ?? 0,
      qType: opts.qType ?? 1,
      needForumlist: opts.needForumlist ?? 0,
      newNetType: opts.newNetType ?? 1,
      newInstall: opts.newInstall ?? 0,
      requestTimes: opts.requestTimes ?? 0,
      invokeSource: opts.invokeSource ?? '',
      // app_pos 与 Kotlin buildAppPosInfo() 一致（22.x 客户端上报的风控/定位块）
      appPos: {
        apMac: '02:00:00:00:00:00',
        apConnected: true,
        coordinateType: 'BD09LL',
        addrTimestamp: 0,
        aspShownInfo: '',
      },
      scrDip: opts.scrDip ?? SCR_DIP,
      scrH: opts.scrH ?? SCR_H,
      scrW: opts.scrW ?? SCR_W,
    },
  });
}

// -----------------------------------------------------------
// UserLike (用户关注动态)
// -----------------------------------------------------------

const UserLikeRequest = lazyType('tieba.userLike.UserLikeRequest');

export interface DecodedUserLikeResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    // 权威键（protos_src/UserLike/UserLike.proto）：threadInfo=1（ConcernData[]，
    // 内含 threadList: ThreadInfo）—— 曾误写 threadList，feed.ts:141 真读 threadInfo。
    threadInfo?: Record<string, any>[];
    pageTag?: string;
    hasMore?: number;
    requestUnix?: number | string;
    [key: string]: any;
  };
}

export function encodeUserLikeRequest(
  common: ProtoCommonRequest,
  opts: { loadType?: number; pageTag?: string; lastRequestUnix?: number },
): string {
  return encodeProtobuf(UserLikeRequest(), {
    data: {
      common,
      loadType: opts.loadType ?? 0,
      pageTag: opts.pageTag ?? '',
      lastRequestUnix: opts.lastRequestUnix ?? 0,
      // 对齐 Kotlin userLikeFlow：follow_type=1（关注动态流）
      followType: 1,
    },
  });
}

// -----------------------------------------------------------
// UserPost (用户帖子)
// -----------------------------------------------------------

const UserPostRequest = lazyType('tieba.userPost.UserPostRequest');

export interface DecodedUserPostResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    postList?: Record<string, any>[];
    hidePost?: number;
    time?: number | string;
    content?: Record<string, any>[];
    hasMore?: number;
    [key: string]: any;
  };
}

export function encodeUserPostRequest(
  common: ProtoCommonRequest,
  opts: {
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
  },
): string {
  return encodeProtobuf(UserPostRequest(), {
    data: {
      common,
      uid: Number(opts.uid),
      rn: opts.rn ?? 20,
      isThread: opts.isThread ? 1 : 0,
      needContent: opts.needContent ?? 0,
      pn: opts.pn ?? 1,
      scrW: opts.scrW ?? SCR_W,
      scrH: opts.scrH ?? SCR_H,
      scrDip: opts.scrDip ?? SCR_DIP,
      qType: opts.qType ?? 0,
      isViewCard: opts.isViewCard ?? 0,
      subtype: opts.subtype ?? 0,
    },
  });
}

// -----------------------------------------------------------
// GetUserInfo (用户信息)
// -----------------------------------------------------------

const GetUserInfoRequest = lazyType('tieba.getUserInfo.GetUserInfoRequest');

export interface DecodedGetUserInfoResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    user?: Record<string, any>;
    [key: string]: any;
  };
}

export function encodeGetUserInfoRequest(
  common: ProtoCommonRequest,
  opts: { uid: number | string; scrW?: number },
): string {
  return encodeProtobuf(GetUserInfoRequest(), {
    data: {
      common,
      uid: Number(opts.uid),
      scrW: opts.scrW ?? SCR_W,
    },
  });
}

// -----------------------------------------------------------
// GetForumDetail (吧详情)
// -----------------------------------------------------------

const GetForumDetailRequest = lazyType('tieba.getForumDetail.GetForumDetailRequest');
export interface DecodedGetForumDetailResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    forum?: Record<string, any>;
    [key: string]: any;
  };
}

export function encodeGetForumDetailRequest(
  common: ProtoCommonRequest,
  opts: { forumId: number | string },
): string {
  return encodeProtobuf(GetForumDetailRequest(), {
    data: { common, forumId: Number(opts.forumId) },
  });
}

// -----------------------------------------------------------
// GetDislikeList (屏蔽吧列表, cmd=309692)
// -----------------------------------------------------------

const GetDislikeListRequest = lazyType('tieba.getDislikeList.GetDislikeListRequest');

export interface DecodedGetDislikeListResponse {
  error?: { error_code?: number; error_msg?: string };
  data?: {
    forumList?: Record<string, any>[];
    hasMore?: number;
    curPage?: number;
    [key: string]: any;
  };
}

export function encodeGetDislikeListRequest(
  common: ProtoCommonRequest,
  opts: { userId: number | string; pn: number; rn: number },
): string {
  return encodeProtobuf(GetDislikeListRequest(), {
    data: {
      common,
      userId: Number(opts.userId),
      pn: opts.pn,
      rn: opts.rn,
    },
  });
}
