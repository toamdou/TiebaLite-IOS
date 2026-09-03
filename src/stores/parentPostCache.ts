/**
 * 楼中楼页面（subposts）的上一级回复缓存。
 *
 * 从帖子页点「查看更多回复」跳转时，把被点击的那条回复（作者 + 全文 + 图片）
 * 临时存在模块级 Map 里，避免把富文本 content 塞进 URL query 参数
 * （超长、特殊字符、encode 易错）。subposts 页按 postId 取回渲染。
 * 仅存活于当前 JS 会话；整包 reload / 直接深链进入时未命中，会回退展示主楼卡。
 */
import type { PostInfo } from '@/types';

export interface ParentPostSummary {
  id: string;
  authorId: string;
  authorName: string;
  authorNameShow: string;
  authorPortrait: string;
  authorLevelId?: number;
  authorIsLz?: boolean;
  content: PostInfo['content'];
  createTime: number;
  ipLocation?: string;
}

/** 快照时效：超过该时长视为 miss（长时间挂机后回跳楼中楼，不应展示过期的上一级回复） */
const CACHE_TTL_MS = 30 * 60 * 1000;

interface ParentCacheEntry {
  summary: ParentPostSummary;
  cachedAt: number;
}

const cache = new Map<string, ParentCacheEntry>();
/** 有界缓存上限：满时驱逐最旧一条（Map 迭代序 = 插入序），避免会话内无限累积富文本 */
const CACHE_MAX_ENTRIES = 50;

export function cacheParentPost(
  post: Pick<PostInfo, 'id' | 'authorId' | 'authorName' | 'authorNameShow' | 'authorPortrait' | 'content' | 'createTime'> &
    Partial<Pick<PostInfo, 'authorLevelId' | 'authorIsLz' | 'ipLocation'>>,
) {
  if (!post?.id) return;
  if (cache.size >= CACHE_MAX_ENTRIES) {
    const oldest = cache.keys().next().value;
    if (oldest !== undefined) cache.delete(oldest);
  }
  cache.set(post.id, {
    cachedAt: Date.now(),
    summary: {
      id: post.id,
      authorId: post.authorId,
      authorName: post.authorName,
      authorNameShow: post.authorNameShow,
      authorPortrait: post.authorPortrait,
      authorLevelId: post.authorLevelId,
      authorIsLz: post.authorIsLz,
      content: post.content,
      createTime: post.createTime,
      ipLocation: post.ipLocation,
    },
  });
}

export function getParentPostSummary(postId?: string): ParentPostSummary | undefined {
  if (!postId) return undefined;
  const entry = cache.get(postId);
  if (!entry) return undefined;
  // 超龄条目视为 miss 并顺手移除（不占驱逐额度，语义与上限 50 一致）
  if (Date.now() - entry.cachedAt > CACHE_TTL_MS) {
    cache.delete(postId);
    return undefined;
  }
  return entry.summary;
}
