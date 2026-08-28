/**
 * PostImageContextMenu — 信息流图片长按操作菜单（X/Twitter 同款 iOS 上下文菜单）
 *
 * 原生层次（TiebaPhotoContextMenuView）：给缩略图挂 UIContextMenuInteraction，
 * 长按激活后系统呈现「背景压暗 + 明亮圆角大图预览 + 深/浅色跟随系统的菜单」，
 * 菜单在预览图正下方；预览首帧复用屏上已渲染的缩略图位图（零下载），
 * 原图后台加载完成淡入替换。点击菜单项回传 id，本组件负责操作执行与反馈：
 * 保存照片（相册，继承水印偏好）/ 分享照片（系统分享）。
 *
 * 渲染形态与普通 View 完全一致——只包一层，不改变信息流任何布局/点击/滚动行为。
 *
 * 性能：不订阅任何 store。水印/账号在「动作触发时」经 getState() 现读——
 * 信息流多图带里每张图都挂一个本组件，逐图 useAppPreference/useAuthStore
 * 订阅是纯浪费；且动作时现读比渲染期捕获更正确（偏好中途改动也生效）。
 */

import { useCallback, type ReactNode } from 'react';
import { Alert } from 'react-native';
import { usePreferencesStore } from '@/stores/preferencesStore';
import { useAuthStore } from '@/stores/authStore';
import { hapticForScene } from '@/theme/hapticsMap';
import { playImageLiftHaptic } from '@/theme/hapticsRealtime';
import { saveImageToGallery, shareFile } from '@/services/media';
import { showToast } from '@/components/ui/Toast';
import {
  TiebaPhotoContextMenu,
  type PhotoMenuAction,
} from '../../../modules/tieba-native/src/TiebaPhotoContextMenu';

/** 默认菜单项：保存 / 分享 */
export const POST_IMAGE_ACTIONS: PhotoMenuAction[] = [
  { id: 'save', title: '保存照片', icon: 'square.and.arrow.down' },
  { id: 'share', title: '分享照片', icon: 'square.and.arrow.up' },
];

/** 动作触发时的水印文案解析（优先 preset，其次按偏好：用户名 / 吧名） */
function resolveWatermarkText(forumName?: string, preset?: string): string {
  if (preset !== undefined) return preset;
  const prefs = usePreferencesStore.getState().preferences;
  if (!prefs.imageWatermarkEnabled) return '';
  switch (prefs.imageWatermark) {
    case 'username':
      return useAuthStore.getState().account?.name ?? '';
    case 'forum_name':
      return forumName ?? '';
    default:
      return '';
  }
}

async function savePhoto(full: string, watermark: string) {
  try {
    await saveImageToGallery(full, watermark);
    hapticForScene('action-success');
    showToast('保存成功');
  } catch (e: any) {
    hapticForScene('action-fail');
    if (e?.message === 'PERMISSION_DENIED') {
      Alert.alert('权限不足', '请在设置中允许访问相册以保存照片');
      return;
    }
    Alert.alert('保存失败', e?.message || '无法保存照片到相册');
  }
}

async function sharePhoto(full: string, watermark: string) {
  try {
    const filename = full.split('/').pop()?.split('?')[0] ?? `image_${Date.now()}.jpg`;
    await shareFile(full, `share_${filename}`, {
      mimeType: 'image/jpeg',
      dialogTitle: watermark ? `分享图片 — ${watermark}` : '分享图片',
      watermarkText: watermark,
    });
  } catch (e: any) {
    if (e?.message === 'SHARE_UNAVAILABLE') {
      Alert.alert('提示', '当前设备不支持分享功能');
    }
  }
}

export interface PostImageContextMenuProps {
  /** 原图 URL（预览后台加载目标） */
  full: string;
  /** 原图像素宽高（预览尺寸计算；缺省按方形兜底） */
  width?: number;
  height?: number;
  /** 所在吧名：水印偏好为「吧名」时保存/分享使用 */
  forumName?: string;
  /** 已算好的水印文本（优先于偏好计算，帖内场景透传上层文案） */
  watermarkText?: string;
  /** 是否显示放大预览（默认 true；大图查看器内传 false 只要菜单） */
  previewEnabled?: boolean;
  /** 锚点内容：已渲染的缩略图（其位图即预览首帧） */
  children?: ReactNode;
}

export default function PostImageContextMenu({
  full,
  width,
  height,
  forumName,
  watermarkText: presetWatermark,
  previewEnabled = true,
  children,
}: PostImageContextMenuProps) {
  const handleAction = useCallback(
    (actionId: string) => {
      const watermark = resolveWatermarkText(forumName, presetWatermark);
      if (actionId === 'save') void savePhoto(full, watermark);
      else if (actionId === 'share') void sharePhoto(full, watermark);
    },
    [full, forumName, presetWatermark],
  );

  // 长按激活、大图预览升起的一瞬间：「弹出大图」实时触觉（档位/开关在
  // 设置-震动设置「实时触觉」；内部自带总开关与关闭短路）
  const handleMenuPresent = useCallback(() => {
    playImageLiftHaptic();
  }, []);

  return (
    <TiebaPhotoContextMenu
      fullUrl={full}
      imageWidth={width ?? 0}
      imageHeight={height ?? 0}
      previewEnabled={previewEnabled}
      actions={POST_IMAGE_ACTIONS}
      onAction={handleAction}
      onMenuPresent={handleMenuPresent}
    >
      {children}
    </TiebaPhotoContextMenu>
  );
}