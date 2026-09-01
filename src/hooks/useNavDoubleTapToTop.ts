/**
 * useNavDoubleTapToTop — 双击导航栏（标题/空白区）回顶
 *
 * 原生侧（tieba-native，须重编）给 UINavigationBar 挂单击手势并发
 * onNavDoubleTap 事件（iOS 27β 原生 2-tap 识别器会"单击即触发"，2026-09-01
 * 真机实证 → 原生只上报单击，双击窗口改在 JS 侧判定）。RN 视图收不到落在
 * 原生 bar 上的触摸，检测必须走原生。
 * 本 hook 在页面订阅事件：仅当页面处于焦点时执行回顶回调——栈顶只有一个
 * 焦点页，无需路由注册表，各页自声明即可。
 *
 * 开关：设置-浏览「双击顶栏回顶」（navBarDoubleTapToTop），由调用方传入。
 */

import { useEffect, useRef } from 'react';
import { useIsFocused } from 'expo-router';

import { addNavDoubleTapListener } from '../../modules/tieba-native/src/TiebaNative';
import { hapticForScene } from '@/theme/hapticsMap';

/**
 * 导航离开抑制（2026-08-31 用户："点右上角吧头像会先回顶再进入吧"）：
 * 原生栏单击手势覆盖整条导航栏（含 headerRight）——点击吧头像后 400ms 内
 * 的后续点击会被误判为"双击回顶"，此时旧页 push 动画未结束（仍可见），
 * 回顶动画照播 → 观感"先回顶再进吧"。导航离开动作前调用 suppress：
 * 窗口期内忽略所有回顶判定并清空单击武装。
 */
let suppressUntil = 0;
/** 双击判定窗（对齐底栏双击 400ms 窗；原生 2-tap 窗口 ~0.3s 同量级） */
const DOUBLE_TAP_WINDOW_MS = 400;
/** 最近一次单击时间：单击只武装，窗口内第二击才执行回顶 */
let lastTapAt = 0;
export function suppressNavDoubleTap(ms = 600): void {
  suppressUntil = Date.now() + ms;
  lastTapAt = 0;
}

export function useNavDoubleTapToTop(scrollToTop: () => void, enabled = true) {
  const isFocused = useIsFocused();
  // 回调与焦点走 ref：聚焦/失焦不重订阅原生事件；enabled 翻转才重挂
  const scrollToTopRef = useRef(scrollToTop);
  const focusedRef = useRef(isFocused);
  scrollToTopRef.current = scrollToTop;
  focusedRef.current = isFocused;

  useEffect(() => {
    if (!enabled) return;
    return addNavDoubleTapListener(() => {
      if (!focusedRef.current) return;
      const now = Date.now();
      if (now < suppressUntil) { // 导航离开窗口期内忽略并清空武装
        lastTapAt = 0;
        return;
      }
      if (now - lastTapAt < DOUBLE_TAP_WINDOW_MS) {
        lastTapAt = 0;
        hapticForScene('press');
        scrollToTopRef.current();
      } else {
        // 第一击：只武装，不动作（修复 iOS 27β "点一次就回顶"）
        lastTapAt = now;
      }
    });
  }, [enabled]);
}
