/**
 * Shared image viewer state for list/detail screens.
 */

import { useCallback, useState } from 'react';
import type { GestureResponderEvent } from 'react-native';

/** 被点击缩略图在窗口坐标系下的屏幕矩形（iOS Photos 式“飞回原位”关闭的目标） */
export interface ImageSourceFrame {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** 大图查看器逐图元数据（与 images 下标一一对应） */
export interface ViewerImageMeta {
  /** 服务端长图标记；未设置时退化为 height > 屏幕精确高度（Kotlin ForumBeanCaster 同判据） */
  isLongPic?: boolean;
  /** 服务端「显示查看原图按钮」（GIF 恒为 false） */
  showOriginalBtn?: boolean;
  /** 图片真实像素宽高（<=0 视为未知） */
  width: number;
  height: number;
}

/** 拿不到具体尺寸时的兜底缩略图大小（仅调用方未提供 size 时使用） */
const DEFAULT_THUMB_SIZE = 96;

/**
 * 从 Pressable 的 onPress 原生事件还原被点击图片的屏幕矩形：
 * pageX/pageY 是触点窗口坐标，locationX/locationY 是触点相对按压视图的偏移，
 * 两者相减即图片视图的左上角；尺寸由调用方提供（各列表单元格尺寸已知：
 * 帖子多图 dims / 单图 pageDim / 引用缩略图 thumbW×90 / 头像 72×72 等）。
 * 拿不到事件坐标时返回 null，查看器退化为“飞出屏幕”关闭。
 */
export function frameFromPressEvent(
  event: GestureResponderEvent,
  size?: { width: number; height: number },
): ImageSourceFrame | null {
  const { pageX, pageY, locationX, locationY } = event.nativeEvent;
  if (typeof pageX !== 'number' || typeof pageY !== 'number') return null;
  return {
    x: pageX - locationX,
    y: pageY - locationY,
    width: size?.width && size.width > 0 ? size.width : DEFAULT_THUMB_SIZE,
    height: size?.height && size.height > 0 ? size.height : DEFAULT_THUMB_SIZE,
  };
}

export function useImageViewer() {
  const [imageViewerVisible, setImageViewerVisible] = useState(false);
  const [imageViewerImages, setImageViewerImages] = useState<string[]>([]);
  const [imageViewerIndex, setImageViewerIndex] = useState(0);
  const [imageViewerSourceFrame, setImageViewerSourceFrame] = useState<ImageSourceFrame | null>(null);
  /** 大图顶栏标题：帖子图片=帖子标题，回复/楼中楼图片=回复文字前 30 字 */
  const [imageViewerContextTitle, setImageViewerContextTitle] = useState<string | null>(null);
  /** 并行原图数组（长按「保存原图」用；与 images 下标一一对应） */
  const [imageViewerOrigins, setImageViewerOrigins] = useState<(string | undefined)[]>([]);
  /** 大图元数据（长图标记/查看原图入口/真实宽高；与 images 下标一一对应，可缺省） */
  const [imageViewerMeta, setImageViewerMeta] = useState<(ViewerImageMeta | undefined)[]>([]);

  const handleImagePress = useCallback((
    images: string[],
    index = 0,
    sourceFrame?: ImageSourceFrame | null,
    origins?: (string | undefined)[],
    contextTitle?: string | null,
    meta?: (ViewerImageMeta | undefined)[],
  ) => {
    setImageViewerImages(images);
    setImageViewerIndex(index);
    setImageViewerSourceFrame(sourceFrame ?? null);
    setImageViewerContextTitle(contextTitle ?? null);
    setImageViewerOrigins(origins ?? []);
    setImageViewerMeta(meta ?? []);
    setImageViewerVisible(true);
  }, []);

  const closeImageViewer = useCallback(() => setImageViewerVisible(false), []);

  return {
    imageViewerVisible,
    imageViewerImages,
    imageViewerIndex,
    imageViewerSourceFrame,
    imageViewerContextTitle,
    imageViewerOrigins,
    imageViewerMeta,
    handleImagePress,
    closeImageViewer,
  };
}
