/**
 * Reduced motion / transparency hook.
 *
 * Motion uses Reanimated's built-in useReducedMotion subscription; only the
 * transparency preference is read manually from AccessibilityInfo.
 */

import { useEffect, useState } from 'react';
import { AccessibilityInfo } from 'react-native';
import { useReducedMotion as useReanimatedReducedMotion } from 'react-native-reanimated';

export interface ReducedMotionInfo {
  reduceMotion: boolean;
  reduceTransparency: boolean;
}

export function useReducedMotion(): ReducedMotionInfo {
  const reduceMotion = useReanimatedReducedMotion();
  const [reduceTransparency, setReduceTransparency] = useState(false);

  useEffect(() => {
    AccessibilityInfo.isReduceTransparencyEnabled().then(setReduceTransparency).catch(() => {});
    const transparencySub = AccessibilityInfo.addEventListener(
      'reduceTransparencyChanged',
      setReduceTransparency,
    );
    return () => transparencySub.remove();
  }, []);

  return { reduceMotion, reduceTransparency };
}
