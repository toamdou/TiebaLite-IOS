import { requireNativeViewManager } from 'expo-modules-core';
import type { StyleProp, ViewStyle } from 'react-native';

export interface TiebaAudioWaveformProps {
  heights: number[];
  isPlaying?: boolean;
  color?: string;
  inactiveColor?: string;
  style?: StyleProp<ViewStyle>;
}

const NativeTiebaAudioWaveform = requireNativeViewManager(
  'TiebaNative',
  'TiebaAudioWaveformView',
);

export function TiebaAudioWaveform(props: TiebaAudioWaveformProps) {
  return <NativeTiebaAudioWaveform {...props} />;
}
