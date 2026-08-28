import { requireNativeViewManager } from 'expo-modules-core';
import { useState } from 'react';
import type { StyleProp, ViewStyle } from 'react-native';

export type TiebaRichTextRun =
  | { kind: 'text'; text: string; fontWeight?: TiebaFontWeight }
  | { kind: 'emoji'; text: string; fontWeight?: TiebaFontWeight }
  | { kind: 'emoticon'; text: string; src: string }
  | { kind: 'linebreak' }
  | { kind: 'link'; text: string; url: string; fontWeight?: TiebaFontWeight }
  | { kind: 'at'; text: string; uid: string; fontWeight?: TiebaFontWeight }
  | { kind: 'topic'; text: string; topicId: string; fontWeight?: TiebaFontWeight };

/** Font weight tokens understood by the native TiebaRichTextView run builder.
 *  Optional — callers that omit it (e.g. contentToRichTextRuns) keep rendering
 *  at regular weight. */
export type TiebaFontWeight = '300' | '400' | '500' | '600' | '700' | '800' | 'bold';

export interface TiebaRichTextProps {
  runs: TiebaRichTextRun[];
  contentWidth?: number;
  fontSize?: number;
  lineHeight?: number;
  textColor?: string;
  linkColor?: string;
  style?: StyleProp<ViewStyle>;
  onLinkPress?: (url: string) => void;
  onUserPress?: (uid: string) => void;
  onTopicPress?: (topicId: string, topicName: string) => void;
}

const NativeTiebaRichText = requireNativeViewManager('TiebaNative', 'TiebaRichTextView');

function unwrap<T>(event: any): T {
  return (event?.nativeEvent ?? event) as T;
}

export function TiebaRichText(props: TiebaRichTextProps) {
  const { style, runs, onLinkPress, onUserPress, onTopicPress, ...rest } = props;
  // Fabric 布局引擎不调用原生 intrinsicContentSize → 自定义 view 宽高都由
  // Yoga 决定：宽度塌成 0、高度恒为 0，正文不可见。原生 rebuild 后把测量
  // 尺寸发来，这里设显式 width+height（Fabric 尊重显式尺寸）。
  // FlashList 回收换帖时 runs 变化 → 原生产生新尺寸事件。
  const [measured, setMeasured] = useState<{ width: number; height: number } | null>(null);
  return (
    <NativeTiebaRichText
      style={[
        style,
        measured != null && measured.height > 0
          ? { width: measured.width, height: measured.height }
          : null,
      ]}
      runs={runs}
      {...rest}
      onContentHeightChange={(event: any) => {
        const payload = unwrap<{ height: number; width: number }>(event);
        if (payload?.height && payload.height > 0 && payload.width > 0) {
          setMeasured({ width: payload.width, height: payload.height });
        }
      }}
      onLinkPress={(event: any) => {
        const payload = unwrap<{ url: string }>(event);
        onLinkPress?.(payload.url);
      }}
      onUserPress={(event: any) => {
        const payload = unwrap<{ uid: string }>(event);
        onUserPress?.(payload.uid);
      }}
      onTopicPress={(event: any) => {
        const payload = unwrap<{ topicId: string; topicName: string }>(event);
        onTopicPress?.(payload.topicId, payload.topicName);
      }}
    />
  );
}
