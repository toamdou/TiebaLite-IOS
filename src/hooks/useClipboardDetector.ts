// ============================================================
// useClipboardDetector — Detect tieba links in clipboard
//
// Mirrors Kotlin: ClipBoardLinkDetector
// Registered as ActivityLifecycleCallbacks, checks clipboard
// on activity start (app foreground), compares hash to avoid
// duplicate prompts, extracts tieba URLs and returns parsed link.
// ============================================================

import { useEffect, useRef, useState, useCallback } from 'react';
import { AppState } from 'react-native';
import * as Clipboard from 'expo-clipboard';
import {
  isThreadUrl,
  isForumUrl,
  extractThreadId,
  extractForumName,
} from '@/utils';

// ---------- Types ----------

export interface DetectedThreadLink {
  type: 'thread';
  url: string;
  threadId: string;
}

export interface DetectedForumLink {
  type: 'forum';
  url: string;
  forumName: string;
}

export type DetectedLink = DetectedThreadLink | DetectedForumLink;

// ---------- URL Regex (from Kotlin) ----------

const URL_REGEX =
  /((http|https):\/\/)(([a-zA-Z0-9._-]+\.[a-zA-Z]{2,6})|([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}))(:[0-9]{1,4})*(\/[a-zA-Z0-9&%_./-~-]*)?/;

// ---------- Hook ----------

export function useClipboardDetector(enabled: boolean = true): {
  detectedLink: DetectedLink | null;
  clearDetectedLink: () => void;
} {
  const [detectedLink, setDetectedLink] = useState<DetectedLink | null>(null);

  // Clipboard hash to avoid re-prompting for the same content
  // Kotlin: uses clipBoardTimestamp; we use content string hash
  const lastHash = useRef<string>('');

  // Throttle: avoid rapid re-checks (Kotlin: 10s throttle)
  const lastCheck = useRef<number>(0);

  // 卸载后置位：getStringAsync 是异步的，响应回来时组件可能已卸载，
  // 防止对已卸载组件 setState（detectLink 开头与 setDetectedLink 前都过闸）。
  const disposedRef = useRef(false);

  // 设置开关（设置-使用习惯-剪贴板链接识别）：关闭时彻底不读剪贴板、
  // 不订阅原生变更事件——iOS 系统粘贴提示也不会被触发。
  const enabledRef = useRef(enabled);
  enabledRef.current = enabled;

  const detectLink = useCallback(async () => {
    if (!enabledRef.current || disposedRef.current) return;
    // Throttle checks to max once per 3 seconds
    const now = Date.now();
    if (now - lastCheck.current < 3000) return;
    lastCheck.current = now;

    try {
      const text = await Clipboard.getStringAsync();
      // 卸载后不再触碰状态（异步读取期间组件可能已卸载）
      if (disposedRef.current) return;
      if (!text || text === lastHash.current) return;

      // Extract URL from clipboard (Kotlin: regex match)
      const match = text.match(URL_REGEX);
      if (!match) return;

      const url = match[0];

      // Parse link (Kotlin: parseLink → ClipBoardThreadLink / ClipBoardForumLink)
      if (isThreadUrl(url)) {
        const threadId = extractThreadId(url);
        if (threadId) {
          // hash 在识别成功后置位：识别失败（如一般 URL）不占位，
          // 下次剪贴板事件仍可重试；识别成功则同内容不再重复弹窗。
          lastHash.current = text;
          setDetectedLink({ type: 'thread', url, threadId });
          return;
        }
      }

      if (isForumUrl(url)) {
        const forumName = extractForumName(url);
        if (forumName) {
          lastHash.current = text;
          setDetectedLink({ type: 'forum', url, forumName });
        }
      }
    } catch {
      // Clipboard access denied or empty — silently skip
    }
  }, []);

  const clearDetectedLink = useCallback(() => {
    setDetectedLink(null);
  }, []);

  useEffect(() => {
    if (!enabled) {
      // 开关关闭：清掉已弹出的检测结果，且完全不订阅剪贴板事件
      //（iOS 系统粘贴提示也不会被触发）
      setDetectedLink(null);
      return;
    }
    // HMR 下同实例复用 ref：挂载时复位 disposed
    disposedRef.current = false;
    // Check on mount (Kotlin: onCreate → checkIntent)
    // eslint-disable-next-line react-hooks/set-state-in-effect -- clipboard read is async; detected-link state only updates after getStringAsync resolves.
    detectLink();

    // 仅在前台化时检测（对齐 Kotlin ActivityLifecycleCallbacks.onStart）：
    // 不订阅原生剪贴板变更事件——应用自身写入剪贴板（复制链接）也会触发
    // 该事件，导致“点一下复制就弹检测弹窗”（2026-08-27 真机反馈）。
    const appStateSub = AppState.addEventListener('change', (state) => {
      if (state === 'active') detectLink();
    });

    return () => {
      disposedRef.current = true;
      appStateSub.remove();
    };
  }, [detectLink, enabled]);

  return { detectedLink, clearDetectedLink };
}
