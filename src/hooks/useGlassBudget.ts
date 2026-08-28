// ============================================================
// TiebaLite - useGlassBudget (实时玻璃预算 hook)
//
// 设计文档性能规则 2：每屏实时 UIVisualEffectView 玻璃最多 1 处。
//
// 作用域模型（终审 I-2 修复）：预算按「当前可见（聚焦）屏幕」独立计算，
// 跨屏不再互相污染。
// - 每个实例用 useRoute().key 归属到其所在屏幕（路由键），
//   用 useIsFocused 判定所在屏是否聚焦；失焦时整屏让位（计数归零）。
//   修复 enableFreeze + freezeOnBlur 下首页胶囊常驻挂载、永久占用唯一
//   预算位，导致 push 详情页后浮动栏被首个挂载者挤成 staticGlass 的问题。
// - 同屏内按挂载顺序（注册顺序）竞争唯一实时玻璃位：首挂载者
//   （activeCount=1，未超预算）可用实时玻璃，其余降级 staticGlass。
// - 注册/注销与计数收敛放在 useLayoutEffect（RN 绘制前）完成，
//   同屏同批挂载首帧即收敛到 ≤1，避免首帧双实时玻璃闪现。
//
// 导出接口与原实现完全兼容：useGlassBudget() 返回
// { shouldUseStaticGlass, activeCount, maxRealTime }，语义不变，
// 只是计数作用域从「全 App 挂载实例」变为「当前可见屏幕内实例」。
// GlassView / TiebaGlassSurface 调用点零改动。
// ============================================================

import {
  useCallback,
  useLayoutEffect,
  useState,
  useSyncExternalStore,
} from 'react';
import { useIsFocused, useRoute } from 'expo-router';
import { glassTokens } from '@/theme/glass';

/** 模块级自增 ID：区分同一屏幕内的多个玻璃实例（注册顺序 = 挂载顺序） */
let nextInstanceId = 0;

/** 每个路由键（屏幕）当前已挂载的实时玻璃实例 id 集合，迭代顺序 = 挂载顺序 */
const mountedByRoute = new Map<string, Set<number>>();

/** 每屏的订阅者集合（计数变化时通知重渲染） */
const listenersByRoute = new Map<string, Set<() => void>>();

/** enabled=false 时使用的空订阅：不注册 listener（免无意义重渲染） */
const NOOP_UNSUBSCRIBE = () => {};

/** 通知某屏的所有订阅者重新读取计数 */
function emitRouteChange(routeKey: string) {
  const listeners = listenersByRoute.get(routeKey);
  if (listeners) {
    for (const listener of listeners) listener();
  }
}

export interface GlassBudgetInfo {
  /** 当前实例是否应降级为 staticGlass（超预算为 true） */
  shouldUseStaticGlass: boolean;
  /**
   * 当前实例所在屏幕的实时玻璃实例数：失焦为 0（整屏让位）；
   * 聚焦时含本实例，按挂载顺序为 1、2、3…
   */
  activeCount: number;
  /** 每屏实时玻璃上限（来自 glassTokens.budget） */
  maxRealTime: number;
}

/**
 * 返回实时玻璃预算状态。作用域为「当前可见（聚焦）屏幕」：
 * 组件挂载且所在屏聚焦时参与计数，失焦时让位，卸载时退出计数。
 * 同一屏幕内首挂载的实例（activeCount=1）可用实时玻璃，其余降级。
 *
 * @param opts.enabled=false 时该实例「显式静态」：不注册、不占预算、
 *   不产生降级日志，恒返回 shouldUseStaticGlass=true。用于视觉上不需要
 *   实时毛玻璃的次要元素（小图标钮、被深色蒙版覆盖的栏条等）——它们本
 *   来就会被降级，与其抢挂载顺序、误占唯一实时位并把主角挤成 static，
 *   不如直接声明静态，让真正的主角玻璃稳定拿到预算。
 */
export function useGlassBudget(opts: { enabled?: boolean } = {}): GlassBudgetInfo {
  const { enabled = true } = opts;
  const maxRealTime = glassTokens.budget.maxRealTimePerScreen;
  const routeKey = useRoute().key;
  const isFocused = useIsFocused();

  // 每个实例唯一的自增 id。useState 惰性初始化是官方允许的初始化器路径，
  // 不触发 react-hooks/refs「渲染期访问 ref」规则；自增顺序即挂载顺序。
  const [instanceId] = useState(() => ++nextInstanceId);

  // 订阅本屏计数变化（其他实例挂载/卸载时触发重渲染，重算排名）
  const subscribe = useCallback(
    (callback: () => void) => {
      let listeners = listenersByRoute.get(routeKey);
      if (!listeners) {
        listeners = new Set();
        listenersByRoute.set(routeKey, listeners);
      }
      listeners.add(callback);
      return () => {
        listeners.delete(callback);
        if (listeners.size === 0) {
          listenersByRoute.delete(routeKey);
        }
      };
    },
    [routeKey],
  );

  // 读取本屏当前实时玻璃实例数：聚焦时 = 本实例在挂载顺序中的排名（含自己），
  // 失焦时 = 0（整屏让位）。首帧注册前乐观取「首个可用位」，
  // useLayoutEffect 注册并 emit 后在绘制前重算收敛到真实排名。
  const getSnapshot = useCallback(() => {
    if (!isFocused) return 0;
    const mounted = mountedByRoute.get(routeKey);
    if (!mounted || mounted.size === 0) return 1;
    let rank = 1;
    for (const id of mounted) {
      if (id === instanceId) return rank;
      rank += 1;
    }
    return rank; // 已挂载但尚未注册（首帧）：排在末尾
  }, [isFocused, routeKey, instanceId]);

  // enabled=false（显式静态）时订阅短路：不注册 listener、计数恒不变
  // （activeCount 恒 1 / shouldUseStaticGlass 恒 true），避免无意义重渲染。
  const activeCount = useSyncExternalStore(
    enabled ? subscribe : () => NOOP_UNSUBSCRIBE,
    getSnapshot,
    getSnapshot,
  );

  // 注册/注销 + 首帧收敛：useLayoutEffect 在绘制前完成，同屏同批挂载
  // 首帧不会出现双实时玻璃闪现。deps 固定（routeKey/instanceId/maxRealTime
  // 均稳定），确保 effect 只在挂载/卸载时运行，注册顺序不被重排。
  // enabled=false（显式静态）不注册：不占预算位、不触发降级日志。
  useLayoutEffect(() => {
    // enabled=false（显式静态）：不注册、不占预算位、不触发降级日志。
    if (!enabled) return;
    let mounted = mountedByRoute.get(routeKey);
    if (!mounted) {
      mounted = new Set();
      mountedByRoute.set(routeKey, mounted);
    }
    mounted.add(instanceId);
    emitRouteChange(routeKey);

    // 降级日志便于后续排查（注册后按真实排名判断，含本实例）
    let rank = 1;
    for (const id of mounted) {
      if (id === instanceId) break;
      rank += 1;
    }
    if (rank > maxRealTime && __DEV__) {
      console.warn(
        `[useGlassBudget] 实时玻璃超预算 ${rank}/${maxRealTime}，该实例已降级 staticGlass`,
      );
    }

    return () => {
      const m = mountedByRoute.get(routeKey);
      if (m) {
        m.delete(instanceId);
        if (m.size === 0) {
          mountedByRoute.delete(routeKey);
        }
      }
      emitRouteChange(routeKey);
    };
  }, [routeKey, instanceId, maxRealTime, enabled]);

  return {
    shouldUseStaticGlass: enabled ? activeCount > maxRealTime : true,
    activeCount: enabled ? activeCount : 1,
    maxRealTime,
  };
}
