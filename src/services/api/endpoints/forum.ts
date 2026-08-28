import { apiGetWeb, apiPost, apiWebPost } from '../client';
import type { AxiosResponse } from '../client';
import { TiebaApiError, getTiebaError } from '../interceptors';
import {
  protoForumRuleDetail,
  protoGeneralTabList,
  protoGetBawuInfo,
  protoGetForumDetail,
  protoGetMemberInfo,
} from '../protoClient';
import {
  assertProtoSuccess,
  extractData,
  getTbs,
  postFormAction,
  type TiebaRes,
} from './helpers';
import { AIOTIEBA_VERSION } from '../config';
import type {
  DecodedGeneralTabListResponse,
  DecodedGetBawuInfoResponse,
  DecodedGetMemberInfoResponse,
} from '../proto';
import type { ForumDetail, SignResult } from '@/types';

/**
 * forumGuide 响应（/c/f/forum/forumGuide，JSON 表单端点）：
 * 顶层 error_code/error_msg + data.like_forum（已关注吧列表）。
 * forumFollowed 以 like_forum ?? likeForum 双读；`data` 缺失时响应整体
 * 即数据容器（forumFollowed 的 `response?.data ?? response` 兜底），故
 * 外层同样声明列表键 + 索引签名，其余字段不属于本项目消费面。
 */
export interface ForumGuideResponse {
  error_code?: string | number;
  error_msg?: string;
  data?: {
    like_forum?: unknown[];
    likeForum?: unknown[];
    [key: string]: unknown;
  };
  like_forum?: unknown[];
  likeForum?: unknown[];
  [key: string]: unknown;
}

// aiotieba get_self_follow_forums 同构：**web 通道**（tieba.baidu.com，无签名，
// cookie 认证）+ Subapp-Type: hybrid；字段仅 tbs/sort_type/call_from/page_no/
// res_num。旧 C_TIEBA+signed 路径已被服务端实测 110001（2026-08-27）。
export async function forumGuide(
  sortType: number = 3,
  callFrom: number = 3,
  pageNo: number = 1,
  resNum: number = 50,
  signal?: AbortSignal,
): Promise<ForumGuideResponse> {
  return extractData(await apiWebPost(
    '/c/f/forum/forumGuide',
    {
      sort_type: String(sortType),
      call_from: String(callFrom),
      page_no: String(pageNo),
      res_num: String(resNum),
      tbs: getTbs(),
    },
    { 'Subapp-Type': 'hybrid' },
    signal,
  ));
}

// Kotlin protobuf: POST /c/f/forum/getforumdetail?cmd=303021&format=protobuf (v12)
// forumDetail is the web GET endpoint used by the detail page and as the
// JSON fallback when the protobuf detail endpoint rejects.
export async function forumDetail(forumId: string): Promise<ForumDetail> {
  const response = await apiGetWeb<TiebaRes<ForumDetail>>('/mo/q/forumDetail', { fid: forumId });
  return extractData(response).data;
}

/**
 * Protobuf forum detail used by the forum info page. Falls back to the
 * legacy JSON endpoint when protobuf returns an error.
 */
export async function getForumDetail(forumId: string): Promise<unknown> {
  try {
    const decoded = await protoGetForumDetail({ forumId });
    assertProtoSuccess(decoded);
    return decoded.data?.forum ?? decoded.data ?? null;
  } catch (error) {
    if (__DEV__) console.warn('[getForumDetail] protobuf failed, fallback:', error);
    return forumDetail(String(forumId));
  }
}

/**
 * 吧规详情。proto 路径（主）返回 DecodedForumRuleDetailResponse.data（权威键
 * forum/title/preface/rules/bazhu…，data 缺失时兜底整包）；web 降级路径返回
 * 整包 body（{code, data, …}，嵌套层级与 proto 不同）。两形态形状复杂，
 * 收窄为 unknown —— 消费侧（forum/[name]/rules.tsx parseRuleData(res: any)）
 * 自行双读。
 */
export async function forumRuleDetail(forumId: string): Promise<unknown> {
  try {
    const decoded = await protoForumRuleDetail({ forumId });
    assertProtoSuccess(decoded);
    return decoded.data ?? decoded;
  } catch (e) {
    if (__DEV__) console.warn('[forumRuleDetail] proto failed, fallback:', e);
    return extractData(await apiGetWeb('/mo/q/forumRuleDetail', { fid: forumId }));
  }
}

// ============================================================
// Sign-in — 对齐 Kotlin (POST, FORCE_LOGIN)
// ============================================================
// Kotlin MiniTiebaApi: POST /c/c/forum/sign {kw, tbs}
// Kotlin OfficialTiebaApi: POST /c/c/forum/msign {forum_ids, tbs}

export async function sign(forumName: string, tbs: string, forumId?: string): Promise<SignResult> {
  if (!tbs) {
    throw new TiebaApiError('缺少 tbs，无法签到', 400, 400);
  }
  // Kotlin OfficialTiebaApi: signFlow(fid, kw, tbs) — includes fid
  const body: Record<string, string> = { kw: forumName, tbs };
  if (forumId) body.fid = forumId;
  // ⚠️ 类型注意（TS 6.0 CFA 行为）：`await` 结果赋给显式 `any` 注解的变量时，
  // 读该变量会被收窄为 unknown（`let x: any = await …` → TS2571）。故此处用
  // 具体类型 AxiosResponse<any>；try/catch 后 catch 必然 return 或 throw，
  // response 必已赋值，`!` 仅为安抚 CFA。
  let response: AxiosResponse<any> | undefined;
  try {
    response = await apiPost<any>('/c/c/forum/sign', body);
  } catch (error) {
    // ⚠️ 1101「今日已签到」双路径兜底（消费契约见 forum/[name].tsx handleSign：
    //   正常分支判 result.isSuccess；已签到判 result.errorCode === 1101）：
    // 1. 顶层 error_code='1101' —— axios 响应拦截器（interceptors.ts
    //    assertSuccessPayload/getTiebaError）会先抛 TiebaApiError（code=1101，
    //    rawData 携带完整响应体），直接冒泡会让页面落入通用 catch → 「网络错误」。
    //    在此归一为 SignResult（isSuccess=false + errorCode=1101），读取
    //    rawData 中已签到信息（forum_id/forum_name/exp/sign_rank），页面既有
    //    `result.errorCode === 1101` → 「今天已签到」分支无需改动。
    // 2. data 内 error_code='1101'（顶层 error_code=0，拦截器放行）——
    //    走下方正常分支，同样得到 errorCode=1101。
    // 若未来调用方改用 catch 消费，可判 `err instanceof TiebaApiError && err.code === 1101`。
    if (error instanceof TiebaApiError && error.code === 1101) {
      const rawData = (error.rawData ?? {}) as Record<string, any>;
      const inner = rawData.data ?? {};
      const uInfo = inner.user_info ?? inner.userInfo ?? {};
      return {
        forumId: inner?.forum_id ?? forumId ?? '',
        forumName: inner?.forum_name ?? forumName,
        exp: Number(inner?.exp ?? uInfo?.sign_bonus_point ?? uInfo?.signBonusPoint ?? 0),
        signRank: Number(inner?.sign_rank ?? uInfo?.sign_rank ?? uInfo?.signRank ?? 0),
        isSuccess: false,
        errorCode: 1101,
        errorMsg: inner?.error_msg ?? error.message,
      };
    }
    throw error;
  }
  const raw = extractData(response!).data;
  // 服务端下发 user_info.sign_bonus_point（aiotieba sign_forum 同款权威键，
  // 顶层 exp 兼容旧形态）——否则"签到成功 经验+0"（2026-08-27 实测）。
  const uInfo = raw?.user_info ?? raw?.data?.user_info ?? raw?.userInfo ?? {};
  return {
    forumId: raw?.forum_id ?? forumId ?? '', forumName: raw?.forum_name ?? forumName,
    exp: Number(raw?.exp ?? uInfo?.sign_bonus_point ?? uInfo?.signBonusPoint ?? 0),
    signRank: Number(raw?.sign_rank ?? uInfo?.sign_rank ?? uInfo?.signRank ?? 0),
    isSuccess: getTiebaError(raw) === null,
    errorCode: raw?.error_code ? parseInt(raw.error_code, 10) : undefined, errorMsg: raw?.error_msg,
  };
}

export async function mSign(_forumIds: string[], tbs: string, _userId?: string): Promise<SignResult[]> {
  if (!tbs) {
    throw new TiebaApiError('缺少 tbs，无法批量签到', 400, 400);
  }
  // aiotieba sign_forums 同构：**web 通道**（tieba.baidu.com，无签名，cookie
  // 认证），字段仅 _client_version + subapp_type；服务端自动签到全部关注吧，
  // sign_list 逐吧返回（旧 forum_ids 传参会破坏该语义且走已废的 C_TIEBA）。
  const raw = extractData(await apiWebPost<any>('/c/c/forum/msign', {
    _client_version: AIOTIEBA_VERSION,
    subapp_type: 'hybrid',
  }, { 'Subapp-Type': 'hybrid' })).data;
  return (raw?.sign_list ?? []).map((item: any) => ({
    forumId: item.forum_id ?? item.forumId ?? '', forumName: item.forum_name ?? item.forumName ?? '', exp: item.exp ?? 0,
    signRank: item.sign_rank ?? item.signRank ?? 0, isSuccess: getTiebaError(item) === null,
    // 双读（8-28）：aiotieba 通道 sign_list 字段可能是 error_code（snake）
    // 或 errorCode（camel），旧实现只读 snake——若服务端下发 camel，
    // 1101「今日已签」判不到，一键签到误报「失败 N」。
    errorCode: (item.error_code ?? item.errorCode) != null ? parseInt(String(item.error_code ?? item.errorCode), 10) : undefined,
    errorMsg: item.error_msg ?? item.errorMsg,
  }));
}

// ============================================================
// Forum Protobuf APIs — NEW (对齐 Kotlin protobuf endpoints)
// ============================================================

// Kotlin protobuf: POST /c/f/forum/getBawuInfo?cmd=301007
// (cmd 与 protoClient.protoGetBawuInfo 一致；Kotlin OfficialProtobufTiebaApi 核对)
/**
 * 吧务信息（proto）。权威键见 DecodedGetBawuInfoResponse：bawuTeamInfo
 * （内嵌 bawuTeamList）等；data 缺失时兜底整包。消费侧（bawu.tsx）做
 * snake/camel 双读（bawu_team_info/bawuTeamInfo、total_num/totalNum），
 * 故整包形态同样保留索引签名。
 */
export type GetBawuInfoPayload =
  | NonNullable<DecodedGetBawuInfoResponse['data']>
  | (DecodedGetBawuInfoResponse & { [key: string]: any });

export async function getBawuInfo(forumId: string): Promise<GetBawuInfoPayload> {
  const decoded = await protoGetBawuInfo({ forumId });
  assertProtoSuccess(decoded);
  return decoded.data ?? decoded;
}

// Kotlin protobuf: POST /c/f/forum/getMemberInfo?cmd=301004
// (cmd 与 protoClient.protoGetMemberInfo 一致；Kotlin OfficialProtobufTiebaApi 核对)
/**
 * 会员信息（proto）。权威键见 DecodedGetMemberInfoResponse：memberGroupInfo/
 * forumMemberInfo/memberGodInfo…（round-54 重建后 member_group_info=1 等）；
 * data 缺失时兜底整包。消费侧（members.tsx parseGroups/parseMyMemberInfo）
 * 取 any 自行解析。
 */
export async function getMemberInfo(forumId: string): Promise<
  NonNullable<DecodedGetMemberInfoResponse['data']> | DecodedGetMemberInfoResponse
> {
  const decoded = await protoGetMemberInfo({ forumId });
  assertProtoSuccess(decoded);
  return decoded.data ?? decoded;
}

// Kotlin protobuf: POST /c/f/frs/generalTabList?cmd=309622
// (cmd 与 protoClient.protoGeneralTabList 一致；Kotlin OfficialProtobufTiebaApi 核对)
/**
 * 通用 Tab 列表（proto）。权威键见 DecodedGeneralTabListResponse：
 * generalList/userList/hasMore/sortType（protos_src/GeneralTabList 重建后
 * general_list=1 等）；data 缺失时兜底整包。
 */
export async function generalTabList(forumId: string, opts?: {
  tabType?: number; pn?: number; rn?: number; sortType?: number; tabName?: string; tabId?: number;
}, signal?: AbortSignal): Promise<
  NonNullable<DecodedGeneralTabListResponse['data']> | DecodedGeneralTabListResponse
> {
  const decoded = await protoGeneralTabList({
    forumId,
    tabType: opts?.tabType,
    pn: opts?.pn ?? 1,
    rn: opts?.rn ?? 20,
    sortType: opts?.sortType,
    tabName: opts?.tabName,
    tabId: opts?.tabId,
  }, signal);
  assertProtoSuccess(decoded);
  return decoded.data ?? decoded;
}

// ============================================================
// Additional Form-Encoded APIs
// ============================================================

// Kotlin MiniTiebaApi: POST /c/c/forum/like (FORCE_LOGIN)
// 响应对齐 Kotlin LikeForumResultBean：info 字段携带等级与经验分
// （cur_score / levelup_score / level_id / level_name / member_sum）——
// 关注成功后吧页头部的等级徽标与进度条即来自这里（Kotlin 同款）。
export async function likeForum(
  forumId: string,
  forumName: string,
  tbs: string,
): Promise<{
  memberSum?: number;
  levelId?: number;
  levelName?: string;
  curScore?: number;
  levelupScore?: number;
}> {
  if (!tbs) {
    throw new TiebaApiError('缺少 tbs，无法关注贴吧', 400, 400);
  }
  const raw = await postFormAction<any>('/c/c/forum/like', {
    fid: forumId, kw: forumName, tbs,
  });
  const info = raw?.info;
  if (!info || typeof info !== 'object') return {};
  const toInt = (v: unknown): number | undefined => {
    const n = parseInt(String(v ?? ''), 10);
    return Number.isNaN(n) ? undefined : n;
  };
  return {
    memberSum: toInt(info.member_sum ?? info.memberSum),
    levelId: toInt(info.level_id ?? info.levelId),
    levelName: info.level_name ?? info.levelName,
    curScore: toInt(info.cur_score ?? info.curScore),
    levelupScore: toInt(info.levelup_score ?? info.levelUpScore),
  };
}

// Kotlin OfficialTiebaApi: POST /c/c/forum/unfavolike (FORCE_LOGIN)
export async function unfavolike(forumId: string, forumName: string, tbs: string): Promise<{ success: boolean }> {
  if (!tbs) {
    throw new TiebaApiError('缺少 tbs，无法取消关注贴吧', 400, 400);
  }
  await postFormAction('/c/c/forum/unfavolike', {
    fid: forumId, kw: forumName, tbs,
  });
  return { success: true };
}

