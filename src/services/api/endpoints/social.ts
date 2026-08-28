// ============================================================
// Social — 粉丝/关注/黑名单/屏蔽吧/吧成员/等级排行/成长任务
//
// 对照 aiotieba api/ 目录实现（form/web GET），未 proto 化部分
// 保持 JSON form 形态以降低风控风险与工程量。
// ============================================================

import { apiGetWeb, apiUpload } from '../client';
import { postFormAction, getStoken } from './helpers';
import { TiebaApiError } from '../interceptors';
import { getUidSync } from '@/services/storage/AuthSQLiteStorage';

export interface SocialUser {
  uid: string;
  portrait: string;
  userName: string;
  nickName: string;
  btype?: string;        // 黑名单类型位串（"FOLLOW,INTERACT,CHAT"）
}

export interface SocialListRes {
  items: SocialUser[];
  hasMore: boolean;
  currentPage: number;
}

function cleanPortrait(p: string): string {
  // 对齐 aiotieba：portrait 尾部 "?" 后的加密段裁剪
  const idx = p.indexOf('?');
  return idx >= 0 ? p.slice(0, idx) : p;
}

/**
 * First non-null value among `keys` if it is an array, else []. Preserves the
 * `a ?? b ?? c` null-skipping semantics used by JSON fallback list fields.
 */
function coalesceList(obj: any, keys: string[]): any[] {
  for (const key of keys) {
    const value = obj?.[key];
    if (value !== undefined && value !== null) {
      return Array.isArray(value) ? value : [];
    }
  }
  return [];
}

function mapSocialUser(raw: any): SocialUser {
  return {
    uid: String(raw.id ?? raw.uid ?? ''),
    portrait: cleanPortrait(String(raw.portrait ?? '')),
    userName: raw.name ?? raw.user_name ?? '',
    nickName: raw.name_show ?? raw.nick_name_new ?? raw.nickName ?? '',
  };
}

// ============================================================
// 1. 粉丝 / 关注列表 — aiotieba get_fans、get_follows（form JSON，20/页）
// ============================================================
// POST /c/u/fans/page       {BDUSS, _client_version, pn, uid}
// POST /c/u/follow/followList {BDUSS, _client_version, pn, uid}

async function fetchSocialList(
  path: string,
  uid: string,
  pn: number,
  signal?: AbortSignal,
): Promise<SocialListRes> {
  const raw = await postFormAction<any>(path, {
    pn: String(pn),
    uid,
  }, signal);
  const body = raw?.data ?? raw ?? {};
  const list = coalesceList(body, ['user_list', 'users', 'list']);
  return {
    items: list.map(mapSocialUser),
    hasMore: (body.has_more ?? body.hasMore ?? 0) === 1,
    currentPage: pn,
  };
}

/** 粉丝列表（20/页，pn 从 1 开始） */
export async function getFans(uid?: string, pn: number = 1, signal?: AbortSignal): Promise<SocialListRes> {
  return fetchSocialList('/c/u/fans/page', uid || getUidSync() || '', pn, signal);
}

/** 关注列表（20/页，pn 从 1 开始） */
export async function getFollows(uid?: string, pn: number = 1, signal?: AbortSignal): Promise<SocialListRes> {
  return fetchSocialList('/c/u/follow/followList', uid || getUidSync() || '', pn, signal);
}

// ============================================================
// 2. 黑名单查看 / 解除 — aiotieba get_blacklist、del_blacklist_old
// ============================================================
// POST /c/u/user/userBlackPage  {BDUSS, _client_version} → {user_list:[{uid,portrait,user_name,name_show,perm_list}]}
// POST /c/c/user/userMuteDel    {BDUSS, mute_user}        → 解除黑名单

export async function getBlacklist(signal?: AbortSignal): Promise<SocialUser[]> {
  const raw = await postFormAction<any>('/c/u/user/userBlackPage', {}, signal);
  const body = raw?.data ?? raw ?? {};
  const list = coalesceList(body, ['user_list', 'black_list', 'list']);
  return list.map((u: any) => {
    const perm = u.perm_list ?? {};
    const types: string[] = [];
    if (Number(perm.follow) === 1) types.push('FOLLOW');
    if (Number(perm.interact) === 1) types.push('INTERACT');
    if (Number(perm.chat) === 1) types.push('CHAT');
    return { ...mapSocialUser(u), btype: types.join(',') };
  });
}

/** 解除黑名单（对齐 aiotieba del_blacklist_old：mute_user 字段） */
export async function delBlacklist(userId: string): Promise<{ success: boolean }> {
  await postFormAction('/c/c/user/userMuteDel', {
    mute_user: userId,
  });
  return { success: true };
}

// ============================================================
// 3. 屏蔽吧列表查看 — aiotieba get_dislike_forums（proto cmd=309692）
// ============================================================
// proto: POST /c/u/user/getDislikeList?cmd=309692
// 复用 FormData/proto 通道会引入 CommonRequest 描述符；此处提供 form 兼容层。
// 说明：aiotieba 走 proto（GetDislikeListReqIdl），本工程 proto 通道对
//       /c/u/user 系无 CommonReq 描述符，故先用 form 降级实现并标注。

export interface DislikeForumItem {
  fid: string;
  fname: string;
  memberNum: number;
  postNum: number;
  threadNum: number;
}

/** 屏蔽吧条目统一映射（round-54 抽取；兼容 proto camelCase 键与 JSON snake_case 键） */
function mapDislikeForum(f: any): DislikeForumItem {
  return {
    fid: String(f.forumId ?? f.forum_id ?? f.fid ?? ''),
    fname: f.forumName ?? f.forum_name ?? f.fname ?? '',
    memberNum: Number(f.memberCount ?? f.member_count ?? 0),
    postNum: Number(f.postNum ?? f.post_num ?? 0),
    threadNum: Number(f.threadNum ?? f.thread_num ?? 0),
  };
}

export async function getDislikeForums(
  pn: number = 1,
  rn: number = 20,
  signal?: AbortSignal,
): Promise<{ items: DislikeForumItem[]; hasMore: boolean; currentPage: number }> {
  // 优先走 proto（对齐 aiotieba cmd=309692），失败降级 JSON form。
  try {
    const { protoGetDislikeList } = await import('../protoClient');
    const decoded = await protoGetDislikeList({ userId: getUidSync() || 0, pn, rn }, signal);
    const protoErr = (decoded as any)?.error;
    if (protoErr && Number(protoErr.error_code ?? protoErr.errorCode ?? 0) !== 0) {
      throw new Error(protoErr.error_msg ?? 'getDislikeList proto error');
    }
    const data = decoded.data ?? {};
    const list = Array.isArray(data.forumList) ? data.forumList : [];
    if (list.length > 0 || (data.hasMore ?? 0) > 0 || data.curPage) {
      return {
        items: list.map(mapDislikeForum),
        hasMore: (data.hasMore ?? 0) === 1,
        currentPage: pn,
      };
    }
    // proto 返回空则落 form 降级
  } catch (e) {
    if (__DEV__) console.warn('[getDislikeForums] proto failed, fallback:', e);
  }

  const raw = await postFormAction<any>(
    '/c/u/user/getDislikeList',
    { pn: String(pn), rn: String(rn) },
    signal,
  );
  const body = raw?.data ?? raw ?? {};
  const list = coalesceList(body, ['forum_list', 'dislike_list', 'list']);
  return {
    items: list.map(mapDislikeForum),
    hasMore: (body.has_more ?? body.hasMore ?? 0) === 1,
    currentPage: pn,
  };
}

// ============================================================
// 4. 头像上传 — aiotieba set_profile / Kotlin /c/c/img/portrait（multipart）
// ============================================================
// 复用现有 uploadClient/apiUpload（multipart/form-data）。
// @param uri  RN ImagePicker 返回的本地 uri；@param tbs 写操作 tbs。

export async function uploadPortrait(uri: string, tbs: string): Promise<{ success: boolean }> {
  const formData = new FormData();
  formData.append('portrait', { uri, name: 'portrait.jpg', type: 'image/jpeg' } as any);
  formData.append('tbs', tbs);
  formData.append('stoken', getStoken());
  await apiUpload('/c/c/img/portrait', formData);
  return { success: true };
}

// ============================================================
// 5. 吧成员 / 等级排行 — aiotieba get_member_users、get_rank_users（web HTML）
// ============================================================
// GET /bawu2/platform/listMemberInfo?word=&pn=&ie=utf-8 （最新关注）
// GET /f/like/furank?kw=&pn=&ie=utf-8                 （等级排行）
// 返回 HTML，需解析。提供原始 HTML + 基础解析（供 UI 层后续接入）。

export interface MemberUserItem {
  userName: string;
  portrait: string;
  level: number;
}

export async function getMemberUsers(
  fname: string,
  pn: number = 1,
  signal?: AbortSignal,
): Promise<{ html: string; items: MemberUserItem[] }> {
  const resp = await apiGetWeb<string>(
    '/bawu2/platform/listMemberInfo',
    { word: fname, pn: String(pn), ie: 'utf-8' },
    signal,
  );
  const html = typeof resp.data === 'string' ? resp.data : JSON.stringify(resp.data ?? '');
  return { html, items: parseMemberUsersHtml(html) };
}

/** 简单解析 memberInfo HTML（若服务端反爬导致结构变化，返回空数组由 UI 层容错） */
export function parseMemberUsersHtml(html: string): MemberUserItem[] {
  const items: MemberUserItem[] = [];
  try {
    const re = /<a[^>]*href="[^"]*tieba\.baidu\.com\/home\/main\?id=[^"]*"[^>]*title="([^"]+)"[^>]*><img[^>]*src="([^"]+)"/g;
    // 兜底：宽松匹配 title + img
    const re2 = /title="([^"]+)"[^>]*>\s*<\/a>/g;
    let m: RegExpExecArray | null;
    while ((m = re.exec(html)) !== null) {
      items.push({ userName: m[1], portrait: m[2], level: 0 });
    }
    // 若精确匹配为空，尝试宽松匹配（等级从 class 解析）
    if (items.length === 0) {
      while ((m = re2.exec(html)) !== null) {
        items.push({ userName: m[1], portrait: '', level: 0 });
      }
    }
  } catch {
    // 解析失败返回空数组
  }
  return items;
}

export interface RankUserItem {
  userName: string;
  level: number;
  exp: number;
  isVip: boolean;
}

export async function getRankUsers(
  fname: string,
  pn: number = 1,
  signal?: AbortSignal,
): Promise<{ html: string; items: RankUserItem[] }> {
  const resp = await apiGetWeb<string>(
    '/f/like/furank',
    { kw: fname, pn: String(pn), ie: 'utf-8' },
    signal,
  );
  const html = typeof resp.data === 'string' ? resp.data : JSON.stringify(resp.data ?? '');
  return { html, items: parseRankUsersHtml(html) };
}

/** 简单解析等级排行 HTML（结构不稳定时返回空数组，由 UI 层容错） */
export function parseRankUsersHtml(html: string): RankUserItem[] {
  const items: RankUserItem[] = [];
  try {
    const re = /drl_item_vip|bg_lv(\d+)|<td[^>]*>([^<]+)<\/td>/g;
    let m: RegExpExecArray | null;
    let pendingName = '';
    let pendingVip = false;
    while ((m = re.exec(html)) !== null) {
      if (m[1]) {
        const level = Number(m[1]);
        items.push({ userName: pendingName, level, exp: 0, isVip: pendingVip });
        pendingName = '';
        pendingVip = false;
      } else if (m[2]) {
        pendingName = m[2];
      } else if (html.slice(m.index - 40, m.index).includes('drl_item_vip')) {
        pendingVip = true;
      }
    }
  } catch {
    // 解析失败返回空数组
  }
  return items;
}

// ============================================================
// 6. 每日成长任务 — aiotieba sign_growth（web POST 需要 MISC_SALT 签名）
// ============================================================
// aiotieba request_web 走 /mo/q/usergrowth/commitUGTaskInfo，web 表单本身
// 依赖 MISC_SALT 签名（helper/crypto/const.py: MISC_SALT），本工程 JS 侧
// 无该签名实现 → 标注跳过，不硬做。若签名缺失不可用则直接抛错。

export async function signGrowth(_actType: string = 'page_sign'): Promise<{ success: boolean }> {
  // round-54：动态 import 改静态（顶部已导入 TiebaApiError，无循环依赖）
  throw new TiebaApiError(
    'signGrowth 未实现：/mo/q/usergrowth/commitUGTaskInfo 需要 MISC_SALT 签名，当前环境无法提供，已按评估跳过',
    501,
    501,
  );
}
