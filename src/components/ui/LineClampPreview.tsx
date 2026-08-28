/**
 * LineClampPreview — 折叠态「隐藏测量行数 + 前 N 行预览 + 行尾『… 更多』」
 * 的共享实现（thermo 2026-08-26 Z2-G/Z4-E：收敛 PostCard.SubQuoteItem 与
 * subposts.ParentReplyCard 两份同构样板）。
 *
 * 为什么不用 numberOfLines：原文在 flexWrap 容器内 numberOfLines 会错误撑高，
 * 且它会把 onTextLayout 的报告也钳成 N 行无法自证截断——必须用隐藏测量
 * Text 读真实行数、再按行拼接预览（历史事故结论，两处旧注释一致）。
 *
 * measureCharLimit：超长文本的测量降本（父楼页用 2000——手机窄列下远超
 * N 行，「是否溢出」与「前 N 行文本」判定和全文测量完全一致）。
 */
import { useMemo, useState } from 'react';
import { type StyleProp, type TextStyle } from 'react-native';
import { Text } from './CompatText';

export interface LineClampPreviewProps {
  /** 纯文本全文（调用方先用 contentToText 归一） */
  text: string;
  maxLines: number;
  textStyle: StyleProp<TextStyle>;
  /** 行尾「… 更多」颜色（与正文同字号加粗以示可点） */
  readMoreColor: string;
  /** 「… 更多」点击回调（展开切换由调用方持有） */
  onExpand?: () => void;
  /** 展开提示的无障碍标签 */
  readMoreLabel?: string;
  /** 测量字符上限（可选；截断只影响测量不影响可见文本语义） */
  measureCharLimit?: number;
  /**
   * 两段 Text 的 pointerEvents（'none' = 触摸穿透到外层整卡 Pressable；
   * PostCard.SubQuoteItem 历史行为即 none，父楼页不传保持可点）。
   */
  textPointerEvents?: 'none';
}

export function LineClampPreview({
  text,
  maxLines,
  textStyle,
  readMoreColor,
  onExpand,
  readMoreLabel = '展开全文',
  measureCharLimit,
  textPointerEvents,
}: LineClampPreviewProps) {
  const [previewLines, setPreviewLines] = useState<string[]>([]);
  const [overflows, setOverflows] = useState(false);

  const measureText = useMemo(
    () =>
      measureCharLimit != null && text.length > measureCharLimit
        ? text.slice(0, measureCharLimit)
        : text,
    [text, measureCharLimit],
  );

  return (
    <>
      {/* 隐藏测量文本：仅用于 onTextLayout 读真实行数，不参与排版 */}
      <Text
        pointerEvents={textPointerEvents}
        style={[textStyle, styles.measure]}
        onTextLayout={(e) => {
          setPreviewLines(e.nativeEvent.lines.map((l) => l.text));
          setOverflows(e.nativeEvent.lines.length > maxLines);
        }}
      >
        {measureText}
      </Text>
      {/* 可见折叠文本：溢出时按实测前 N 行渲染 + 行尾内联后缀 */}
      <Text pointerEvents={textPointerEvents} style={textStyle}>
        {overflows ? (
          <>
            {previewLines.slice(0, maxLines).join('\n')}
            <Text
              onPress={onExpand}
              accessibilityRole="button"
              accessibilityLabel={readMoreLabel}
              style={[styles.readMore, { color: readMoreColor }]}
            >
              … 更多
            </Text>
          </>
        ) : (
          text
        )}
      </Text>
    </>
  );
}

const styles = {
  measure: {
    position: 'absolute' as const,
    top: 0,
    left: 0,
    right: 0,
    opacity: 0,
  },
  readMore: {
    fontWeight: '600' as const,
  },
};
