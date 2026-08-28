/**
 * useFeedCardActions — 信息流/列表卡片动作四件套的全库唯一实现
 * （thermo 2026-08-26 Z3-B/Z4-B/Z5-D：此前 explore / 吧页 / 话题页 / 搜索页
 * 各持一份 like/share/block/report 处理器，且点赞连点防竞态策略四页四种。
 * 本 hook 以「ref 镜像优先、页面可注入更新基准」为唯一竞态策略）。
 *
 * 页面只需注入两个回调：
 * - applyLike(id, targetAgree)：把 id 项翻到目标点赞态并调整计数
 *  （在函数式 setState 内读当前值做 ±1 钳制，回滚即以相反 target 再调一次）；
 * - removeByAuthor(authorId)：屏蔽作者后把其帖子从列表移除。
 *
 * 行为统一点（相对各旧实现的差异，均为改善）：
 * - 未登录一律跳登录页（吧页/话题页此前是 Alert 提示）；
 * - 点赞先乐观更新、失败回滚（吧页此前是请求成功后才 patch）；
 * - 分享文案 = 标题\nURL 单条目（与 services/threadActions 同规范）。
 */

import { useCallback, useRef } from 'react';
import { Alert, Share } from 'react-native';
import { useRouter } from 'expo-router';
import * as Clipboard from 'expo-clipboard';

import { agree } from '@/services/api/endpoints/thread';
import { checkReportPost } from '@/services/api/endpoints/misc';
import { TiebaApiError } from '@/services/api/interceptors';
import { BlockManager } from '@/utils/BlockManager';
import { buildThreadUrl } from '@/utils';
import { hapticForScene } from '@/theme/hapticsMap';
import { useAuthStore } from '@/stores/authStore';
import { showToast } from '@/components/ui/Toast';

/**
 * 卡片动作的最小目标形状：ThreadInfo / SearchThreadResult 等列表行结构均可
 * 直接传入（结构性兼容），hook 只消费 id/title/点赞态/作者字段。
 */
export interface FeedCardTarget {
  id: string;
  title?: string | null;
  hasAgree?: boolean;
  /** 帖 id（ThreadInfo.proto 字段 2；缺省回退 id）——opAgree thread_id 用 */
  threadId?: string;
  /** 首楼 post id（ThreadInfo.proto 字段 40）——帖级点赞 opAgree post_id 必须用它 */
  firstPostId?: string;
  authorId?: string;
  authorName?: string | null;
  authorNameShow?: string | null;
}

export interface UseFeedCardActionsOptions {
  /** 点赞乐观写入（失败时以相反 target 再次调用即完成回滚） */
  applyLike: (id: string, targetAgree: boolean) => void;
  /** 屏蔽作者成功后移除其帖子（不传则只写黑名单不动列表） */
  removeByAuthor?: (authorId: string) => void;
  /**
   * 点赞竞态基准：从列表最新数据读当前 hasAgree（推荐——页面已有 itemsRef
   * 或可直接读 store）；未提供时使用 hook 内部镜像（跨刷新可能过期，
   * 但刷新后首次点击会以 item.hasAgree 兜底）。
   */
  getLatestHasAgree?: (id: string) => boolean | undefined;
}

export function useFeedCardActions(options: UseFeedCardActionsOptions) {
  const router = useRouter();
  const isLoggedIn = useAuthStore((s) => s.isLoggedIn);
  // 点赞态镜像（thermo 统一策略）：每次乐观翻转同步写入，快速连点的第二次
  // 点击读到的是已翻转的新值，请求参数正确取反；失败回滚镜像。
  const likeMirrorRef = useRef<Map<string, boolean>>(new Map());

  const requireLogin = useCallback((): boolean => {
    if (isLoggedIn) return true;
    router.push('/login');
    return false;
  }, [isLoggedIn, router]);

  /** 点赞/取消点赞（乐观更新 + 失败回滚） */
  const like = useCallback(
    async (thread: FeedCardTarget) => {
      if (!requireLogin()) return;
      const latest =
        options.getLatestHasAgree?.(thread.id) ??
        likeMirrorRef.current.get(thread.id) ??
        thread.hasAgree ??
        false;
      const nextAgree = !latest;
      likeMirrorRef.current.set(thread.id, nextAgree);
      hapticForScene('like');
      options.applyLike(thread.id, nextAgree);
      try {
        // Kotlin 同构（PersonalizedPage/ConcernPage/HotPage/ForumThreadListPage 全链路）：
        //   thread_id = ThreadInfo.threadId（字段 2）、post_id = ThreadInfo.firstPostId
        //   （字段 40，首楼 id）、obj_type = 3（帖级 — 必须显式传，post_id=firstPostId
        //   ≠ thread_id 时端点默认值会误判成楼级 1）、op_type 取反（RN opType 1=赞 →
        //   服务端 0）。post_id 此前传 threadId，与服务端「post_id 锚定首楼」不符 ——
        //   2026-08-28 对齐 Kotlin。
        await agree(
          thread.threadId || thread.id,
          thread.firstPostId || thread.id,
          nextAgree ? 1 : 0,
          3,
        );
        // 点赞成功 toast（2026-08-28 用户要求，吧页信息流场景）：Kotlin 对照为
        // 成功无提示、仅失败有 snackbar（snackbar_agree_fail）——RN 按用户要求补
        // 成功提示，文案对齐收藏/关注成功 toast 风格（showToast 底部药丸）。
        // 成对语义：点赞 → 「点赞成功」；取消（含乐观已赞后再点）→「已取消点赞」。
        hapticForScene('action-success');
        showToast(nextAgree ? '点赞成功' : '已取消点赞');
      } catch (e) {
        // 失败诊断（2026-08-28 吧页点赞失败排查）：错误只弹 toast 不透出，
        // 服务端具体 error_code 不可见；打印 code/message 供 Metro 定位
        if (__DEV__) {
          console.warn(
            '[agree] ERR',
            e instanceof TiebaApiError ? `code=${e.code} msg=${e.message}` : String(e),
          );
        }
        // 服务端「您已经点过赞了/还没有点过赞」= 目标态已达成（幂等服务端状态
        // 翻转），视为成功：保持乐观目标态、不回滚、不弹失败 toast（帖内
        // handleThreadAgree 同款策略，2026-08-27 日志实证）——否则列表状态会被
        // 回滚成与服务器相反的一面，且每次点都弹「点赞失败」造成 toast 风暴。
        if (e instanceof TiebaApiError && /点过赞/.test(e.message)) {
          hapticForScene('action-success');
          showToast(nextAgree ? '点赞成功' : '已取消点赞');
          return;
        }
        hapticForScene('action-fail');
        likeMirrorRef.current.set(thread.id, latest);
        options.applyLike(thread.id, latest); // 回滚列表到原态
        // 失败 toast（对齐 Kotlin snackbar_agree_fail「点赞失败」与帖内
        // useThreadPageActions 同文案）
        showToast('点赞失败，请稍后重试');
      }
    },
    // options 由调用方保证引用稳定（useCallback/useMemo 注入）
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [requireLogin, options.applyLike, options.getLatestHasAgree],
  );

  /** 分享：标题+URL 合并为一条整体（与 services/threadActions 同规范） */
  const share = useCallback(
    async (thread: FeedCardTarget) => {
      hapticForScene('press');
      try {
        const url = buildThreadUrl(thread.id);
        const content = thread.title ? `${thread.title}\n${url}` : url;
        await Share.share({ message: content }, { dialogTitle: '分享帖子' });
      } catch {
        // 用户取消分享面板 — 忽略
      }
    },
    [],
  );

  /** 屏蔽作者：写黑名单 + 从列表移除其帖子 */
  const blockAuthor = useCallback(
    async (thread: FeedCardTarget) => {
      const authorId = thread.authorId;
      if (!authorId) return;
      try {
        await BlockManager.addBlockedUser({
          id: Date.now().toString(),
          uid: authorId,
          username: thread.authorNameShow || thread.authorName || undefined,
        });
        hapticForScene('action-success');
        options.removeByAuthor?.(authorId);
      } catch {
        hapticForScene('action-fail');
      }
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [options.removeByAuthor],
  );

  /** 举报：拉取服务端举报页 URL，内嵌 webview 打开（全库统一归宿） */
  const report = useCallback(
    async (thread: FeedCardTarget) => {
      try {
        const url = await checkReportPost(thread.id);
        if (url) {
          router.push({ pathname: '/webview', params: { url, title: '举报' } });
        } else {
          Alert.alert('提示', '当前帖子不支持在线举报');
        }
      } catch {
        hapticForScene('action-fail');
        Alert.alert('错误', '举报失败');
      }
    },
    [router],
  );

  /** 复制标题 */
  const copyTitle = useCallback((thread: FeedCardTarget) => {
    const title = thread.title ?? '';
    if (title) {
      Clipboard.setStringAsync(title).catch(() => {});
    }
  }, []);

  return { requireLogin, like, share, blockAuthor, report, copyTitle };
}
