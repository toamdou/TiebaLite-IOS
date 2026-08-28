import { apiPost } from '../client';
import { extractData, postFormAction, toMillis } from './helpers';
import type { MessageItem, NotificationCount } from '@/types';
// ============================================================
// Messages — 对齐 Kotlin NewTiebaApi (POST, FORCE_LOGIN)
// ============================================================
// Kotlin: POST /c/s/msg (bookmark=1)
// Kotlin: POST /c/u/feed/replyme (pn=0)
// Kotlin: POST /c/u/feed/atme (pn=0)
// Kotlin: POST /c/u/feed/agreeme (pn=0)
//
// 消息 proto 化评估：replyMe/atMe/agreeMe 的 proto（ReplyMe.proto cmd=303007 族）
// 依赖 ReplyList/User/Zan 等大量嵌套描述符，工程量与验证成本高；
// 按任务授权"至少保留现有 JSON 实现并新增 GetMoreMsg 分类查询"执行。
// 现有 JSON 实现全部保留，另新增 getMoreMsg 分类查询。

export async function msg(): Promise<NotificationCount> {
  const body = extractData(await apiPost<any>('/c/s/msg', { bookmark: '1' }));
  // 计数解码（8-28 修正）：对齐 Kotlin MsgBean —— 计数在顶层 `message`
  // 对象、键为 replyme/atme（无 data 包装、无 reply/at 键）；旧实现读
  // body.data.reply/at/agree 恒为 undefined → 计数/角标/推送增量全部静默失效。
  // 此处兼容 message 包装 / data 包装 / 平铺三种形状。
  const raw = body?.message ?? body?.data ?? body ?? {};
  const count = (key: string, alt: string): number => {
    const n = Number(raw?.[key] ?? raw?.[alt]);
    return Number.isFinite(n) && n > 0 ? n : 0;
  };
  const reply = count('replyme', 'reply');
  const at = count('atme', 'at');
  const agree = count('agreeme', 'agree');
  return { reply, at, agree, total: reply + at + agree };
}

export type MsgCategory = 'reply' | 'at' | 'agree';

/**
 * 映射服务端消息单条（snake_case）为 UI MessageItem（camelCase）。
 * 服务端 reply_list / at_list / agree_list 字段命名不完全一致，统一用 ?? 容错
 * （同时兼容 snake_case 与 camelCase）：
 * - user_id → fromUserId、user_name → fromUserName、user_portrait → fromUserPortrait
 * - thread_id → threadId、thread_title → threadTitle、post_id → postId
 * - is_read → isRead（兼容 1 / '1' / true）
 * - unread → isRead（权威：Kotlin MessageInfoBean.unread / ReplyList.proto
 *   字段 11 unread；旧实现只读 is_read 恒不命中，未读圆点永不显示。值为
 *   '0'/'1' 字符串或 0/1，'1'=未读 → isRead=false）
 * - time / create_time / reply_time / agree_time → createTime（toMillis 统一毫秒，不乘 1000）
 */
export function mapMessageItem(raw: any, type: MessageItem['type'] = 'reply'): MessageItem {
  if (!raw || typeof raw !== 'object') {
    return {
      id: '', type, fromUserId: '', fromUserName: '', fromUserPortrait: '',
      threadId: '', threadTitle: '', content: '', createTime: 0, isRead: false,
    };
  }
  const threadId = String(raw.thread_id ?? raw.threadId ?? raw.tid ?? '');
  const postId = raw.post_id ?? raw.postId ?? raw.pid;
  // 用户信息在 replyer 子对象（对齐 Kotlin MessageInfoBean：replyer.id/name/
  // name_show/portrait）；旧实现只读平铺 user_id 等，行内作者恒空。
  const replyer = raw.replyer ?? raw.replyer_info;
  return {
    id: String(raw.id ?? raw.reply_id ?? raw.msg_id ?? (threadId && postId != null ? `${threadId}_${postId}` : threadId) ?? ''),
    type,
    fromUserId: String(replyer?.id ?? raw.user_id ?? raw.userId ?? raw.from_user_id ?? raw.fromUserId ?? raw.uid ?? ''),
    fromUserName: replyer?.name_show ?? replyer?.name ?? raw.user_name ?? raw.userName ?? raw.name ?? '',
    fromUserPortrait: replyer?.portrait ?? raw.user_portrait ?? raw.userPortrait ?? raw.portrait ?? '',
    threadId,
    threadTitle: raw.thread_title ?? raw.threadTitle ?? raw.title ?? '',
    postId: postId != null ? String(postId ?? '') : undefined,
    content: raw.content ?? raw.reply_content ?? raw.replyContent ?? raw.summary ?? '',
    createTime: toMillis(Number(raw.time ?? raw.create_time ?? raw.createTime ?? raw.reply_time ?? raw.agree_time ?? 0)),
    // unread 权威（ReplyList.proto 字段 11 / Kotlin MessageInfoBean.unread，'1'=未读）；
    // is_read/isRead 仅为旧形状兼容。
    isRead: !(
      raw.unread === 1 || raw.unread === '1' || raw.unread === true ||
      raw.is_read === 1 || raw.is_read === '1' || raw.is_read === true ||
      raw.isRead === 1 || raw.isRead === '1' || raw.isRead === true
    ),
  };
}

export async function replyMe(page: number = 0, signal?: AbortSignal): Promise<{ items: MessageItem[]; hasMore: boolean }> {
  const raw = await postFormAction<any>('/c/u/feed/replyme', { pn: String(page) }, signal);
  const list = raw?.data?.reply_list ?? raw?.reply_list ?? [];
  return {
    // 新字段形状：reply_list 映射为 camelCase MessageItem（旧实现透传 snake_case，UI 读 item.fromUserId / item.createTime 等恒空）
    items: Array.isArray(list) ? list.map((i: any) => mapMessageItem(i, 'reply')) : [],
    // has_more 在 page 子对象（对齐 Kotlin PageInfoBean），值为 '1'/'0' 字符串
    hasMore: hasMoreFlag(raw),
  };
}

export async function atMe(page: number = 0, signal?: AbortSignal): Promise<{ items: MessageItem[]; hasMore: boolean }> {
  const raw = await postFormAction<any>('/c/u/feed/atme', { pn: String(page) }, signal);
  const list = raw?.data?.at_list ?? raw?.at_list ?? [];
  return {
    // 新字段形状：at_list 映射为 camelCase MessageItem
    items: Array.isArray(list) ? list.map((i: any) => mapMessageItem(i, 'at')) : [],
    hasMore: hasMoreFlag(raw),
  };
}

export async function agreeMe(page: number = 0, signal?: AbortSignal): Promise<{ items: MessageItem[]; hasMore: boolean }> {
  const raw = await postFormAction<any>('/c/u/feed/agreeme', { pn: String(page) }, signal);
  const list = raw?.data?.agree_list ?? raw?.agree_list ?? [];
  return {
    // 新字段形状：agree_list 映射为 camelCase MessageItem
    items: Array.isArray(list) ? list.map((i: any) => mapMessageItem(i, 'agree')) : [],
    hasMore: hasMoreFlag(raw),
  };
}

/** has_more 读取：兼容 page.has_more / data.page.has_more / 顶层 has_more，值为 '1'/'0' 或 1/0 */
function hasMoreFlag(raw: any): boolean {
  const v = raw?.data?.page?.has_more ?? raw?.page?.has_more ?? raw?.data?.has_more ?? raw?.has_more;
  return v === '1' || v === 1 || v === true;
}

/**
 * GetMoreMsg 分类查询：按 category 只拉当前分类对应接口，hasMore 只取当前分类。
 * 说明：GetMoreMsg proto（GetMoreMsgReqIdl）仅有 common 字段、数据体在
 * MsgContent 中为文本类，价值有限；此处按任务授权先落地 JSON 分类查询，
 * 后续如需 proto 化再补描述符（CMD=303017 待真机验证）。
 *
 * !!! NOTIFICATIONS-ADAPTER !!!
 * 签名已从 getMoreMsg(page, signal) 变更为 getMoreMsg(category, page, signal)：
 * - notifications.tsx 的 usePagedList fetcher 需改为按当前分段传入 category，
 *   例如 getMoreMsg(params.type, p - 1, signal)，并移除 items.filter(i => i.category === params.type) 过滤。
 * - 返回值不再包含 counts（未读数请单独调用 msg() / loadNotificationCounts()）。
 * - hasMore 只反映当前分类的翻页状态（原实现三源或合并，分类耗尽后会空翻页）。
 */
// round-54：三分支改表驱动（分类 → 拉取函数）
const CATEGORY_FETCHERS: Record<MsgCategory, (page: number, signal?: AbortSignal) => Promise<{ items: MessageItem[]; hasMore: boolean }>> = {
  reply: replyMe,
  at: atMe,
  agree: agreeMe,
};

export async function getMoreMsg(
  category: MsgCategory,
  page: number = 0,
  signal?: AbortSignal,
): Promise<{ items: (MessageItem & { category: MsgCategory })[]; hasMore: boolean }> {
  const res = await CATEGORY_FETCHERS[category](page, signal);
  return {
    items: res.items.map((i) => ({ ...i, category })),
    hasMore: res.hasMore,
  };
}



