/**
 * PostImages — 帖内图片块（ImageSegment，第二轮拆分自 PostContent.tsx）
 *
 * 全部图片统一抽取到正文下方独立块（永不内联在文本后）：
 *  - 单图：全宽按宽高比渲染，高度钳制 + 竖长图「长图」徽标（contain 整图可见）
 *  - 多图：X 式横向图片带（MediaPager，与吧页信息流 TweetCard 共用）
 *
 * 尺寸常量收敛（第二轮）：LONG_IMAGE_RATIO / MEDIA_HEIGHT_MAX 均 import 自
 * MediaPager（唯一出处），不再本地复制。
 */

import { View, Pressable, type StyleProp, type ViewStyle } from 'react-native';
import { Text } from '../ui/CompatText';
import { Image } from 'expo-image';
import { SymbolView } from '@/components/ui/SymbolView';
import { useThemeColors } from '@/theme/ThemeContext';
import { useAppPreference } from '@/hooks/useAppPreference';
import { MediaPager, LONG_IMAGE_RATIO, MEDIA_HEIGHT_MAX } from '@/components/feed/MediaPager';
import PostImageContextMenu from '@/components/feed/PostImageContextMenu';
import { thumbnailUrl, THUMB_POST, pickViewerImages } from '@/utils/thumbnail';
import { isImageWarm, markImageWarm } from '@/utils/imageWarm';
import { hapticForScene } from '@/theme/hapticsMap';
import { frameFromPressEvent, type ImageSourceFrame, type ViewerImageMeta } from '@/hooks/useImageViewer';
import { styles } from './postContentStyles';

/** 多图分页统一显示高度（不再随首图比例伸缩，避免横+竖混排时被撑大） */
const MULTI_IMAGE_HEIGHT = 300;

/**
 * 大图查看器回调统一签名（images / origins / meta 与下标一一对应）。
 * 全链路唯一声明处：PostContent / PostCard / PostImages 共用，
 * 消除此前五份手抄签名漂移（PostCard 系不含 meta，此处以可选参数兼容）。
 */
export type ImagePressHandler = (
  images: string[],
  index: number,
  sourceFrame?: ImageSourceFrame | null,
  origins?: (string | undefined)[],
  contextTitle?: string | null,
  meta?: (ViewerImageMeta | undefined)[],
) => void;

/** 帖内抽取出的图片段（服务端长图/查看原图标记由 mapProtoContent 装配） */
export interface ImageSegmentImage {
  src: string;
  width: number;
  height: number;
  originSrc?: string;
  isLongPic?: boolean;
  showOriginalBtn?: boolean;
}

interface ImageSegmentProps {
  images: ImageSegmentImage[];
  contentWidth: number;
  watermarkText?: string;
  forumName?: string;
  contextTitle?: string | null;
  onPress?: ImagePressHandler;
  /** 夜间「图片压暗」（isDark && imageDarkenWhenNight），单图与多图带一致 */
  dimmed?: boolean;
  /** 外部间距（PostContent 传 imageBlockSpaced） */
  style?: StyleProp<ViewStyle>;
}

export function ImageSegment({
  images,
  contentWidth,
  watermarkText,
  forumName,
  contextTitle,
  onPress,
  dimmed = false,
  style,
}: ImageSegmentProps) {
  const { colors } = useThemeColors();
  const count = images.length;
  // 帖内图片加载档位（设置-更多）：smart_origin 缩略图 / all_origin 原图 /
  // all_no 占位块。`?? 'smart_origin'` 仅为 useAppPreference 类型收窄，
  // 运行时 store selector 已兜底。
  const imageLoadType = useAppPreference('imageLoadType', 'smart_origin') ?? 'smart_origin';
  // 注：`?? 'high'` 为类型收窄所需——useAppPreference 签名返回 `T | undefined`，
  // pickViewerImages 需 ViewerImageMode；运行时经 store selector 缺省已兜底。
  const dataSaverMode = useAppPreference('dataSaverMode', 'high') ?? 'high';

  // 并行原图数组（长按「保存原图」/ 大图查看器用）
  const origins = images.map((img) => img.originSrc || img.src);
  // 逐图元数据（服务端长图/查看原图标记 + 真实宽高）：大图查看器据此
  // 决定长图默认原图、菜单是否出现「查看原图」。
  const viewerMeta: (ViewerImageMeta | undefined)[] = images.map((img) => ({
    isLongPic: img.isLongPic,
    showOriginalBtn: img.showOriginalBtn,
    width: img.width,
    height: img.height,
  }));

  // 单图显示尺寸：
  //  - 非长图（横图/方图/普通竖图）：全宽按宽高比，高度钳制在 MEDIA_HEIGHT_MAX
  //    （与 MediaPager 共享常量：原帖内 480 / 信息流 520 双份收敛为 520）
  //  - 竖长图：改用固定高度 MULTI_IMAGE_HEIGHT（contain 整图可见），右下角“长图”徽标，
  //    不再让长图拉满整屏高度；点击进查看器看完整大图。
  const pageDim = (img: { width: number; height: number }) => {
    const aspectRatio = img.width > 0 && img.height > 0 ? img.width / img.height : 1;
    if (img.height > 0 && img.width > 0 && img.height / img.width > LONG_IMAGE_RATIO) {
      return { width: contentWidth, height: MULTI_IMAGE_HEIGHT };
    }
    const height = Math.min(contentWidth / aspectRatio, MEDIA_HEIGHT_MAX);
    return { width: contentWidth, height };
  };

  const isLongImage = (img: { width: number; height: number }) =>
    img.height > 0 && img.width > 0 && img.height / img.width > LONG_IMAGE_RATIO;

  // Limit to 9 images（imageLoadType=all_no 占位也复用此上限）
  const displayImages = images.slice(0, 9);
  const remainingCount = images.length - 9;

  if (contentWidth <= 0) return null;

  // When image loading is disabled entirely, show placeholders
  if (imageLoadType === 'all_no') {
    return (
      <View style={[styles.imageGrid, style]}>
        {displayImages.map((img, idx) => {
          const dims = pageDim(img);
          return (
            <View
              key={idx}
              style={[
                styles.imagePlaceholder,
                {
                  width: dims.width,
                  height: dims.height,
                  backgroundColor: colors.placeholder,
                  borderColor: colors.divider,
                },
              ]}
            >
              <SymbolView name="photo" size={24} tintColor={colors.textDisabled} />
              {idx === 8 && remainingCount > 0 && (
                <View style={styles.imageOverlay}>
                  <Text style={styles.imageOverlayText}>
                    +{remainingCount}
                  </Text>
                </View>
              )}
            </View>
          );
        })}
      </View>
    );
  }

  // 多图 X 式横向图片带（吧页信息流同款，来自 TweetCard/MediaPager）：
  // 统一行高、宽度随宽高比自适应、全卡宽视口 + 卡片圆角边缘裁切、
  // 可左右滑至头像列附近。替代旧翻页式（单页圆角 + 页间空隙）。
  // 需要在 PostCard 卡片上加 overflow hidden（已加）。
  const viewportWidth = Math.max(0, contentWidth + 16 * 2);
  // 对齐内容列左缘（卡 inner padding 16，无头像列场景）
  const leadInset = 16;

  // 多图：X 式横向图片带（保留外部传入的间距 style）
  if (count > 1) {
    // 始终高质量档：图片带直接显示 originSrc（MediaPager 内部 thumbnailUrl
    // 只做 ATS 协议升级、不改尺寸，传原图 URL 即全图渲染）
    const useOriginStrip = imageLoadType === 'all_origin';
    const stripImages = images.map((img) => ({
      src: useOriginStrip ? (img.originSrc || img.src) : img.src,
      originSrc: img.originSrc || img.src,
      width: img.width,
      height: img.height,
    }));
    return (
      // dimmed 与单图分支一致（夜间压暗整条图片带）。压暗放在本层外层 View：
      // MediaPager 为吧页/帖内共享组件，不宜内嵌帖内专属压暗逻辑。
      <View style={[style, dimmed && { opacity: 0.6 }]}>
        <MediaPager
          images={stripImages}
          width={contentWidth}
          viewportWidth={viewportWidth}
          leadInset={leadInset}
          recycleKey={images[0]?.src || ''}
          contextMenu
          forumName={forumName}
          onImagePress={(index, frame) => {
            hapticForScene('press');
            onPress?.(pickViewerImages(images, dataSaverMode), index, frame ?? undefined, origins, contextTitle, viewerMeta);
          }}
        />
      </View>
    );
  }

  // 单图
  const single = images[0];
  const dims = pageDim(single);
  const useOriginalSingle = imageLoadType === 'all_origin';
  const singleUri = useOriginalSingle
    ? (single.originSrc || single.src)
    : thumbnailUrl(single.src, THUMB_POST);
  const singleIsLong = isLongImage(single);
  const singleImageEl = (
    <Pressable
      style={[
        styles.imageWrapper,
        {
          width: dims.width,
          height: dims.height,
          backgroundColor: colors.placeholder,
        },
        style,
      ]}
      onPress={(e) => {
        hapticForScene('press');
        onPress?.(
          pickViewerImages(images, dataSaverMode),
          0,
          frameFromPressEvent(e, dims),
          origins,
          contextTitle,
          viewerMeta,
        );
      }}
    >
      <Image
        cachePolicy="memory-disk" source={{ uri: singleUri }}
        style={[styles.image, dimmed && { opacity: 0.6 }]}
        contentFit={singleIsLong ? 'contain' : 'cover'}
        transition={isImageWarm(singleUri) ? 0 : 200}
        onLoad={() => markImageWarm(singleUri)}
        recyclingKey={singleUri}
      />
      {singleIsLong ? (
        <View style={styles.longBadge} pointerEvents="none">
          <SymbolView name="arrow.down" size={10} tintColor="#FFFFFF" />
          <Text style={styles.longBadgeText}>长图</Text>
        </View>
      ) : null}
    </Pressable>
  );
  // 帖内长按：系统上下文菜单（保存/分享），与信息流一致；长按由原生
  // 手势接管，点击进大图查看器行为不变。
  return (
    <PostImageContextMenu
      full={single.originSrc || single.src}
      width={single.width}
      height={single.height}
      forumName={forumName}
      watermarkText={watermarkText}
    >
      {singleImageEl}
    </PostImageContextMenu>
  );
}
