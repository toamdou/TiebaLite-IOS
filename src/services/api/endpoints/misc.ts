import { apiGetWeb, apiPost } from '../client';
import { TiebaApiError } from '../interceptors';
import {
  extractData,
  getStoken,
  postFormAction,
} from './helpers';
export async function submitDislike(params: {
  threadId: string;
  dislikeIds: string;   // comma-separated reason IDs
  forumId?: string;
  clickTime: number;    // timestamp millis
  extra?: string;       // comma-separated extra info
}): Promise<{ success: boolean }> {
  // 对齐 Kotlin DislikeBean(tid, dislike_ids, fid, click_time, extra)，序列化为 JSON 数组
  const bean = {
    tid: params.threadId,
    dislike_ids: params.dislikeIds,
    fid: params.forumId ?? '',
    click_time: params.clickTime,
    extra: params.extra ?? '',
  };
  await postFormAction('/c/c/excellent/submitDislike', {
    dislike: JSON.stringify([bean]),
    dislike_from: 'homepage',
    // 不带 stoken：见 thread.ts agree 注释（Web 落地页 stoken 对该通道无效，
    // 携带即被判 NOT_LOGIN，2026-08-27 Metro 实证）
  });
  return { success: true };
}

export async function checkReportPost(postId: string): Promise<string> {
  const body = extractData(await apiPost<any>('/c/f/ueg/checkjubao', {
    category: '1',
    pid: postId,
    // 对齐 Kotlin checkReport：@Field("stoken")=登录 sToken（缺省服务端当
    // 未登录，data.url 回空 →"不支持在线举报"假象；2026-09-01 二轮补）
    stoken: getStoken(),
  }));
  // Kotlin CheckReportBean.data.url；旧实现误读 data.report_url 恒空
  // → 所有内容一律"不支持在线举报"（2026-09-01 对照 Kotlin 实证修复）
  return body?.data?.url ?? body?.data?.report_url ?? '';
}

// Kotlin AppHybridTiebaApi topicDetail: GET /mo/q/newtopic/topicDetail
// Returns rich response with topic_info + thread_list from the Hybrid API
export async function topicDetail(topicId: string, topicName: string, page: number = 1, signal?: AbortSignal): Promise<any> {
  const raw = extractData(await apiGetWeb<any>(
    '/mo/q/newtopic/topicDetail',
    { topic_id: topicId, topic_name: topicName, is_new: '1', is_share: '1', pn: String(page), rn: '10' },
    signal,
  ));
  return raw?.data ?? raw;
}

export async function setUserBlack(blackUid: string, tbs: string, permList: string = '1,2,3'): Promise<{ success: boolean }> {
  if (!tbs) {
    throw new TiebaApiError('缺少 tbs，无法设置屏蔽', 400, 400);
  }
  await postFormAction('/c/c/user/setUserBlack', { black_uid: blackUid, tbs, perm_list: permList });
  return { success: true };
}

/** Unblock a user. Kotlin's block list uses an empty permission list to clear. */
export async function cancelUserBlack(blackUid: string, tbs: string): Promise<{ success: boolean }> {
  return setUserBlack(blackUid, tbs, '');
}
