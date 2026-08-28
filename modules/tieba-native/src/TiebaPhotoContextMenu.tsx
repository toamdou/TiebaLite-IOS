import { requireNativeViewManager } from 'expo-modules-core';
import type { ReactNode } from 'react';
import type { StyleProp, ViewStyle } from 'react-native';

const NativeTiebaPhotoContextMenu = requireNativeViewManager(
  'TiebaNative',
  'TiebaPhotoContextMenuView',
);

export interface PhotoMenuAction {
  /** 唯一 id，点击后经 onAction 原样回传 */
  id: string;
  /** 菜单标题 */
  title: string;
  /** SF Symbol 名称（如 square.and.arrow.down），缺省菜单行无图标 */
  icon?: string;
  /** 红色警示样式（如「删除」类操作） */
  destructive?: boolean;
}

export interface TiebaPhotoContextMenuProps {
  /** 原图 URL（长按预览的后台加载目标；http 会由原生统一升级 https） */
  fullUrl?: string;
  /** 原图像素宽高（预览尺寸计算；缺省/<=0 按方形兜底） */
  imageWidth?: number;
  imageHeight?: number;
  /** 是否显示放大预览（默认 true）；false 时仅菜单在长按位置弹出 */
  previewEnabled?: boolean;
  /** 菜单项（默认不显示菜单则长按只出预览） */
  actions?: PhotoMenuAction[];
  /** 点击菜单项回调（回传 action.id） */
  onAction?: (actionId: string) => void;
  /** 长按激活、预览/菜单升起动画开始的瞬间（previewEnabled=true 才会触发） */
  onMenuPresent?: () => void;
  style?: StyleProp<ViewStyle>;
  /** 锚点内容：通常是一张已渲染的缩略图；首帧预览直接截取它的位图 */
  children?: ReactNode;
}

/**
 * 长按图片 → iOS 系统上下文菜单容器（X/Twitter 同款形态）：
 * 背景压暗 + 明亮圆角大图预览（居中、菜单紧随其下，深浅色跟随系统）。
 * 渲染形态与普通 View 完全一致，长按手势/动画/触觉全部由原生系统处理。
 */
export function TiebaPhotoContextMenu({
  fullUrl,
  imageWidth,
  imageHeight,
  previewEnabled = true,
  actions,
  onAction,
  onMenuPresent,
  style,
  children,
}: TiebaPhotoContextMenuProps) {
  return (
    <NativeTiebaPhotoContextMenu
      style={style}
      fullUrl={fullUrl}
      imageWidth={imageWidth ?? 0}
      imageHeight={imageHeight ?? 0}
      previewEnabled={previewEnabled}
      actions={actions}
      onAction={(e: any) => onAction?.(e.nativeEvent.action)}
      onMenuPresent={onMenuPresent}
    >
      {children}
    </NativeTiebaPhotoContextMenu>
  );
}

export default TiebaPhotoContextMenu;