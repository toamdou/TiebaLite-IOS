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
      hapticForScene('press');
      scrollToTopRef.current();
    });
  }, [enabled]);
}
