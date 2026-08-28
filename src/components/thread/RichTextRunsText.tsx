/**
 * RichTextRunsText — 把 canonical 的 contentToRichTextRuns 产物渲染为
 * RN 嵌套 <Text> 树（thermo 2026-08-26 Z2-F）。
 *
 * 使用场景：原生 TiebaRichText 无法嵌入的「嵌套文本流」上下文
 * （如 PostCard 楼中楼引用行需要与外层 Text 共享排版）。
 * 独立块级场景仍应优先用原生 TiebaRichText（PostContent / subposts）。
 *
 * at/link/topic 的跳转语义与 PostContent 的回调契约一致：
 * 未提供回调时 at/topic 跳用户页/话题页、link 走 openLink。
 */

import { useMemo } from 'react';
import { type StyleProp, type TextStyle } from 'react-native';
import { Text } from '../ui/CompatText';
import { Image } from 'expo-image';
import { useRouter } from 'expo-router';

import { contentToRichTextRuns } from '@/utils/richTextRuns';
import { openLink } from '@/utils/linkOpener';
import type { TiebaRichTextRun } from '../../../modules/tieba-native/src/TiebaRichText';
import type { PostContent as PostContentSegment } from '@/types';

const EMOTICON_SIZE = 20;

export interface RichTextRunsTextProps {
  content: readonly PostContentSegment[] | null | undefined;
  /** 正文基础样式（含颜色；at/link/topic 统一叠加 linkColor） */
  baseStyle?: StyleProp<TextStyle>;
  linkColor: string;
  onUserPress?: (uid: string) => void;
  onTopicPress?: (topicId: string, topicName: string) => void;
  onLinkPress?: (url: string) => void;
}

export function RichTextRunsText({
  content,
  baseStyle,
  linkColor,
  onUserPress,
  onTopicPress,
  onLinkPress,
}: RichTextRunsTextProps) {
  const router = useRouter();
  const runs = useMemo(() => contentToRichTextRuns(content), [content]);

  const nodes = runs.map((run: TiebaRichTextRun, idx: number) => {
    switch (run.kind) {
      case 'emoticon':
        return (
          <Image
            key={idx}
            source={{ uri: run.src }}
            style={styles.emoticon}
            cachePolicy="memory-disk"
            accessibilityLabel={run.text}
          />
        );
      case 'linebreak':
        return <Text key={idx}>{'\n'}</Text>;
      case 'link':
        return (
          <Text
            key={idx}
            style={{ color: linkColor }}
            onPress={(e) => {
              e.stopPropagation();
              if (onLinkPress) onLinkPress(run.url);
              else openLink(run.url);
            }}
          >
            {run.text || run.url}
          </Text>
        );
      case 'at':
        return (
          <Text
            key={idx}
            style={{ color: linkColor }}
            onPress={(e) => {
              e.stopPropagation();
              if (onUserPress) onUserPress(run.uid);
              else router.push(`/user/${run.uid}`);
            }}
          >
            @{run.text}
          </Text>
        );
      case 'topic':
        return (
          <Text
            key={idx}
            style={{ color: linkColor }}
            onPress={(e) => {
              e.stopPropagation();
              if (onTopicPress) onTopicPress(run.topicId, run.text);
              else router.push(`/topic/${run.topicId}?name=${encodeURIComponent(run.text)}`);
            }}
          >
            #{run.text}#
          </Text>
        );
      default:
        // text / emoji
        return <Text key={idx}>{run.text}</Text>;
    }
  });

  return <Text style={baseStyle}>{nodes}</Text>;
}

const styles = {
  emoticon: {
    width: EMOTICON_SIZE,
    height: EMOTICON_SIZE,
    marginHorizontal: 1,
  },
};
