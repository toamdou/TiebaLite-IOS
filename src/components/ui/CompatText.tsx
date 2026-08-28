import { use } from 'react';
import {
  Text as RnText,
  unstable_TextAncestorContext,
  type TextProps,
} from 'react-native';
import { PlainText, type PlainTextProps } from 'react-native-plain-text';

/**
 * PlainText 全局接入点：纯字符串、单样式、无交互的 Text 直渲 UILabel。
 *
 * 原生批次（pod install + 全量重编 + 重签）完成后把 PLAIN_TEXT_ENABLED 翻成 true；
 * 在此之前 PlainText 没有原生实现，任何渲染都会红屏，必须保持 false。
 * 若真机出现 UILabel 行高裁切，可在启用时同步打开
 * unstable_configureTextCompat({ lineHeightClippingIos: true })（本项目显式 lineHeight 场景多）。
 */
const PLAIN_TEXT_ENABLED = true;

const TextAncestor = unstable_TextAncestorContext;

export function CompatText(props: TextProps) {
  const isNestedText = use(TextAncestor);
  const canUsePlainText =
    PLAIN_TEXT_ENABLED &&
    !isNestedText &&
    typeof props.children === 'string' &&
    !props.onPress &&
    !props.selectable &&
    !props.onTextLayout &&
    !props.selectionColor &&
    !props.suppressHighlighting &&
    !props.adjustsFontSizeToFit &&
    props.minimumFontScale == null;
  if (canUsePlainText) {
    return <PlainText {...(props as PlainTextProps)} />;
  }
  return <RnText {...props} />;
}

export { CompatText as Text };