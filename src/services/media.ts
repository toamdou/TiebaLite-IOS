/**
 * Shared media utilities: save to gallery and share downloaded files.
 */

import { File, Paths } from 'expo-file-system';
import * as MediaLibrary from 'expo-media-library';
import * as Sharing from 'expo-sharing';
import { TiebaNative } from '../../modules/tieba-native/src/TiebaNative';
import { sanitizeUrl } from '@/utils';

async function withWatermark(file: File, watermarkText: string): Promise<string> {
  if (!watermarkText) return file.uri;
  return TiebaNative.applyWatermark(file.uri, watermarkText);
}

function destinationFile(uri: string, prefix: string): File {
  // filename 派生统一收敛点（见全量审查 #7）：URL 末段剥 query/hash，
  // 无末段时退回 `${prefix}_${时间戳}.jpg`，两种前缀（share_/save_）共用。
  const filename =
    uri.split('/').pop()?.split('?')[0]?.split('#')[0] ||
    `${prefix}_${Date.now()}.jpg`;
  return new File(Paths.cache, `${prefix}_${filename}`);
}

/** 水印会生成独立的临时文件；分享结束后尽力清理，避免只靠磁盘 LRU 兜底。 */
async function deleteBestEffort(uri?: string): Promise<void> {
  if (!uri?.startsWith('file:')) return;
  try {
    const f = new (File as any)(uri) as File;
    f.delete();
  } catch {
    // 路径不可构造或已删除 —— 忽略
  }
}

/**
 * Download a remote file to cache and delete it in a finally block.
 *
 * destination 可选：缺省按前缀经 destinationFile 派生（share_/save_ 统一）；
 * 显式传入（如调用方已算好文件名）则直接下载到该目标。shareFile 与
 * saveImageToGallery 共用此实现（此前两处各自下载/清理，逻辑分叉）。
 */
async function withTempFile(
  uri: string,
  prefix: string,
  run: (file: File) => Promise<void>,
  destination?: File,
): Promise<void> {
  const file = destination ?? destinationFile(uri, prefix);
  const downloaded = await File.downloadFileAsync(uri, file);
  try {
    await run(downloaded);
  } finally {
    try {
      downloaded.delete();
    } catch {
      // Best-effort cleanup.
    }
  }
}

/**
 * Save an image to the device photo library with write-only permission.
 */
export async function saveImageToGallery(
  uri: string,
  watermarkText = '',
): Promise<void> {
  const { status } = await MediaLibrary.requestPermissionsAsync(true);
  if (status !== 'granted') {
    throw new Error('PERMISSION_DENIED');
  }
  const safeUri = sanitizeUrl(uri);
  await withTempFile(safeUri, 'save_', async (file) => {
    const watermarked = await withWatermark(file, watermarkText);
    try {
      // SDK 57：saveToLibraryAsync 已废弃（运行时抛错），改用 Asset.create
      await MediaLibrary.Asset.create(watermarked);
    } finally {
      if (watermarked !== file.uri) await deleteBestEffort(watermarked);
    }
  });
}

/**
 * Share a remote file. When sharing is unavailable on the device, the file
 * is still downloaded and its path is returned for callers to surface.
 */
export async function shareFile(
  uri: string,
  filename?: string,
  options?: { mimeType?: string; dialogTitle?: string; watermarkText?: string },
): Promise<void> {
  if (!(await Sharing.isAvailableAsync())) {
    throw new Error('SHARE_UNAVAILABLE');
  }
  const safeUri = sanitizeUrl(uri);
  // 显式文件名（调用方已算好 share_xxx.jpg）→ 落入缓存目录同名文件；
  // 缺省由 withTempFile 按前缀经 destinationFile 派生。
  const target = filename ? new File(Paths.cache, filename) : undefined;
  await withTempFile(safeUri, 'share_', async (file) => {
    const watermarked = await withWatermark(file, options?.watermarkText ?? '');
    try {
      await Sharing.shareAsync(watermarked, {
        mimeType: options?.mimeType ?? 'image/jpeg',
        dialogTitle: options?.dialogTitle ?? '分享',
      });
    } finally {
      if (watermarked !== file.uri) {
        await deleteBestEffort(watermarked);
      }
    }
  }, target);
}
