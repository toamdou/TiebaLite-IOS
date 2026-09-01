/**
 * Thread Page Actions（帖子详情页全部动作回调）。抽自 src/app/thread/[id].tsx
 * （4 抽 1 留拆分，#8）：
 * - 登录守卫统一 requireLogin 包装（未登录弹提示即返回）
 * - 点赞/收藏双击竞态：in-flight 守卫（在途期间吞掉重复点击，finally 释放）
 * - patchPost / setExtra / setPosts 由页面注入（持 posts/extra 状态的唯一
 *   持有者是 usePagedList，本 hook 不做第二份状态拷贝）
 * - addStore 核心供收藏动作共用（handleCollectFloor 随 onCollectFloor
 *   ghost prop 删除而移除）
 */

import { useCallback, useRef, type Dispatch, type MutableRefObject, type SetStateAction } from 'react';
import { useRouter } from 'expo-router';

import { agree as apiAgree, addStore, removeStore } from '@/services/api/endpoints/thread';
import { TiebaApiError } from '@/services/api/interceptors';
import { useThreadActions } from '@/services/threadActions';
import { hapticForScene } from '@/theme/hapticsMap';
import { saveFavoriteImages, removeFavoriteImages, imagesFromContent } from '@/services/storage/favoriteImages';
import { showToast } from '@/components/ui/Toast';
import type { PostInfo, ThreadInfo } from '@/types';

/** paged.extra 的 thread 页形状（与 usePagedList 泛型参数一致） */
export interface ThreadExtra {
  thread: ThreadInfo | null;
  total: number;
  current: number;
}

export type ThreadPatchPost = (postId: string, patch: (post: PostInfo) => Partial<PostInfo>) => void;

/** ConfirmationDialog 请求（visible 由页面侧统一置 true） */
export interface ConfirmRequest {
  title: string;
  message: string;
  onConfirm: () => void;
}

export interface UseThreadPageActionsOptions {
  id: string;
  isLoggedIn: boolean;
  thread: ThreadInfo | null;
  isCollected: boolean;
  setIsCollected: Dispatch<SetStateAction<boolean>>;
  patchPost: ThreadPatchPost;
  setExtra: (updater: (prev: ThreadExtra | null) => ThreadExtra | null) => void;
  setPosts: Dispatch<SetStateAction<PostInfo[]>>;
  /** 置顶主贴正文快照（收藏时把本帖图片快照到本地供收藏页缩略图） */
  mainPostContentRef: MutableRefObject<PostInfo['content'] | undefined>;
  /** 首楼 post id（帖级点赞的 post_id 用，Kotlin AgreeThread 传 firstPostId
   *  而非 threadId；缺省回退 threadId，与旧行为一致） */
  firstPostId?: string;
  showConfirm: (c: ConfirmRequest) => void;
}

export function useThreadPageActions({
  id,
  isLoggedIn,
  thread,
  isCollected,
  setIsCollected,
  patchPost,
  setExtra,
  setPosts,
  mainPostContentRef,
  firstPostId,
  showConfirm,
}: UseThreadPageActionsOptions) {
  const router = useRouter();
  const threadActions = useThreadActions({
    threadId: id,
    forumId: thread?.forumId,
    forumName: thread?.forumName,
    title: thread?.title,
  });
  const { share: shareAction, report: reportAction, remove: removeAction, copy: copyAction } = threadActions;

  // ── 登录守卫：未登录弹提示，返回 false 表示拦截（调用方直接 return）──
  const requireLogin = useCallback((): boolean => {
    if (isLoggedIn) return true;
    showToast('请先登录');
    return false;
  }, [isLoggedIn]);

  // ── in-flight 守卫：同一 key 的动作在途时吞掉重复点击（双击竞态）──
  const inFlight = useRef<Set<string>>(new Set());
  const runOnce = useCallback(async (key: string, action: () => Promise<void>) => {
    if (inFlight.current.has(key)) return;
    inFlight.current.add(key);
    try {
      await action();
    } finally {
      inFlight.current.delete(key);
    }
  }, []);

  /** “已点过赞/未点过赞”类状态翻转错误：目标态已达成，按成功处理 */
  const isAlreadyInTargetState = useCallback((e: unknown): boolean => {
    if (!(e instanceof TiebaApiError)) return false;
    return /点过赞/.test(e.message);
  }, []);

  /** 收藏/取消收藏（帖级） */
  const handleToggleCollect = useCallback(async () => {
    if (!requireLogin()) return;
    await runOnce('collect', async () => {
      try {
        if (isCollected) {
          await removeStore(id);
          void removeFavoriteImages(id);
          showToast('已取消收藏');
        } else {
          await addStore(id, firstPostId ?? id);
          // 收藏列表服务端不带图，把本帖正文图片快照到本地供收藏页缩略图显示
          void saveFavoriteImages(id, imagesFromContent(mainPostContentRef.current));
          showToast('已收藏');
        }
        setIsCollected((v) => !v);
        hapticForScene('action-success');
      } catch (e) {
        // 全量取证：TiebaApiError 的 code=服务端 error_code（日志 msg 兜底
        // 「未知错误」时只有 code 能定案；data 是原始响应体）
        if (__DEV__) {
          const err = e as { code?: number; data?: unknown } | null;
          console.warn(
            '[thread] toggleCollect ERR code=', err?.code, 'body=',
            err?.data ? JSON.stringify(err.data).slice(0, 300) : '',
            e,
          );
        }
        hapticForScene('action-fail');
        showToast(
          e instanceof TiebaApiError && e.message
            ? `${isCollected ? '取消收藏失败' : '收藏失败'}：${e.message}`
            : isCollected
              ? '取消收藏失败，请稍后重试'
              : '收藏失败，请稍后重试',
        );
      }
    });
  }, [requireLogin, runOnce, isCollected, id, firstPostId, mainPostContentRef, setIsCollected]);

  /** 乐观更新单个 post 的字段（按 id 匹配 prev state 中的当前项） */
  const handleAgree = useCallback(async (postId: string, opType: number) => {
    if (!requireLogin()) return;
    // opType 由 PostCard 依据当前卡片状态给出（1=赞，0=取消），
    // 不再读 posts 数组 —— 避免点赞 patch 引发整列表 renderPost 重建。
    await runOnce(`agree:${postId}`, async () => {
      try {
        await apiAgree(id, postId, opType, 1);
        patchPost(postId, (p) => ({
          isAgree: opType === 1,
          agreeNum: Math.max(0, p.agreeNum + (opType === 1 ? 1 : -1)),
        }));
        hapticForScene('like');
        // 成功 toast（2026-09-01：与信息流卡片同款底部药丸，此前只失败有）
        showToast(opType === 1 ? '点赞成功' : '已取消点赞');
      } catch (e) {
        if (__DEV__) console.warn('[thread] agree ERR postId=', postId, e);
        hapticForScene('action-fail');
        showToast('点赞失败，请稍后重试');
      }
    });
  }, [requireLogin, runOnce, id, patchPost]);

  /** Agree on the thread itself (from floating bar heart button) */
  const handleThreadAgree = useCallback(async () => {
    if (!requireLogin()) return;
    if (!thread) return;
    await runOnce('threadAgree', async () => {
      try {
        hapticForScene('like');
        // Kotlin AgreeThread 同构：post_id 用首楼 id（非 threadId）、obj_type=3
        const opType = thread.hasAgree ? 0 : 1;
        await apiAgree(id, firstPostId ?? id, opType, 3);
        setExtra((prev) => {
          const current = prev?.thread ?? thread;
          return {
            ...(prev ?? { thread: null, total: 0, current: 1 }),
            thread: current
              ? {
                  ...current,
                  hasAgree: !current.hasAgree,
                  zanNum: Math.max(0, (current.zanNum ?? 0) + (opType === 1 ? 1 : -1)),
                }
              : current,
          };
        });
        // 成功 toast（2026-09-01：帖底栏点赞此前无任何成功反馈）
        showToast(opType === 1 ? '点赞成功' : '已取消点赞');
      } catch (e) {
        // 2026-08-28：帖内点赞「没反应」已由 thread 同步修复（setExtra 不再被
        // repin 门控吞）；此处保留 code+body 取证，服务端状态类错误继续幂等处理
        if (__DEV__) {
          const err = e as { code?: number; data?: unknown } | null;
          console.warn(
            '[thread] threadAgree ERR code=', err?.code, 'body=',
            err?.data ? JSON.stringify(err.data).slice(0, 300) : '',
            e,
          );
        }
        // 服务端「您已经点过赞了/还没有点过赞」= 目标态已达成（幂等服务端
        // 状态翻转），视为成功并同步 UI（2026-08-27 日志实证：首次点赞后
        // UI/服务端状态不一致时二次点击返回该错误）
        if (isAlreadyInTargetState(e)) {
          const current = (prev: ThreadExtra | null) => prev?.thread ?? thread;
          setExtra((prev) => ({
            ...(prev ?? { thread: null, total: 0, current: 1 }),
            thread: { ...current(prev), hasAgree: !thread.hasAgree },
          }));
          return;
        }
        hapticForScene('action-fail');
        showToast('点赞失败，请稍后重试');
      }
    });
  }, [requireLogin, runOnce, id, thread, firstPostId, setExtra, isAlreadyInTargetState]);

  /** 举报：文案区分回复/主贴 */
  const handleReport = useCallback((postId?: string) => {
    const targetPostId = postId || id;
    const isReply = !!postId && postId !== id;
    showConfirm({
      title: isReply ? '举报回复' : '举报',
      message: isReply ? '确定要举报这条回复吗？' : '确定要举报这条帖子吗？',
      onConfirm: () => reportAction(targetPostId),
    });
  }, [id, reportAction, showConfirm]);

  /** 删除（主贴→返回上一页；回复→就地移除） */
  const handleDelete = useCallback((postId?: string) => {
    const targetPostId = postId || id;
    const deletingThread = !postId || postId === id;
    showConfirm({
      title: deletingThread ? '删除帖子' : '删除回复',
      message: deletingThread ? '确定要删除这条帖子吗？' : '确定要删除这条回复吗？',
      onConfirm: async () => {
        if (await removeAction(targetPostId)) {
          if (!deletingThread) {
            setPosts((prev) => prev.filter((p) => p.id !== targetPostId));
          } else {
            router.back();
          }
        }
      },
    });
  }, [id, removeAction, setPosts, router, showConfirm]);

  /** 复制链接：底栏单行药丸提示（用户要求统一在底栏上方，2026-08-27） */
  const handleCopyLink = useCallback(async () => {
    if (await copyAction()) {
      showToast('已复制');
    } else {
      showToast('复制失败');
    }
  }, [copyAction]);

  return {
    requireLogin,
    handleToggleCollect,
    handleAgree,
    handleThreadAgree,
    handleReport,
    handleDelete,
    handleCopyLink,
    shareAction,
  };
}