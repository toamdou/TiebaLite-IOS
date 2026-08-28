import type { TiebaRichTextRun, TiebaFontWeight } from '../../modules/tieba-native/src/TiebaRichText';
import type { PostContent as PostContentSegment } from '@/types';
import { EMOTICON_NAME_MAP, buildEmoticonSrc } from '@/constants/emoticons';

/**
 * 帖内/楼中楼文本级段 → 原生富文本 run 的 canonical 装配器（第二轮收敛）。
 *
 * 职责：
 *  - 全部内联段类型（text / emoji / emoticon / linebreak / link / at / topic）
 *  - 表情文本拆包：text 段内 #(名) / [名] / (#名) → emoticon run（opt-in）
 *  - 内容屏蔽过滤：isBlocked 命中的段不产出 run（tieba 帖子列表以此隐藏屏蔽词）
 *  - topic run 字重（opt-in，PostContent 传 '500' 对齐 Kotlin）
 *
 * Block 级段（image / video / audio / poll）由调用方布局层（PostContent /
 * subposts 各自的拆分循环）负责，这里一律不产出 —— 与 Kotlin 侧
 * PbContentRender 的「文本 flow + 块媒体」拆分一致。
 *
 * 接口契约（subposts 页按此切换调用点）：
 *   contentToRichTextRuns(content, opts?)
 *   - content：PostContent 段数组；缺省/空 → []
 *   - opts.splitEmoticonText?：text 段表情拆包开关（默认 false，保持
 *     subposts 现行为）
 *   - opts.fontWeight?：topic run 字重（默认 undefined → 常规字重，
 *     保持 subposts 现行为；PostContent 传 '500'）
 *   - opts.isBlocked? / opts.onBlocked?：段级屏蔽过滤 + 命中回调
 *     （PostContent 用 onBlocked 渲染「内容已屏蔽」提示条）
 */
export interface ContentToRichTextRunsOptions {
  /** 表情文本拆包：text 段内 #(名) / [名] / (#名) → emoticon run。默认 false */
  splitEmoticonText?: boolean;
  /** topic run 字重（TiebaFontWeight；默认 undefined = 常规字重） */
  fontWeight?: TiebaFontWeight;
  /** 段级内容屏蔽判定；返回 true 的段不产出 run（也不产出 emoticon 拆包） */
  isBlocked?: (segment: PostContentSegment) => boolean;
  /** 屏蔽命中回调（每个命中段调用一次；PostContent 用它渲染提示条） */
  onBlocked?: (segment: PostContentSegment) => void;
}

export type TextOrEmoticon =
  | { type: 'text'; text: string }
  | { type: 'emoticon'; text: string; src: string };

/**
 * 把文本段按贴吧表情语法拆成 text / emoticon 片段。
 * 匹配 #(name)、[name]、(#name) 三种写法；未知表情名保留原文。
 */
export function splitTextWithEmoticons(text: string): TextOrEmoticon[] {
  const segments: TextOrEmoticon[] = [];
  const regex = /#\(([^)]+)\)|\((#[^)]+)\)|\[([^\]]+)\]/g;
  let lastIndex = 0;
  let match: RegExpExecArray | null;

  while ((match = regex.exec(text)) !== null) {
    if (match.index > lastIndex) {
      segments.push({ type: 'text', text: text.slice(lastIndex, match.index) });
    }
    // Extract the emoticon name from whichever group matched
    let name = match[1] || ''; // #(name)
    if (!name && match[2]) name = match[2].slice(1); // (#name) -> strip leading #
    if (!name && match[3]) name = match[3]; // [name]
    const num = EMOTICON_NAME_MAP[name];
    if (num) {
      segments.push({
        type: 'emoticon',
        text: name,
        src: buildEmoticonSrc(num),
      });
    } else {
      // Unknown emoticon name, keep as original text
      segments.push({ type: 'text', text: match[0] });
    }
    lastIndex = regex.lastIndex;
  }

  if (lastIndex < text.length) {
    segments.push({ type: 'text', text: text.slice(lastIndex) });
  }

  return segments.length > 0 ? segments : [{ type: 'text', text }];
}

/**
 * Convert mapped post content segments into native attributed-string runs.
 * Block media (image/video/audio/poll) is intentionally omitted here and
 * rendered by the surrounding RN layout.
 */
export function contentToRichTextRuns(
  content: readonly PostContentSegment[] | null | undefined,
  opts: ContentToRichTextRunsOptions = {},
): TiebaRichTextRun[] {
  const { splitEmoticonText = false, fontWeight, isBlocked, onBlocked } = opts;
  const runs: TiebaRichTextRun[] = [];
  for (const segment of content ?? []) {
    if (!segment) continue;
    if (isBlocked?.(segment)) {
      onBlocked?.(segment);
      continue;
    }
    switch (segment.type) {
      case 'text': {
        if (splitEmoticonText) {
          for (const part of splitTextWithEmoticons(segment.text ?? '')) {
            if (part.type === 'emoticon') {
              runs.push({ kind: 'emoticon', text: part.text, src: part.src });
            } else {
              runs.push({ kind: 'text', text: part.text });
            }
          }
        } else {
          runs.push({ kind: 'text', text: segment.text ?? '' });
        }
        break;
      }
      case 'emoji':
        runs.push({ kind: 'emoji', text: segment.text ?? '' });
        break;
      case 'emoticon':
        runs.push({ kind: 'emoticon', text: segment.text ?? '', src: segment.src ?? '' });
        break;
      case 'linebreak':
        runs.push({ kind: 'linebreak' });
        break;
      case 'link':
        runs.push({ kind: 'link', text: segment.text ?? segment.url ?? '', url: segment.url ?? '' });
        break;
      case 'at':
        runs.push({ kind: 'at', text: segment.text ?? '', uid: String(segment.uid ?? '') });
        break;
      case 'topic':
        runs.push({
          kind: 'topic',
          text: segment.text ?? '',
          topicId: String(segment.topicId ?? ''),
          ...(fontWeight ? { fontWeight } : null),
        });
        break;
      default:
        // image / video / audio / poll：block 级，由调用方布局层处理
        break;
    }
  }
  return runs;
}