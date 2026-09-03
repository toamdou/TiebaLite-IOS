import { apiPost } from '../client';
import { TiebaApiError } from '../interceptors';
import { protoPbFloor, protoPbPage } from '../protoClient';
import { getUidSync } from '@/services/storage/AuthSQLiteStorage';
import { getStoken } from '@/services/api/authState';
import {
  assertProtoSuccess,
  extractData,
  mapProtoContent,
  mapProtoPosts,
  mapProtoThread,
  postFormAction,
  requireTbs,
  toMillis,
  type TiebaRes,
} from './helpers';
import type { FavoriteThread, PostInfo, SubPostInfo, ThreadInfo } from '@/types';

export async function pbPage(
  threadId: string, page: number = 1, postId?: string,
  seeLz: boolean = false, back: boolean = false, sortType: number = 0,
  signal?: AbortSignal,
): Promise<{ thread: ThreadInfo; posts: PostInfo[]; page: { current: number; total: number; hasMore: boolean } }> {
  const decoded = await protoPbPage({
    kz: threadId,
    pn: page,
    pid: postId,
    seeLz,
    back,
    sortType,
    // Kotlin proto pbPageFlow 的 st_type 默认空串（仅"提到我的/收藏"来源传非空值；
    // 'tb_frslist' 是 JSON 老接口的默认值，误用于 proto 端点会被服务端当特殊来源处理）。
    stType: '',
  }, signal);
  assertProtoSuccess(decoded);
  const data = decoded.data;
  // Kotlin PbPageRepository 兜底：首楼可能下发在 first_floor_post 而非 post_list。
  // ⚠️ 倒序（sortType=1）时服务端把楼主楼放 first_floor_post、回复放 post_list
  // ——原先仅 postList 空时读它，导致倒序时 posts[0]=最新回复被钉成主帖卡
  //（用户实测"回复内容跑到主帖子卡片里"）。改为恒并入并插头部（去重）：
  // 无论楼主楼在 post_list 还是 first_floor_post，posts[0] 恒为楼主楼。
  const rawPosts = data?.postList ?? [];
  let posts = rawPosts.length > 0
    ? mapProtoPosts(rawPosts, threadId, data?.userList ?? [])
    : [];
  const firstFloor = data?.firstFloorPost
    ? mapProtoPosts([data.firstFloorPost], threadId, data?.userList ?? [])[0]
    : undefined;
  if (firstFloor && !posts.some((p) => p.id === firstFloor.id)) {
    posts = [firstFloor, ...posts];
  }
  // hasMore 用 currentPage < totalPage 推导，而非服务端 hasMore 字段（同
  // pbFloor）：越界 pn 时服务端返回 current 递增 + totalPage 不变，若直信
  // hasMore 会把"越界页也算还有下一页"，配合 loadMore 守卫层叠失效。
  const curPage = data?.page?.currentPage ?? page;
  const totPage = data?.page?.totalPage ?? data?.page?.totalCount ?? 0;
  return {
    // ⚠️ mapProtoThread 的 opts 结构是 { forum }：直接传 forum 对象会读不到
    // forum.avatar/forum.id → 吧头像、吧名、forumId 全空（remote 版引入）。
    thread: mapProtoThread(data?.thread, { forum: data?.forum }),
    posts,
    page: {
      current: curPage,
      total: totPage,
      hasMore: totPage > 0 ? curPage < totPage : (data?.page?.hasMore ?? 0) === 1,
    },
  };
}

// Kotlin protobuf: POST /c/f/pb/floor?cmd=302002&format=protobuf (v12)
export async function pbFloor(
  threadId: string, postId: string, forumId: string, page: number = 1, subPostId?: string,
  signal?: AbortSignal,
): Promise<{ posts: SubPostInfo[]; page: { current: number; total: number; hasMore: boolean }; floorPost?: PostInfo }> {
  const decoded = await protoPbFloor({
    kz: threadId,
    pid: postId,
    pn: page,
    forumId: forumId || undefined,
    subPostId: subPostId || undefined,
  }, signal);
  assertProtoSuccess(decoded);
  const data = decoded.data;
  // 目标楼层本体（PbFloorResponseData.post = 3）：楼中楼页"上一级回复"卡的
  // 权威数据源——服务端随响应下发楼层完整内容（含图片/表情/头像/IP）。
  // 此前只依赖调用方预写快照（帖子页跳转才有），搜索/深链直达时无快照
  // → 回退空标题卡（用户实测"一片空白/无头像/无表情无图片"）。这里透传，
  // 页面优先用它；快照仅作 floorPost 缺失时的兜底。
  const floorPost = data?.post
    ? mapProtoPosts([data.post], threadId)[0]
    : undefined;
  const rawPosts = data?.subpostList ?? [];
  // Kotlin uses: page.current_page < page.total_page (NOT has_more field!)
  const pg = data?.page;
  const curPage = pg?.currentPage ?? page;
  const totPage = pg?.totalPage ?? 0;
  const computedHasMore = totPage > 0 ? curPage < totPage : (pg?.hasMore ?? 0) === 1;
  // 诊断（2026-09-02 临时，验完即删）：楼中楼 IP 属地不显示——打印原始
  // 楼层项的 location 与 author 结构，确认属地在 proto 解码后的实际键。
  if (__DEV__ && rawPosts.length > 0) {
    const probe = rawPosts[0];
    console.warn('[pbfloor-debug] keys=', Object.keys(probe ?? {}).slice(0, 25).join(','));
    console.warn('[pbfloor-debug] location=', JSON.stringify(probe?.location ?? null),
      'ip=', probe?.ip, 'ipLocation=', probe?.ipLocation,
      'author.ipAddress=', probe?.author?.ipAddress, 'author.IP=', probe?.author?.ip);
    if (probe?.author && typeof probe.author === 'object') {
      console.warn('[pbfloor-debug] author.keys=', Object.keys(probe.author).slice(0, 30).join(','));
      console.warn('[pbfloor-debug] author.sample=', JSON.stringify(probe.author).slice(0, 400));
    }
  }
  return {
    posts: rawPosts.map((item: any) => {
      // 判空内嵌 author（proto3 空对象 {} 问题，同 mapProtoThread/mapProtoPosts）
      const rawAuthor = item.author && typeof item.author === 'object' && Object.keys(item.author).length > 0
        ? item.author
        : undefined;
      const author = rawAuthor ?? {};
      return {
        id: String(item.id ?? ''),
        postId: String(item.postId ?? postId),
        authorId: String(item.authorId ?? author.id ?? ''),
        authorName: author.name ?? '',
        authorNameShow: author.nameShow ?? author.name ?? '',
        authorPortrait: author.portrait ?? '',
        authorLevelId: Number(author.levelId ?? 0) || undefined,
        content: mapProtoContent(item.content ?? []),
        createTime: toMillis(Number(item.time ?? 0)),
        replyToUserName: item.replyToUserName ?? '',
        // 楼中楼 IP 属地：proto 的 SubPostList.location 是 Lbs 对象
        // （lat/lng/name/sn/distance，**无 addr 字段**——SwiftProtobuf
        // ToJsonName 输出 location.name 属地文本）；author 内嵌 User 带
        // ip_address=127（ToJsonName→ipAddress）。多源兜底，缺一不阻断。
        ipLocation:
          item.location?.name ??
          item.location?.addr ??
          item.ip ??
          item.ipAddress ??
          author.ipAddress ??
          author.ip ??
          '',
        agreeNum: Number(item.agreeNum ?? item.agree?.agreeNum ?? 0),
        isAgree: (item.agree?.hasAgree ?? 0) === 1,
      };
    }),
    page: {
      current: curPage,
      total: totPage,
      hasMore: computedHasMore,
    },
    floorPost,
  };
}

// ============================================================
// Posts — 仅保留删除/互动/收藏。发帖/回复已按产品要求移除。
// ============================================================
// Kotlin: POST /c/c/bawu/delpost (FORCE_LOGIN)
export async function delPost(
  forumId: string, forumName: string, threadId: string, postId: string, isFloor: boolean = false,
): Promise<{ success: boolean }> {
  const data = extractData(await apiPost<TiebaRes<unknown>>('/c/c/bawu/delpost', {
    fid: forumId, word: forumName, z: threadId, pid: postId, isfloor: isFloor ? '1' : '0',
    src: '1', is_vipdel: '0', delete_my_post: '1', tbs: await requireTbs(),
  }));
  return { success: data.code === 0 };
}

// Kotlin: POST /c/c/bawu/delthread (FORCE_LOGIN)
export async function delThread(forumId: string, forumName: string, threadId: string): Promise<{ success: boolean }> {
  const data = extractData(await apiPost<TiebaRes<unknown>>('/c/c/bawu/delthread', {
    fid: forumId, word: forumName, z: threadId, src: '1', is_vipdel: '0', delete_my_thread: '1', tbs: await requireTbs(),
  }));
  return { success: data.code === 0 };
}

// ============================================================
// Interactions — 对齐 Kotlin (POST, form-encoded, FORCE_LOGIN)
// ============================================================
// Kotlin: POST /c/c/agree/opAgree (FORCE_LOGIN) {thread_id, post_id, agree_type=2, obj_type, op_type, tbs, stoken}
// MiniTiebaApi 参数语义：op_type 0=赞 / 1=取消（RN 侧 opType 1=赞 0=取消，
// 发送前翻转，2026-08-27 此前反向导致点赞报错）；obj_type 3=帖级（post_id
// 传首楼 id）/ 1=楼级，对齐 Kotlin AgreeThread objType=3 / AgreePost objType=1。
export async function agree(
  threadId: string,
  postId: string,
  opType: number = 1,
  objType: number = postId === threadId ? 3 : 1,
): Promise<{ success: boolean }> {
  // ⚠️ 不带 stoken（2026-08-27 Metro 实证）：所有携带 stoken 的写请求
  //（agree/addstore/threadstore…）被服务端判 error_code=1「用户未登录」，
  // 不带 stoken 的（sign/forumGuide）全部成功——RN 的 stoken 来自 Web 落地
  // 页 Cookie，对该 app 通道是无效凭证；对齐 aiotieba 通道 wire 形状
  //（其 opAgree 表单仅 BDUSS+_client_version+参数+sign）。
  await postFormAction('/c/c/agree/opAgree', {
    // stoken 恢复（2026-08-28）：Kotlin MiniTiebaApi.opAgreeFlow 权威带
    // stoken=AccountUtil.getSToken()（登录 Cookie 解析，与我们同源），官方
    // App 同款；8-27"stoken 毒"结论撤销——当时实验混在 op_type/obj_type
    // 修复批次里，实锤是其他参数；无 stoken 的 opAgree 命中服务端风控
    // 3280004「您操作的太频繁了」（本账号官方 App 可赞、我们全失败）。
    thread_id: threadId, post_id: postId, agree_type: '2',
    obj_type: String(objType),
    op_type: String(opType === 1 ? 0 : 1), tbs: await requireTbs(),
    stoken: getStoken() || undefined,
  });
  return { success: true };
}

export async function disagree(threadId: string, postId: string, opType: number = 1): Promise<{ success: boolean }> {
  await postFormAction('/c/c/agree/opAgree', {
    thread_id: threadId, post_id: postId, agree_type: opType ? '5' : '2', obj_type: '3', op_type: opType ? '1' : '0', tbs: await requireTbs(),
  });
  return { success: true };
}

// Kotlin: POST /c/c/user/follow (FORCE_LOGIN) {portrait, tbs, from_type=2, in_live=0}
export async function followUser(portrait: string, tbs: string): Promise<{ success: boolean }> {
  if (!tbs) {
    throw new TiebaApiError('缺少 tbs，无法关注', 400, 400);
  }
  await postFormAction('/c/c/user/follow', {
    portrait, tbs, from_type: '2', in_live: '0', authsid: 'null',
  });
  return { success: true };
}

// Kotlin: POST /c/c/user/unfollow (FORCE_LOGIN) {portrait, tbs, from_type=2, in_live=0}
export async function unfollowUser(portrait: string, tbs: string): Promise<{ success: boolean }> {
  if (!tbs) {
    throw new TiebaApiError('缺少 tbs，无法取消关注', 400, 400);
  }
  await postFormAction('/c/c/user/unfollow', {
    portrait, tbs, from_type: '2', in_live: '0', authsid: 'null', timestamp: String(Date.now()),
  });
  return { success: true };
}

// ============================================================
// Favorites — 对齐 Kotlin (POST, FORCE_LOGIN)
// ============================================================
// Kotlin: POST /c/f/post/threadstore (rn=50, offset=page*50, user_id=uid)
// Kotlin: POST /c/c/post/addstore (data=json, tbs, stoken)
// Kotlin: POST /c/c/post/rmstore (tid, tbs, fid=null)

/**
 * 收藏列表项（新字段形状，NOTIFICATIONS-ADAPTER / 收藏 UI 侧按此消费）。
 * 服务端 store_list 为 snake_case，此处统一映射为 camelCase：
 * - id / tid / threadId 三别名等价（tid 为服务端主键，跳转统一用 id）
 * - collectTime / updateTime 经 toMillis 统一转毫秒（兼容秒/毫秒下发，不乘 1000）
 * - 向后兼容：仍满足旧 FavoriteThread 形状，UI 旧的 item.id / title / floor 读取保持有效
 */
export interface FavoriteStoreItem extends FavoriteThread {
  /** 服务端原始帖子 id（与 id / threadId 等价） */
  tid: string;
  /** 帖子 id 别名（跳转用） */
  threadId: string;
  /** 所属吧 id（forum_id） */
  forumId: string;
  /** 服务端 is_read（1 / '1' / true 已读） */
  isRead: boolean;
}

/** 映射服务端 store_list 单条（snake_case）为 UI camelCase 形状。 */
export function mapStoreItem(item: any): FavoriteStoreItem {
  const tid = String(item.tid ?? item.id ?? item.thread_id ?? '');
  return {
    id: tid,
    tid,
    threadId: String(item.thread_id ?? item.tid ?? item.id ?? tid),
    title: item.title ?? item.thread_title ?? '',
    forumName: item.forum_name ?? item.forumName ?? item.fname ?? '',
    forumId: String(item.forum_id ?? item.forumId ?? item.fid ?? ''),
    authorName: item.author?.name_show ?? item.author?.name ?? item.author_name ?? item.authorName ?? '',
    authorPortrait: item.author?.user_portrait ?? item.author?.portrait ?? '',
    postId: String(item.post_id ?? item.postId ?? item.pid ?? ''),
    floor: Number(item.floor ?? 0),
    collectTime: toMillis(Number(item.collect_time ?? item.collectTime ?? 0)),
    updateTime: toMillis(Number(item.update_time ?? item.updateTime ?? 0)),
    latestReplyNum: Number(item.latest_reply_num ?? item.latestReplyNum ?? 0),
    isRead: item.is_read === 1 || item.is_read === '1' || item.is_read === true || item.isRead === 1 || item.isRead === true,
  };
}

export async function threadStore(page: number = 0, signal?: AbortSignal): Promise<{ items: FavoriteStoreItem[]; hasMore: boolean }> {
  // 调用方 usePagedList initialPage=1，实际首页请求 p=1 → offset=0（第 0 页被
  // 请求）；p=0 的旧入口保留兼容（同样落到 offset=0，与服务端 offset 语义一致，
  // 勿改公式）。
  const offset = Math.max(0, (page - 1)) * 50;
  // Kotlin OfficialTiebaApi: threadStoreFlow(rn, offset, user_id)
  const raw = await postFormAction<any>('/c/f/post/threadstore', {
    rn: '50', offset: String(offset), user_id: getUidSync() || '',
  }, signal);
  const storeList = raw?.data?.store_list ?? raw?.store_list ?? raw?.store_thread ?? [];
  // 取证：收藏页空列表的唯一直接证据在响应体（store_list 字段名/条数）
  if (__DEV__) {
    console.warn(
      '[store] threadstore res=', JSON.stringify(raw).slice(0, 300),
      'items=', Array.isArray(storeList) ? storeList.length : 'not-array',
    );
  }
  return {
    // 新字段形状：store_list 映射为 camelCase（旧实现直接透传 snake_case，UI 读 item.title 等恒空、formatCount(undefined) 崩溃、keyExtractor 全 undefined）
    items: Array.isArray(storeList) ? storeList.map(mapStoreItem) : [],
    hasMore: (raw?.data?.has_more ?? raw?.has_more ?? 0) === 1,
  };
}

export async function addStore(threadId: string, postId?: string): Promise<{ success: boolean }> {
  // Kotlin NewCollectDataBean(tid, pid, status) 逐字段对照：无 cid；
  // status 为收藏置位 1（int）；pid 传首楼 id（Kotlin AddFavorite 传 it.id），
  // 缺省 '0'。旧实现带 cid 且 status:'0' → 服务端「未知错误」（2026-08-27 日志）
  const dataObj = JSON.stringify([{ tid: threadId, pid: postId ?? '0', status: 1 }]);
  const res = await postFormAction<any>('/c/c/post/addstore', { data: dataObj });
  // 取证（2026-08-28）：addstore 常返回「伪成功」——服务端 error_code=0 但
  // 收藏未入库（缺 stoken 嫌疑）。响应体是本问题的唯一直接证据。
  if (__DEV__) console.warn('[store] addstore res=', JSON.stringify(res).slice(0, 300));
  return { success: true };
}

export async function removeStore(threadId: string): Promise<{ success: boolean }> {
  // Kotlin OfficialTiebaApi: removeStoreFlow(tid, fid="null", tbs, user_id)
  await postFormAction('/c/c/post/rmstore', {
    tid: threadId, fid: 'null', tbs: await requireTbs(), user_id: getUidSync() || '',
  });
  return { success: true };
}
