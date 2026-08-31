/**
 * useNavDoubleTapToTop — 双击导航栏（标题/空白区）回顶
 *
 * 原生侧（tieba-native，须重编）给 UINavigationBar 挂双击手势并发
 * onNavDoubleTap 事件；RN 视图收不到落在原生 bar 上的触摸，检测必须走原生。
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
 * 原生栏双击手势覆盖整条导航栏（含 headerRight）——点击吧头像后 400ms 内
 * 的第二次点击会被识别为"双击回顶"，此时旧页 push 动画未结束（仍可见），
 * 回顶动画照播 → 观感"先回顶再进吧"。导航离开动作前调用 suppress：
 * 窗口期内忽略所有双击回顶事件。
 */
let suppressUntil = 0;
export function suppressNavDoubleTap(ms = 600): void {
  suppressUntil = Date.now() + ms;
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
      if (Date.now() < suppressUntil) return; // 导航离开窗口期内忽略
      hapticForScene('press');
      scrollToTopRef.current();
    });
  }, [enabled]);
}
