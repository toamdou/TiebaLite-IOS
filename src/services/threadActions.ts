/**
 * Shared thread/post actions: share, copy link, report and delete.
 *
 * 透传包装层（shareThread/copyThreadLink/fetchThreadReportUrl/
 * deleteThreadAction/deletePostAction）已删除（全量审查 #9）：它们只转发
 * 参数无任何语义，hook 直接调用 endpoint 底层 API，行为不变（remove()
 * 的 deletingThread 判定语义保持：无 postId 或 postId===threadId 视为删帖）。
 */

import { useCallback } from 'react';
import { Alert, Share } from 'react-native';
import { useRouter } from 'expo-router';
import * as Clipboard from 'expo-clipboard';
import { hapticForScene } from '@/theme/hapticsMap';
import { checkReportPost } from '@/services/api/endpoints/misc';
import { delPost, delThread } from '@/services/api/endpoints/thread';
import { buildThreadUrl } from '@/utils';

export const THREAD_ACTION_ERRORS = {
  report: '举报失败',
  delete: '删除失败',
  copy: '复制失败',
};

export function useThreadActions({
  threadId,
  forumId,
  forumName,
  title,
}: {
  threadId: string;
  forumId?: string;
  forumName?: string;
  /** 帖子标题：分享时与 URL 合并为一条整体内容 */
  title?: string;
}) {
  const router = useRouter();

  const share = useCallback(async () => {
    try {
      const url = buildThreadUrl(threadId);
      // 分享内容 = 标题 + URL 合并为一条整体（用户要求：不要拆成两个条目）。
      // 只传 message 字段 → iOS 分享面板单条目。
      const content = title ? `${title}\n${url}` : url;
      await Share.share({ message: content }, { dialogTitle: '分享帖子' });
    } catch {
      // Sharing is best-effort.
    }
  }, [threadId, title]);

  const copy = useCallback(async () => {
    try {
      await Clipboard.setStringAsync(buildThreadUrl(threadId));
      hapticForScene('action-success');
      return true;
    } catch {
      hapticForScene('action-fail');
      // 失败反馈由调用方统一 showToast（2026-08-27：点赞/收藏/复制一律
      // 去 Alert，改底栏单行药丸）
      return false;
    }
  }, [threadId]);

  const report = useCallback(
    async (postId?: string) => {
      try {
        const url = await checkReportPost(postId || threadId);
        if (url) {
          router.push({
            pathname: '/webview',
            params: { url, title: '举报' },
          });
        } else {
          Alert.alert('提示', '当前帖子不支持在线举报');
        }
        return true;
      } catch {
        hapticForScene('action-fail');
        Alert.alert('错误', THREAD_ACTION_ERRORS.report);
        return false;
      }
    },
    [threadId, router],
  );

  const remove = useCallback(
    async (postId?: string) => {
      const deletingThread = !postId || postId === threadId;
      try {
        if (deletingThread) {
          await delThread(forumId || '', forumName || '', threadId);
        } else {
          await delPost(forumId || '', forumName || '', threadId, postId, true);
        }
        hapticForScene('action-success');
        return true;
      } catch {
        hapticForScene('action-fail');
        Alert.alert('错误', THREAD_ACTION_ERRORS.delete);
        return false;
      }
    },
    [threadId, forumId, forumName],
  );

  return { share, copy, report, remove };
}