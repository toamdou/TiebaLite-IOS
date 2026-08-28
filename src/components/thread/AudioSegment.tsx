// ============================================================
// TiebaLite React Native - AudioSegment（语音条）
// 帖子/楼中楼的语音内容渲染：play/pause + 波形动画 + 进度/时长 +
// 1x/1.5x 倍速 + 长按下载。惰性创建播放器（点击才挂载，卸载即释放）。
// 抽自 PostContent（帖内与楼中楼 subposts 共用同一实现）。
// URL 由 helpers.ts 对齐 Kotlin 拼装（voice_md5 → tiebac /c/p/voice）。
// ============================================================

import { useCallback, useEffect, useState } from 'react';
import { Alert, StyleSheet } from 'react-native';
import { Text } from '../ui/CompatText';
import { useAudioPlayer, useAudioPlayerStatus } from 'expo-audio';

import { TiebaAudioWaveform } from '../../../modules/tieba-native/src/TiebaAudioWaveform';
import { SymbolView } from '@/components/ui/SymbolView';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { useThemeColors } from '@/theme/ThemeContext';
import {RadiusStyle} from '@/theme';
import { hapticForScene } from '@/theme/hapticsMap';
import { formatDuration } from '@/utils/formatDuration';
import { useMediaBusMutex } from '@/hooks/useMediaBusMutex';
import { shareFile } from '@/services/media';

/** 波形条高度序列（静态，Kotlin 同款视觉节奏） */
const AUDIO_WAVEFORM_BARS = [12, 18, 8, 22, 14, 20, 10, 24, 16, 6, 19, 13, 21, 9, 17];

function promptDownloadAudio(src: string) {
  Alert.alert('音频', '下载音频文件？', [
    { text: '取消', style: 'cancel' },
    {
      text: '下载',
      onPress: async () => {
        try {
          await shareFile(src, undefined, {
            mimeType: 'audio/mpeg',
            dialogTitle: '保存音频',
          });
        } catch (e) {
          if (__DEV__) console.warn('[AudioSegment] download ERR src=', src, e);
          Alert.alert('错误', '下载失败');
        }
      },
    },
  ]);
}

function AudioSegmentUI({
  isCurrentlyPlaying,
  displayTime,
  displayDuration,
  onPress,
  onLongPress,
  rate,
  onRateToggle,
}: {
  isCurrentlyPlaying: boolean;
  displayTime: number;
  displayDuration: number;
  onPress: () => void;
  onLongPress: () => void;
  /** 激活播放时显示倍速切换（1x/1.5x） */
  rate?: number;
  onRateToggle?: () => void;
}) {
  const { colors } = useThemeColors();

  return (
    <HdrPressable
      onPress={() => {
        void hapticForScene('press');
        onPress();
      }}
      onLongPress={() => {
        void hapticForScene('long-press');
        onLongPress?.();
      }}
      style={[
        styles.audioWrapper,
        { backgroundColor: colors.chip, borderColor: colors.divider },
      ]}
      accessibilityLabel={isCurrentlyPlaying ? '暂停音频' : '播放音频'}
      accessibilityRole="button"
    >
      <SymbolView
        name={isCurrentlyPlaying ? 'pause.circle.fill' : 'play.circle.fill'}
        size={28}
        tintColor={colors.primary}
      />

      {/* Waveform visualization */}
      <TiebaAudioWaveform
        heights={AUDIO_WAVEFORM_BARS}
        isPlaying={isCurrentlyPlaying}
        color={colors.primary}
        inactiveColor={colors.textSecondary}
        style={styles.audioWave}
      />

      {/* Time display: currentTime / total duration */}
      <Text style={[styles.audioDuration, { color: colors.textSecondary }]}>
        {formatDuration(displayTime)} / {formatDuration(displayDuration)}
      </Text>

      {/* Playback rate toggle (1x / 1.5x) — only while active */}
      {rate != null && (
        <HdrPressable
          onPress={() => {
            void hapticForScene('toggle');
            onRateToggle?.();
          }}
          hitSlop={8}
          accessibilityRole="button"
          accessibilityLabel={`播放速度 ${rate}x`}
          style={styles.audioRate}
        >
          <Text style={[styles.audioRateText, { color: colors.textSecondary }]}>{rate}x</Text>
        </HdrPressable>
      )}
    </HdrPressable>
  );
}

/**
 * Player is created only after the user taps play. Unmounting this child
 * releases the expo-audio player with it.
 */
function ActiveAudio({
  src,
  duration,
}: {
  src: string;
  duration: number;
}) {
  const player = useAudioPlayer(null);
  const status = useAudioPlayerStatus(player);
  const [rate, setRate] = useState(1);
  // 媒体总线互斥 + 离屏暂停收敛到共享 hook（thermo Z2-E；key 形态 a:<src> 不变）。
  // pause 包 try/catch：音频播放器在未装载时 pause 可能抛错，视频版无此顾虑。
  const myKey = `a:${src}`;
  const { activate, deactivate } = useMediaBusMutex(
    myKey,
    () => {
      try {
        player.pause();
      } catch (e) {
        if (__DEV__) console.warn('[AudioSegment] mutex pause ERR', e);
      }
    },
  );

  // Start playback once the child mounts after a user tap.
  // await replace 完成后再 play：expo-audio 的 replace 是异步装载，未等就绪
  // 直接 play 有概率被忽略（语音条首次点击"没声音"）。
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        await player.replace({
          uri: src,
          headers: { Referer: 'https://tieba.baidu.com/' },
        });
        if (cancelled) return;
        player.play();
        activate();
      } catch (e) {
        if (__DEV__) console.warn('[AudioSegment] init ERR src=', src, e);
      }
    })();
    return () => {
      deactivate();
    };
  }, [player, src, myKey, activate, deactivate]);

  // Pause audio on unmount to prevent background playback & memory leak
  useEffect(() => {
    return () => {
      try {
        player.pause();
      } catch (e) {
        if (__DEV__) console.warn('[AudioSegment] unmount pause ERR', e);
      }
    };
  }, [player]);

  const isCurrentlyPlaying = status.playing;
  const displayTime = status.isLoaded ? status.currentTime : 0;
  const displayDuration = status.duration > 0 ? status.duration : duration;

  /** Toggle play/pause */
  const handleToggle = useCallback(async () => {
    hapticForScene('toggle');
    try {
      if (isCurrentlyPlaying) {
        player.pause();
        return;
      }
      if (!status.isLoaded) {
        // replace 是异步装载：await 完成后再 play，否则快速二次点击时
        // 播放会被装载过程吞掉。
        await player.replace({
          uri: src,
          headers: { Referer: 'https://tieba.baidu.com/' },
        });
      }
      // If playback ended, seek to start before playing
      if (status.didJustFinish) player.seekTo(0);
      player.play();
    } catch (e) {
      if (__DEV__) console.warn('[AudioSegment] toggle ERR src=', src, e);
    }
  }, [player, isCurrentlyPlaying, status.didJustFinish, status.isLoaded, src]);

  /** Toggle 1x / 1.5x playback rate */
  const handleRateToggle = useCallback(() => {
    hapticForScene('toggle');
    const next = rate === 1 ? 1.5 : 1;
    setRate(next);
    try {
      player.playbackRate = next;
    } catch (e) {
      if (__DEV__) console.warn('[AudioSegment] rate ERR src=', src, e);
    }
  }, [player, rate, src]);

  return (
    <AudioSegmentUI
      isCurrentlyPlaying={isCurrentlyPlaying}
      displayTime={displayTime}
      displayDuration={displayDuration}
      onPress={handleToggle}
      onLongPress={() => promptDownloadAudio(src)}
      rate={rate}
      onRateToggle={handleRateToggle}
    />
  );
}

/**
 * 语音条（惰性激活：首次点击才挂载 ActiveAudio 创建播放器，卸载即释放）。
 * 帖内主回复与楼中楼共用。
 */
export function AudioSegment({
  src,
  duration,
}: {
  src: string;
  duration: number;
}) {
  const [isActive, setIsActive] = useState(false);

  const handleActivate = useCallback(() => {
    hapticForScene('press');
    setIsActive(true);
  }, []);

  if (!isActive) {
    return (
      <AudioSegmentUI
        isCurrentlyPlaying={false}
        displayTime={0}
        displayDuration={duration}
        onPress={handleActivate}
        onLongPress={() => promptDownloadAudio(src)}
      />
    );
  }

  return <ActiveAudio src={src} duration={duration} />;
}

const styles = StyleSheet.create({
  audioWrapper: {
    flexDirection: 'row' as const,
    alignItems: 'center',
    padding: 10,
    ...RadiusStyle.input,
    borderWidth: 1,
    gap: 10,
    marginTop: 10,
  },
  audioWave: {
    flex: 1,
    height: 32,
  },
  audioDuration: {
    fontSize: 12,
    fontVariant: ['tabular-nums'],
  },
  audioRate: {
    minWidth: 34,
    alignItems: 'center',
    paddingVertical: 2,
    paddingHorizontal: 6,
    borderRadius: 8,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(127,127,127,0.14)',
  },
  audioRateText: {
    fontSize: 12,
    fontWeight: '600',
    fontVariant: ['tabular-nums'],
  },
});