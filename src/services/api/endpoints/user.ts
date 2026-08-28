import { apiPost, tiebaClient } from '../client';
import { protoProfile, protoUserPost } from '../protoClient';
import { getUidSync } from '@/services/storage/AuthSQLiteStorage';
import { assertProtoSuccess, extractData, mapForumInfo, postFormAction } from './helpers';
import { assertSuccessPayload } from '../interceptors';
import type { ForumInfo, UserProfile } from '@/types';
// ============================================================
// Profile — 对齐 Kotlin (POST, form-encoded)
// ============================================================
// Kotlin MiniTiebaApi: POST /c/u/user/profile {uid, need_post_count=1}
// Kotlin OfficialTiebaApi: POST /c/c/profile/modify {birthday_show_status, birthday_time, intro, sex, nick_name, stoken}
// Kotlin OfficialTiebaApi: POST /c/c/img/portrait (multipart, FORCE_LOGIN)

export async function profile(uid: string): Promise<UserProfile> {
  // Use protobuf API (mirrors Kotlin userProfileFlow)
  const selfUid = getUidSync() || '';
  const isSelf = selfUid === uid;

  const decoded = await protoProfile({
    selfUid: selfUid || uid,
    targetUid: uid,
    isSelf,
  });

  assertProtoSuccess(decoded);

  const u = decoded.data?.user ?? {};
  return {
    user: {
      id: String(u.id ?? u.uid ?? ''),
      name: u.name ?? u.user_name ?? '',
      nameShow: u.nameShow ?? u.name_show ?? u.show_nickname ?? u.showNickname ?? u.name ?? '',
      portrait: u.portrait ?? '',
      levelId: parseInt(String(u.levelId ?? u.level_id ?? '0'), 10),
      levelName: u.levelName ?? u.level_name ?? '',
      sex: parseInt(String(u.sex ?? u.gender ?? '0'), 10),
      intro: u.intro ?? '',
      fansNum: parseInt(String(u.fansNum ?? u.fans_num ?? '0'), 10),
      concernNum: parseInt(String(u.concernNum ?? u.concern_num ?? '0'), 10),
      postNum: parseInt(String(u.postNum ?? u.post_num ?? '0'), 10),
      totalAgreeNum: parseInt(String(u.totalAgreeNum ?? u.total_agree_num ?? '0'), 10),
      ipLocation: u.ipAddress ?? u.ip_address ?? u.ip_location ?? '',
      tbAge: parseFloat(String(u.tbAge ?? u.tb_age ?? '0')),
      isBawu: (u.isBawu ?? u.is_bawu) === 1,
      tiebaUid: String(u.tiebaUid ?? u.tieba_uid ?? u.id ?? uid),
      hasConcerned: parseInt(String(u.hasConcerned ?? u.has_concerned ?? '0'), 10),
      bazhuGrade: u.bazhuGrade ? { desc: String(u.bazhuGrade.desc ?? '') } : undefined,
      newGodData: u.newGodData ? {
        status: parseInt(String(u.newGodData.status ?? '0'), 10),
        fieldName: u.newGodData.fieldName ?? u.newGodData.field_name,
      } : undefined,
    },
    statue: {
      postsNum: parseInt(String(u.postNum ?? u.post_num ?? '0'), 10),
      concernForumsNum: parseInt(String(u.myLikeNum ?? u.my_like_num ?? '0'), 10),
    },
  };
}

export async function profileModify(params: Record<string, string | number | boolean>): Promise<{ success: boolean }> {
  await postFormAction('/c/c/profile/modify', params);
  return { success: true };
}

// ============================================================
// User Content — 对齐 Kotlin (POST, form-encoded)
// ============================================================
// Kotlin MiniTiebaApi: POST /c/u/feed/userpost {uid, pn, is_thread, rn=20, need_content=1}
// Kotlin MiniTiebaApi: POST /c/f/forum/like {page_no=1, page_size=50, uid, friend_uid, is_guest} (FORCE_LOGIN)

export async function userPost(uid: string, page: number = 1, isThread: boolean = false, signal?: AbortSignal): Promise<{ items: any[]; hasMore: boolean }> {
  try {
    const decoded = await protoUserPost({ uid, pn: page, isThread: isThread ? 1 : 0, needContent: 1 }, signal);
    assertProtoSuccess(decoded);
    const data = decoded.data;
    const content = data?.postList ?? [];
    return {
      items: content.map((i: any) => ({
        ...i,
        // 原生解码回传 camelCase（TiebaProtoProjector 白名单：threadId/postId/createTime；
        // 2026-08-25 修复：白名单曾缺 postId，postId 落不到 JS 侧），
        // JSON 回退路径是 snake_case（thread_id/post_id/create_time）。两种都读。
        // id 优先 postId：回复帖共享同一 thread_id，只读 threadId 时同一主题下所有
        // 回复 key 相同 → LegendList 只渲染 1 个 cell（key 退化）；threadId 保留供跳帖。
        // 注意：全部 miss 时映射为 ''（非 nullish）会短路 keyExtractor 的 ?? 链，
        // 所有 key 相同 → LegendList 只渲染 1 个 cell；keyExtractor 侧有空串防护兜底。
        id: String(i.postId ?? i.post_id ?? i.threadId ?? i.thread_id ?? i.id ?? ''),
        threadId: String(i.threadId ?? i.thread_id ?? i.postId ?? i.post_id ?? i.id ?? ''),
        createTime: Number(i.createTime ?? i.create_time ?? i.time ?? 0),
        // proto 路径 content 是 PostInfoContent 对象（postContent: Abstract[]，type 为数值），
        // 归一化为 contentToText 可读的片段数组，避免回复行正文恒空（JSON 路径保持透传）。
        content:
          typeof i.content === 'string'
            ? i.content
            : Array.isArray(i.content)
              ? i.content
              : (i.content?.postContent ?? []).map((s: any) => ({ type: 'text', text: s.text ?? '' })),
      })),
      // hasMore 与 Kotlin 分歧（有意为之）：Kotlin UserPostRepository 用
      // `post_list.isNotEmpty()` 判定翻页，末页恰好非空时会"非空→继续翻→非空"
      // 死循环；RN 侧改用「整页 20 条」判定，末页不满 20 条立即停翻。代价是
      // 整页恰满 20 条的末页会多发一次空页请求（返回空列表后 hasMore 即 false），
      // 可接受。
      hasMore: content.length >= 20,
    };
  } catch (e) {
    if (__DEV__) console.warn('[userPost] proto failed, fallback:', e);
    try {
      const raw = extractData(await apiPost<any>(
        '/c/u/feed/userpost',
        { uid, pn: String(page), is_thread: isThread ? '1' : '0', rn: '20', need_content: '1' },
        undefined,
        signal,
      ));
      // Kotlin UserPostBean 权威键：@SerializedName("post_list")，顶层下发
      //（旧实现读 raw.data.content 恒为空 → 兜底列表静默空白）。
      const content = raw?.post_list ?? raw?.data?.post_list ?? [];
      if (!Array.isArray(content)) {
        throw new Error('用户帖子列表解析失败');
      }
      return {
        // JSON 回退路径：服务端下发 snake_case（tid / create_time / time），UI 读 item.createTime 恒空。
        // 此处映射为 UI 读取的 camelCase：id ← tid ?? id、createTime ← create_time ?? time。
        // 注意：与 proto 路径一致，createTime 保持秒级（UI 侧按秒 *1000 消费，userPost 不走毫秒契约）。
        // 其余字段（title / content / forum_name 等）原样透传；映射字段放在展开后，保证始终生效。
        items: content.map((i: any) => ({
          ...i,
          id: String(i.tid ?? i.id ?? ''),
          threadId: String(i.tid ?? i.thread_id ?? i.id ?? ''),
          createTime: Number(i.create_time ?? i.time ?? 0),
        })),
        hasMore: (raw?.data?.has_more ?? raw?.has_more ?? 0) === 1,
      };
    } catch (fallbackErr) {
      // 兜底失败 rethrow：让 UI 走 ErrorState，而不是静默返回空列表伪装成"无内容"。
      if (__DEV__) console.warn('[userPost] JSON fallback failed:', fallbackErr);
      throw fallbackErr;
    }
  }
}

export async function userLikeForum(uid: string, page: number = 1, signal?: AbortSignal): Promise<{ items: ForumInfo[]; hasMore: boolean }> {
  // 对齐 Kotlin MixedTiebaApiImpl.userLikeForum：uid=自己、friend_uid=目标（看别人时）、
  // is_guest=1（看别人时）+ Force-Login: 1（Kotlin @Headers(FORCE_LOGIN)）。
  // 旧实现把目标塞进 uid 且缺 friend_uid/is_guest → 110001"未知错误"。
  const myUid = getUidSync() || '';
  const isSelf = myUid === uid;
  try {
    const response = await tiebaClient.post(
      '/c/f/forum/like',
      {
        page_no: String(page),
        page_size: '50',
        uid: myUid || undefined,
        friend_uid: isSelf ? undefined : uid,
        is_guest: isSelf ? undefined : '1',
      },
      { signal, headers: { 'Force-Login': '1' } },
    );
    const raw = extractData(response) as any;
    assertSuccessPayload(raw, false);
    const forumList = raw?.data?.forum_list ?? raw?.forum_list ?? [];
    return {
      // 新字段形状：forum_list 映射为 camelCase ForumInfo（旧实现透传 snake_case，UI 读 item.forumName / item.levelName 恒空）
      items: Array.isArray(forumList) ? forumList.map(mapForumInfo) : [],
      hasMore: (raw?.data?.has_more ?? raw?.has_more ?? 0) === 1,
    };
  } catch (e) {
    // 服务端对「未登录」与「对方隐私设置」都回 110001"未知错误"，裸透传体验差。
    // 按登录态映射为可读提示：已登录多为对方隐私设置，未登录则引导登录。
    const err = e as { errorCode?: number; code?: number; message?: string };
    const isGeneric = err?.errorCode === 110001 || err?.code === 110001 ||
      (err?.message ?? '').includes('未知错误');
    if (isGeneric) {
      throw new Error(
        myUid
          ? '由于对方的隐私设置，无法查看 TA 关注的吧'
          : '请先登录后查看 TA 关注的吧',
      );
    }
    throw e;
  }
}


