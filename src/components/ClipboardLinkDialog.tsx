// ============================================================
// ClipboardLinkDialog — Dialog shown when a tieba link is
// detected in the clipboard.
//
// Mirrors Kotlin: MainActivityV2.ClipBoardDetectDialog()
// ============================================================

import { Alert } from 'react-native';
import { router } from 'expo-router';
import type { DetectedLink } from '@/hooks/useClipboardDetector';

/**
 * Show a dialog asking the user to open a detected tieba link.
 * Kotlin equivalent: ClipBoardDetectDialog composable with Dialog + DialogPositiveButton + DialogNegativeButton
 */
export function showClipboardLinkDialog(
  link: DetectedLink,
  onDismiss: () => void,
): void {
  const title =
    link.type === 'thread' ? '检测到贴吧帖子链接' : '检测到贴吧链接';
  const message =
    link.type === 'thread'
      ? `帖子ID: ${link.threadId}\n\n${link.url}`
      : `吧名: ${link.forumName}\n\n${link.url}`;

  Alert.alert(title, message, [
    {
      text: '取消',
      style: 'cancel',
      onPress: onDismiss,
    },
    {
      text: '打开',
      onPress: () => {
        onDismiss();
        if (link.type === 'thread') {
          router.push(`/thread/${link.threadId}`);
        } else {
          router.push(`/forum/${encodeURIComponent(link.forumName)}`);
        }
      },
    },
  ]);
}
