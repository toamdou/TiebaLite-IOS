// ============================================================
// TiebaLite React Native - User/Forum Avatar
// Circular shape, initials placeholder, status indicator, level badge
// ============================================================

import { useEffect, useState } from 'react';
import {
  Pressable,
  StyleSheet,
  Text,
  View,
  type StyleProp,
  type GestureResponderEvent,
  type ViewStyle,
} from 'react-native';
import { Image } from 'expo-image';

import { useThemeColors } from '@/theme/ThemeContext';
import { Spacing } from '@/theme';
import { getAvatarUrl } from '@/utils';
import { isImageWarm, markImageWarm } from '@/utils/imageWarm';
import { levelBadgeColor } from '@/constants/rank';

// ---------- Avatar Props ----------
export interface AvatarProps {
  /** Image source URL */
  source?: string;
  /** Fallback initials (e.g. "JD" for John Doe) */
  initials?: string;
  /** Avatar size (default: 40) */
  size?: number;
  /** Level number to show as badge */
  level?: number;
  /** Custom style */
  style?: StyleProp<ViewStyle>;
  /** Accessibility label */
  accessibilityLabel?: string;
  /** Optional tap handler (avatar preview, navigation, etc.) */
  onPress?: (event: GestureResponderEvent) => void;
  /** Optional long-press handler */
  onLongPress?: (event: GestureResponderEvent) => void;
}

// ---------- Avatar Component ----------
export function Avatar({
  source,
  initials,
  size = 40,
  level,
  style,
  accessibilityLabel,
  onPress,
  onLongPress,
}: AvatarProps) {
  const { colors } = useThemeColors();
  const [imageError, setImageError] = useState(false);

  // Convert portrait ID to full URL (mirrors Kotlin StringUtil.getAvatarUrl)
  const avatarUri = getAvatarUrl(source);
  const showFallback = !avatarUri || imageError;
  const fontSize = Math.round(size * 0.38);
  const isPressable = Boolean(onPress || onLongPress);

  // 列表虚拟化下行会随滚动卸载/重挂、行内数据也可能原地更新（如历史页
  // 作者信息回填）：avatar URL 变化时重置失败态，避免新用户继承旧占位图。
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- reset recycled-cell error state when the avatar URL changes.
    setImageError(false);
  }, [avatarUri]);

  return (
    <Pressable
      style={[styles.wrapper, { width: size, height: size }, style]}
      disabled={!isPressable}
      onPress={onPress}
      onLongPress={onLongPress}
      accessibilityRole={isPressable ? 'imagebutton' : 'image'}
      accessibilityLabel={
        accessibilityLabel ??
        (initials ? `Avatar for ${initials}` : 'Avatar')
      }
    >
      {/* Main circle */}
      <View
        style={[
          styles.avatar,
          {
            width: size,
            height: size,
            borderRadius: size / 2,
            backgroundColor: colors.surfaceSecondary,
          },
        ]}
      >
        {showFallback ? (
          <Text
            style={[
              styles.initials,
              {
                fontSize,
                color: colors.textOnPrimary,
              },
            ]}
            allowFontScaling={false}
          >
            {initials?.slice(0, 2).toUpperCase() ?? '?'}
          </Text>
        ) : (
          <Image
            source={{ uri: avatarUri }}
            style={{
              width: size,
              height: size,
              borderRadius: size / 2,
            }}
            contentFit="cover"
            cachePolicy="memory-disk"
            // 回收复用防闪：首次加载 200ms，之后瞬时（见 imageWarm）
            transition={isImageWarm(avatarUri) ? 0 : 200}
            onLoad={() => markImageWarm(avatarUri)}
            // Row-reuse safe: resets stale content before the new avatar
            // loads (Image.md §recyclingKey).
            recyclingKey={avatarUri}
            onError={() => setImageError(true)}
            accessibilityIgnoresInvertColors
          />
        )}
      </View>

      {/* Level Badge：Kotlin 官方等级多色（实底色 + 白字，getIconColorByLevel 复刻） */}
      {level !== undefined && level > 0 && (
        <View
          style={[
            styles.levelBadge,
            {
              backgroundColor: levelBadgeColor(level)?.solidBg ?? colors.accent,
              minWidth: size * 0.42,
              height: size * 0.36,
              borderRadius: size * 0.18,
            },
          ]}
        >
          <Text
            style={[
              styles.levelText,
              { fontSize: Math.max(10, size * 0.22), color: colors.textOnPrimary },
            ]}
            allowFontScaling={false}
            numberOfLines={1}
          >
            Lv.{level}
          </Text>
        </View>
      )}
    </Pressable>
  );
}

// ---------- Styles ----------
const styles = StyleSheet.create({
  wrapper: {
    position: 'relative',
  },
  avatar: {
    overflow: 'hidden',
    alignItems: 'center',
    justifyContent: 'center',
  },
  initials: {
    fontWeight: '600',
    textAlign: 'center',
  },
  levelBadge: {
    position: 'absolute',
    // 徽章下缘超出圆头像 4pt：视觉上"骑"在头像底边上，为等级角标的设计
    // 意图（负值偏移 + 居中定位），与头像尺寸无关，故用负 Spacing.xs 令牌。
    bottom: -Spacing.xs,
    alignSelf: 'center',
    left: 0,
    right: 0,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 4,
  },
  levelText: {
    fontWeight: '700',
    textAlign: 'center',
  },
});

export default Avatar;
