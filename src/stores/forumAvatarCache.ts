// 全站统一吧头像缓存（2026-08-28 统一化）
// 服务端 thread.forumInfo 恒 null（wire 实证）不发吧头像，各页头像来源分散：
// 已关注吧（forumFollowed 缓存）、未关注吧（/mo/q/search/forum 实时拉）、
// 历史 DB avatar 列、搜索帖 forum_info（时有时无）——统一收敛到本 store：
//   * 键 = forumId（String 化）；forumId 缺失（搜索帖/部分历史）退化为
//     `n:${forumName}` 名键，保证全站同一条目
//   * 每次 ensureAvatars 先查已关注缓存（同步、零网络），未命中才发
//     搜索接口（在途去重 + 并发 2 + 每吧间隔 120ms 防风控；失败静默）
//   * 内存 + MMKV 磁盘双层；磁盘**不自动清理**（用户需求：只能经由
//     设置页「清除图片缓存」手动清空，见 clearForumAvatarCache）
//
// 消费页：动态流 FeedContent、历史 history.tsx、收藏 threadstore.tsx、
// 搜索帖 SearchResultList；渲染侧订阅 avatars，缺失期间保持灰底兜底。

import { create } from 'zustand';
import { kvGetSync, kvSetSync } from '@/services/storage/unifiedDb';
import { getCachedForumsMap } from '@/services/forumFollowed';

const DISK_KEY = 'forum_avatars_v1';
const CONCURRENCY = 2;
const PER_FORUM_DELAY_MS = 120;

interface AvatarEntry {
  avatar: string;
  /** 记录写入时间（仅诊断；磁盘条目不按此清理） */
  ts: number;
}

export type AvatarMap = Record<string, AvatarEntry>;

/** 统一键：forumId 优先（String 化），缺失退化吧名键 */
export function forumAvatarKey(it: { forumId?: string | number | null; forumName?: string }): string | null {
  const id = it.forumId;
  if (id !== undefined && id !== null) {
    const s = String(id).trim();
    if (s && s !== '0') return s;
  }
  const name = it.forumName?.trim();
  return name ? `n:${name}` : null;
}

interface ForumAvatarState {
  avatars: AvatarMap;
  /** 幂等补齐（已缓存/在途跳过；异步不阻塞渲染） */
  ensureAvatars: (items: { forumId?: string | number | null; forumName?: string }[]) => void;
}

let diskLoaded = false;
const inflight = new Set<string>();

function loadDiskCache(): AvatarMap {
  try {
    const raw = kvGetSync(DISK_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw) as AvatarMap;
    const fresh: AvatarMap = {};
    for (const [id, e] of Object.entries(parsed)) {
      if (e && typeof e.avatar === 'string' && e.avatar) fresh[id] = e;
    }
    return fresh;
  } catch {
    return {};
  }
}

function persistDiskCache(avatars: AvatarMap): void {
  try {
    kvSetSync(DISK_KEY, JSON.stringify(avatars));
  } catch {
    // best-effort：写失败仅失去冷启动加速
  }
}

function commitAvatar(key: string, avatar: string, logMsg: string): void {
  useForumAvatarStore.setState((s) => {
    if ((s.avatars[key]?.avatar) === avatar) return s;
    const next = { ...s.avatars, [key]: { avatar, ts: Date.now() } };
    persistDiskCache(next);
    return { avatars: next };
  });
  if (__DEV__) console.warn(`[avatar] ${logMsg}`);
}

/** 设置页手动清理入口（并入「清除图片缓存」）：内存 + 磁盘一次性清空，
 *  之后各页按需重新拉取；不参与任何自动清理（cacheAutoCleanDays 只触
 *  图片缓存，本键仅经此函数删除）。 */
export function clearForumAvatarCache(): void {
  inflight.clear();
  diskLoaded = false;
  try {
    kvSetSync(DISK_KEY, '{}');
  } catch {
    // best-effort
  }
  useForumAvatarStore.setState({ avatars: {} });
  if (__DEV__) console.warn('[avatar] 吧头像缓存已手动清空');
}

export const useForumAvatarStore = create<ForumAvatarState>((set, get) => ({
  avatars: {},

  ensureAvatars: (items) => {
    if (items.length === 0) return;
    if (!diskLoaded) {
      diskLoaded = true;
      const disk = loadDiskCache();
      if (Object.keys(disk).length > 0) set({ avatars: { ...disk, ...get().avatars } });
    }

    // 已关注缓存直查（零网络）：forumFollowed 内存 5min/磁盘 24h，
    // 命中即入本 store——关注/取消关注天然实时同步到全站头像。
    const followed = getCachedForumsMap();
    for (const it of items) {
      const key = forumAvatarKey(it);
      if (!key || get().avatars[key] || inflight.has(key)) continue;
      const avatar = followed.get(String(it.forumId ?? ''))?.avatar;
      if (avatar) {
        commitAvatar(key, avatar, `已关注缓存回填 ${it.forumName ?? key}`);
      }
    }

    const pending = items.filter((it) => {
      const key = forumAvatarKey(it);
      return key && !get().avatars[key] && !inflight.has(key);
    });
    if (pending.length === 0) return;

    let cursor = 0;
    const worker = async () => {
      while (cursor < pending.length) {
        const item = pending[cursor++];
        const key = forumAvatarKey(item);
        if (!key) continue;
        inflight.add(key);
        try {
          const { searchForum } = await import('@/services/api/endpoints/search');
          const results = await searchForum(item.forumName ?? '');
          // 按吧名精确匹配（dynamic feed 的 forumName 与 exact_match.forum_name
          // 同源），避免 forumId 类型形态（string/number）差异误配
          const hit = results.find((r) => r.forumName === item.forumName) ?? results[0];
          const avatar = hit?.avatar ?? '';
          if (avatar) {
            commitAvatar(key, avatar, `实时拉取 ${item.forumName} 头像`);
          }
        } catch (e) {
          // 静默：拉取失败保持灰底兜底，下次进入重试
          if (__DEV__) console.warn(`[avatar] 拉取 ${item.forumName} 失败（可忽略）:`, String(e));
        } finally {
          inflight.delete(key);
        }
        if (cursor < pending.length) {
          await new Promise((r) => setTimeout(r, PER_FORUM_DELAY_MS));
        }
      }
    };

    for (let i = 0; i < Math.min(CONCURRENCY, pending.length); i++) void worker();
  },
}));