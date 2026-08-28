/**
 * useTimeLabel — 时间显示格式化 hook（reactive 读 timestampStyle 偏好）。
 *
 * relative = 相对时间（relativeTime，默认）；absolute = 绝对时间（absoluteTime）。
 * 返回稳定函数供渲染处直接调用；偏好切换时返回的函数引用会更新，
 * 组件随 zustand 订阅重渲染（调用点须把该函数用于渲染而非闭包缓存）。
 */

import { useCallback } from 'react';
import { relativeTime, absoluteTime } from '@/utils';
import { useAppPreference } from './useAppPreference';

export function useTimeLabel(): (timestamp: number) => string {
  const timestampStyle = useAppPreference('timestampStyle', 'relative');
  return useCallback(
    (timestamp: number) =>
      timestampStyle === 'absolute' ? absoluteTime(timestamp) : relativeTime(timestamp),
    [timestampStyle],
  );
}
