import { getTiebaError } from '../interceptors';
import { protoSearchSug } from '../protoClient';
import { searchClient } from '../searchClient';
import type {
  SearchForumResult,
  SearchPostResult,
  SearchThreadResult,
  SearchUserResult,
} from '@/types';
import { SearchThreadFilter, SearchThreadOrder } from '@/types';
// ============================================================
// Search — already aligned ✅
// ============================================================

function toArray(val: any): any[] { if (!val) return []; if (Array.isArray(val)) return val; return Object.values(val); }
function toExact(val: any): any | null { if (!val || Array.isArray(val)) return null; return val; }
const parseNum = (v: any): number => {
  if (v === undefined || v === null || v === '') return 0;
  const n = parseInt(String(v), 10);
  return Number.isFinite(n) ? n : 0;
};
// 多键候选取值统一走 utils/protoFields.pick（thermo Z6-B，全库单一出处）。
// 语义差异说明：canonical 版会跳过空串——对本文件的数值/名称字段是更安全的
// 行为（'' 视为缺失继续回退下一个键），消费端 parseNum/?? '' 均已兜底。
import { pick } from '@/utils/protoFields';
// ⚠️ 关注/帖子数必须取 *_ori 原始整数值：post_num/concern_num 是服务端格式化
// 缩写字符串（如 "7444W"、"20.1W"），push cmd parseInt 会得到错误数值
// （"484W"→484）。旧实现对缩写字符串 parseInt 导致搜索吧数量严重偏小。
const mapForumItem = (item: any): SearchForumResult => ({
  forumId: String(item.forum_id ?? item.forumId ?? ''),
  forumName: item.forum_name ?? item.forumName ?? '',
  avatar: item.avatar ?? '',
  memberCount: parseNum(pick(item, 'concern_num_ori', 'concernNumOri', 'concern_num', 'member_num', 'memberNum')),
  threadCount: parseNum(pick(item, 'post_num_ori', 'postNumOri', 'post_num', 'thread_num', 'threadNum')),
  isLike: (item.has_concerned ?? item.hasConcerned ?? 0) === 1,
});

export async function searchForum(keyword: string, signal?: AbortSignal): Promise<SearchForumResult[]> {
  const raw = (
    await searchClient.get<any>('/mo/q/search/forum', {
      params: { word: keyword },
      signal,
    })
  ).data;
  const data = raw.data ?? raw;
  const res: SearchForumResult[] = [];
  const exact = toExact(data.exact_match ?? data.exactMatch);
  if (exact) res.push(mapForumItem(exact));
  for (const item of toArray(data.fuzzy_match ?? data.fuzzyMatch ?? data)) res.push(mapForumItem(item));
  return res;
}

export async function searchThread(keyword: string, page: number = 1, order: SearchThreadOrder = SearchThreadOrder.NEW_FIRST, filter: SearchThreadFilter = SearchThreadFilter.ALL, signal?: AbortSignal): Promise<{ items: SearchThreadResult[]; hasMore: boolean; currentPage: number }> {
  const raw = (
    await searchClient.get<any>('/mo/q/search/thread', {
      params: { word: keyword, pn: page, st: order, tt: filter, rn: 20, ct: 1, cv: '99.9.101' },
      signal,
    })
  ).data;
  const data = raw.data ?? raw;
  const list: any[] = data.post_list ?? data.postList ?? [];
  return {
    items: list.map((i: any) => ({
      id: String(i.tid ?? ''),
      title: i.title ?? '',
      forumName: i.forum_name ?? i.forumInfo?.forum_name ?? '',
      forumAvatar: i.forum_info?.avatar ?? i.forumInfo?.avatar ?? '',
      authorName: i.user?.user_name ?? i.user?.userName ?? '',
      authorNameShow: i.user?.show_nickname ?? i.user?.showNickname ?? '',
      authorPortrait: i.user?.portrait ?? '',
      replyNum: parseInt(String(i.post_num ?? '0'), 10),
      likeNum: parseInt(String(i.like_num ?? '0'), 10),
      shareNum: parseInt(String(i.share_num ?? '0'), 10),
      createTime: (() => {
        // modified_time 可能是秒级时间戳，也可能是字符串日期（"2026-08-25 12:00:00"）；
        // 旧实现对字符串日期 parseInt 会得到 2026 这类垃圾值。统一 Number 守卫，
        // 非法/非正数一律 0（卡上以 >0 判断是否显示时间）。
        const t = Number(i.modified_time ?? '');
        return Number.isFinite(t) && t > 0 ? t : 0;
      })(),
      content: i.content ?? '',
      media: (i.media ?? []).map((m: any) => ({
        type: m.type ?? 'pic',
        width: parseInt(String(m.width ?? '0'), 10) || 300,
        height: parseInt(String(m.height ?? '0'), 10) || 300,
        bigPic: m.big_pic ?? m.bigPic ?? '',
        smallPic: m.small_pic ?? m.smallPic ?? '',
        waterPic: m.water_pic ?? m.waterPic ?? '',
        src: m.src ?? '',
        vsrc: m.vsrc ?? '',
      })),
      mainPost: i.main_post ? {
        title: i.main_post.title ?? '',
        content: i.main_post.content ?? '',
        user: i.main_post.user ? {
          userName: i.main_post.user.user_name ?? i.main_post.user.userName ?? '',
          showNickname: i.main_post.user.show_nickname ?? i.main_post.user.showNickname,
          userId: String(i.main_post.user.user_id ?? i.main_post.user.userId ?? ''),
          portrait: i.main_post.user.portrait ?? '',
        } : undefined,
        likeNum: i.main_post.like_num ?? i.main_post.likeNum,
        shareNum: i.main_post.share_num ?? i.main_post.shareNum,
        postNum: i.main_post.post_num ?? i.main_post.postNum,
        media: (i.main_post.media ?? []).map((m: any) => ({
          type: m.type ?? 'pic',
          width: parseInt(String(m.width ?? '0'), 10) || 300,
          height: parseInt(String(m.height ?? '0'), 10) || 300,
          bigPic: m.big_pic ?? m.bigPic ?? '',
          smallPic: m.small_pic ?? m.smallPic ?? '',
          waterPic: m.water_pic ?? m.waterPic ?? '',
          src: m.src ?? '',
          vsrc: m.vsrc ?? '',
        })),
      } : undefined,
      postInfo: i.post_info ? {
        tid: i.post_info.tid,
        pid: i.post_info.pid,
        title: i.post_info.title ?? '',
        content: i.post_info.content ?? '',
        user: i.post_info.user ? {
          userName: i.post_info.user.user_name ?? i.post_info.user.userName ?? '',
          showNickname: i.post_info.user.show_nickname ?? i.post_info.user.showNickname,
          userId: String(i.post_info.user.user_id ?? i.post_info.user.userId ?? ''),
          portrait: i.post_info.user.portrait ?? '',
        } : undefined,
      } : undefined,
    })),
    // Kotlin uses requested page+1 for currentPage tracking, NOT server response
    // Align: return requested page so store can use it directly
    hasMore: (data.has_more ?? 0) === 1,
    currentPage: page,
  };
}

export async function searchUser(keyword: string, signal?: AbortSignal): Promise<SearchUserResult[]> {
  const raw = (
    await searchClient.get<any>('/mo/q/search/user', {
      params: { word: keyword },
      signal,
    })
  ).data;
  const data = raw.data ?? raw;
  // fans_num 与 forum 的 concern_num/post_num 同源：服务端返回缩写字符串
  // （如 "1.2W"），parseInt 会得错误值；fans_num_ori 为原始整数，判据对齐
  // mapForumItem 的 *_ori 优先链（Kotlin SearchUserBean 未随仓，字段形态按
  // 此约定；勿对 fans_num 直接 parseInt——"484W"→484）。
  const mapUser = (item: any): SearchUserResult => ({
    uid: String(pick(item, 'id', 'user_id') ?? ''),
    name: pick(item, 'name', 'user_name', 'user_nickname') ?? '',
    nameShow: pick(item, 'show_nickname', 'name_show', 'name') ?? '',
    portrait: item.portrait ?? '',
    intro: item.intro ?? '',
    fansNum: parseNum(pick(item, 'fans_num_ori', 'fansNumOri', 'fans_num')),
  });
  const res: SearchUserResult[] = [];
  const exact = toExact(data.exact_match ?? data.exactMatch);
  if (exact) res.push(mapUser(exact));
  for (const item of toArray(data.fuzzy_match ?? data.fuzzyMatch ?? data.user_list ?? data)) res.push(mapUser(item));
  return res;
}

// ============================================================
// 吧内搜索 — 对齐 Kotlin ForumSearchPostViewModel.searchPostFlow →
// HYBRID_TIEBA_API.searchThreadFlow（GET /mo/q/search/thread）：
//   st = ForumSearchPostSortType（1=时间倒序, 2=相关性）
//   tt = ForumSearchPostFilterType（1=仅主题贴, 2=全部）
//   fname = 吧名限定 + ct=2（frs 入口）+ frs referer。
// 不再用遗留 POST /c/s/searchpost：旧实现传 sm=0（合法值 1/2），
// 服务端直接回 110001"未知错误"（8-25 真机实测）。
// ============================================================
export async function searchPost(
  keyword: string,
  forumName: string = '',
  page: number = 1,
  sortType: number = 1,
  filterType: number = 1,
  signal?: AbortSignal,
): Promise<{ items: SearchPostResult[]; hasMore: boolean }> {
  const raw = (
    await searchClient.get<any>('/mo/q/search/thread', {
      params: {
        word: keyword,
        pn: page,
        st: sortType,
        tt: filterType,
        rn: 30,
        fname: forumName,
        ct: 2,
        cv: '99.9.101',
      },
      headers: {
        Referer: `https://tieba.baidu.com/mo/q/hybrid-usergrow-search/searchGlobal?entryPage=frs&forumName=${encodeURIComponent(forumName)}&_client_version=99.9.101&_client_type=2`,
      },
      signal,
    })
  ).data;
  const d: any = raw.data ?? {};
  const list: any[] = Array.isArray(d) ? d : (d.post_list ?? d.postList ?? []);
  // 时间兜底统一：字符串日期（"2024-08-25 …"）parseInt 会得 2024 这类垃圾值，
  // 与 searchThread 的 modified_time 同款守卫（混合接口时间字段为 modified_time）。
  const parseTime = (v: unknown): number => {
    const t = Number(v ?? '');
    return Number.isFinite(t) && t > 0 ? t : 0;
  };
  return { items: list.map((i: any) => ({
    id: String(i.tid ?? ''),
    title: i.title ?? '',
    content: i.content ?? '',
    authorName: i.user?.user_name ?? '',
    authorId: String(i.user?.user_id ?? ''),
    forumName: i.forum_name ?? i.forumInfo?.forum_name ?? '',
    createTime: parseTime(i.modified_time ?? i.time),
    replyNum: parseInt(String(i.post_num ?? '0'), 10),
    // mo 搜索项带 pid/floor → 跳楼中楼深链（无则退化为进帖）
    postId: i.pid != null ? String(i.pid) : undefined,
    floor: i.floor != null ? Number(i.floor) : undefined,
  })), hasMore: !!(d.has_more ?? (list.length >= 30)) };
}

// ============================================================
// Search Suggestions — 对齐 Kotlin protobuf searchSug
// ============================================================
// Kotlin: POST /c/s/searchSug?cmd=309438&format=protobuf (V12, needSToken=true)

export async function searchSuggestions(keyword: string, isForum: boolean = false, signal?: AbortSignal): Promise<{ list: string[] }> {
  try {
    const decoded = await protoSearchSug({ word: keyword, isForum }, signal);
    if (getTiebaError(decoded)) {
      return { list: [] };
    }
    return {
      list: decoded.data?.list ?? [],
    };
  } catch (e) {
    // Fallback: return empty on network error
    if (__DEV__) console.warn('[searchSuggestions] failed:', e);
    return { list: [] };
  }
}


