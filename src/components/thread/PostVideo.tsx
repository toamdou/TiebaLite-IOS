/**
 * PostVideo — 帖内视频块（VideoSegment + ActiveVideo，第二轮拆分自 PostContent.tsx）
 *
 * Player 只在用户点击播放后创建；卸载本子组件即释放 expo-video player。
 * 与 AudioSegment 同语义：帖内视频不受 hideMedia/blockVideo 之外的扩展门控。
 */

import { useCallback, useEffect, useRef, useState } from 'react';
import { View } from 'react-native';
import { Text } from '../ui/CompatText';
import { Image } from 'expo-image';
import { SymbolView } from '@/components/ui/SymbolView';
import { HdrPressable } from '@/components/ui/HdrPressable';
import { hapticForScene } from '@/theme/hapticsMap';
import { useVideoPlayer, VideoView } from 'expo-video';
import { useThemeColors } from '@/theme/ThemeContext';
import { useMediaBusMutex } from '@/hooks/useMediaBusMutex';
import { useMediaBus } from '@/stores/mediaBusStore';
import { useAppPreference } from '@/hooks/useAppPreference';
import { styles } from './postContentStyles';

/**
 * Player is created only after the user taps play. Unmounting this child
 * releases the expo-video player with it.
 */
function ActiveVideo({
  src,
  effectiveWidth,
  effectiveHeight,
  expanded,
  onEnded,
  onToggleExpanded,
}: {
  src: string;
  effectiveWidth: number;
  effectiveHeight: number;
  expanded: boolean;
  onEnded: () => void;
  onToggleExpanded: () => void;
}) {
  const player = useVideoPlayer(null, (p) => {
    p.muted = true;
    p.loop = false;
  });
  // 媒体总线互斥 + 离屏暂停收敛到共享 hook（thermo Z2-E；key 形态 v:<src> 不变）
  const myKey = `v:${src}`;
  const { activate, deactivate } = useMediaBusMutex(myKey, () => player.pause());

  // Start playback once the child mounts after a user tap.
  // 用 replaceAsync：iOS 上 replace 会在主线程同步加载资源（警告）；
  // 卸载时不做任何 player 调用——expo-video 底层 useReleasingSharedObject 已释放
  // native 对象，cleanup 里调 pause() 会抛 NotFoundException（FunctionCallException）。
  useEffect(() => {
    player.replaceAsync({
      uri: src,
      headers: { Referer: 'https://tieba.baidu.com/' },
    });
    player.play();
    activate();
    return () => deactivate();
  }, [player, src, myKey, activate, deactivate]);

  // Listen for playback end → reset to poster
  useEffect(() => {
    const sub = player.addListener('playToEnd', onEnded);
    return () => sub.remove();
  }, [player, onEnded]);

  return (
    <View
      style={[
        styles.videoWrapper,
        {
          width: effectiveWidth,
          height: effectiveHeight,
          backgroundColor: '#000',
        },
      ]}
    >
      <VideoView
        player={player}
        style={styles.videoPlayer}
        nativeControls
        contentFit="contain"
        allowsPictureInPicture
        fullscreenOptions={{ enable: true }}
      />
      <HdrPressable
        onPress={() => {
          void hapticForScene('press');
          onToggleExpanded();
        }}
        style={styles.expandButton}
        accessibilityLabel={expanded ? '缩小视频' : '放大视频'}
        accessibilityRole="button"
      >
        <SymbolView
          name={expanded ? 'arrow.down.right.and.arrow.up.left' : 'arrow.up.left.and.arrow.down.right'}
          size={14}
          tintColor="rgba(255,255,255,0.9)"
        />
      </HdrPressable>
    </View>
  );
}

export function VideoSegment({
  src,
  poster,
  width,
  height,
  contentWidth,
}: {
  src: string;
  poster: string;
  width: number;
  height: number;
  contentWidth: number;
}) {
  const { colors } = useThemeColors();
  const [isPlaying, setIsPlaying] = useState(false);
  const [expanded, setExpanded] = useState(false);

  // 自动播放（偏好开启时）：可视区自动静音开播、滚出视野收起回海报（播放器
  // 随卸载释放，长帖不堆积）；滚回视野重新开播。关闭=点按播放（原行为）。
  // visibleKeys === null 表示列表未接入可见性（视为可见）。帖内页与楼中楼页
  // 均已上报可视媒体 key（mediaKeysOf 与总线 v:<src> 同构）。
  // autoRanRef：每次「进入可视区」只自动开播一次——否则 playToEnd 回海报态
  // 后 effect 会立刻再次开播，形成无限重播循环。
  const videoAutoplay = useAppPreference('videoAutoplay', false);
  const visibleKeys = useMediaBus((s) => s.visibleKeys);
  const autoKey = `v:${src}`;
  const autoVisible = visibleKeys == null || visibleKeys.has(autoKey);
  const autoRanRef = useRef(false);
  useEffect(() => {
    if (!videoAutoplay) return;
    if (autoVisible) {
      if (!autoRanRef.current && !isPlaying) {
        autoRanRef.current = true;
        setIsPlaying(true);
      }
    } else {
      autoRanRef.current = false;
      if (isPlaying) {
        setIsPlaying(false);
        setExpanded(false);
      }
    }
  }, [videoAutoplay, autoVisible, isPlaying]);

  const aspectRatio = width > 0 && height > 0 ? width / height : 1;
  // 视频帖卡满内容宽（旧 280pt 上限在 ~350pt 内容宽下浪费 1/5 屏宽）
  const displayWidth = contentWidth > 0 ? contentWidth : 280;
  const displayHeight = displayWidth / aspectRatio;
  const effectiveHeight = expanded ? displayHeight * 2 : displayHeight;
  const effectiveWidth = expanded ? displayWidth * 1.5 : displayWidth;

  const handlePlay = useCallback(() => {
    hapticForScene('press');
    setIsPlaying(true);
  }, []);

  const handleEnded = useCallback(() => {
    setIsPlaying(false);
    setExpanded(false);
  }, []);

  const handleToggleExpanded = useCallback(() => {
    hapticForScene('toggle');
    setExpanded((prev) => !prev);
  }, []);

  // Poster state
  if (!isPlaying) {
    return (
      <View
        style={[
          styles.videoWrapper,
          {
            width: displayWidth,
            height: displayHeight,
            backgroundColor: colors.placeholder,
          },
        ]}
      >
        <Image
          cachePolicy="memory-disk"
          source={{ uri: poster }}
          style={styles.videoPoster}
          contentFit="cover"
          recyclingKey={poster}
        />
        <HdrPressable
          onPress={() => {
            void hapticForScene('press');
            handlePlay();
          }}
          style={styles.playButton}
          accessibilityLabel="播放视频"
          accessibilityRole="button"
        >
          <SymbolView name="play.circle.fill" size={44} tintColor="rgba(255,255,255,0.9)" />
        </HdrPressable>
        <View style={styles.videoBadge}>
          <SymbolView name="video.fill" size={10} tintColor="#FFF" />
          <Text style={styles.videoBadgeText}>视频</Text>
        </View>
      </View>
    );
  }

  // Video playing — expo-video VideoView with native controls
  return (
    <ActiveVideo
      src={src}
      effectiveWidth={effectiveWidth}
      effectiveHeight={effectiveHeight}
      expanded={expanded}
      onEnded={handleEnded}
      onToggleExpanded={handleToggleExpanded}
    />
  );
}