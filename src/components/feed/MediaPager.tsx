/**
 * MediaPager — 卡内媒体区（TweetCard 信息流卡 / PostContent 帖内楼层共用）
 *
 *   单图：按宽高比钳制显示（含长图徽标/视频 poster）
 *   多图：X 式横向平滑图片带 —— 多图并排共显、统一行高、宽度随各图宽高比
 *   自适应（不拉伸不裁切）、全卡宽可视视口 + 卡片边缘裁切、惯性减速自由滚。
 *
 * 自 TweetCard.tsx 抽出（全量审查 #2）：横带常量、PagerImage 类型与实现随迁，
 * TweetCard / PostContent 均从本文件 import。
 */

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  View,
  Text,
  Pressable,
  StyleSheet,
  ScrollView,
} from 'react-native';
import { clamp } from 'react-native-reanimated';
import { Image } from 'expo-image';
import { useThemeColors } from '@/theme/ThemeContext';
import {Radius} from '@/theme/spacing';
import { thumbnailUrl, THUMB_POST } from '@/utils/thumbnail';
import { isImageWarm, markImageWarm } from '@/utils/imageWarm';
import { frameFromPressEvent, type ImageSourceFrame } from '@/hooks/useImageViewer';
import { stopPropagation } from '@/utils/gesture';
import PostImageContextMenu from '@/components/feed/PostImageContextMenu';
import { SymbolView } from '@/components/ui/SymbolView';

/** 媒体区高度钳制：长图全显不截断（contain），超高则限制高度防撑爆卡片 */
// （尺寸常量收敛第二轮：PostImages 等外部消费方直接 import，取值冻结 520）
export const MEDIA_HEIGHT_MAX = 520;
/** 无尺寸信息时的兜底显示高度（宽高比未知按近似方形） */
const MULTI_MEDIA_HEIGHT = 260;
/** 宽高比（h/w）超过该值视为竖长图 → 右下角"长图"徽标（对齐 Kotlin） */
// （尺寸常量收敛第二轮：PostImages 等外部消费方直接 import，取值冻结 2.4）
export const LONG_IMAGE_RATIO = 2.4;
/** X 式图片带：统一行高下限/上限（极端比例钳制，防止过矮/过高撑爆卡片） */
const STRIP_HEIGHT_MIN = 160;
const STRIP_HEIGHT_MAX = 340;
/** X 式图片带：图间距（可配，0 表示紧贴） */
const STRIP_GAP = 4;

export interface PagerImage {
  src: string;
  originSrc: string;
  /** 更小一档的服务端派生图（srcPic，查看器省流档用；卡片显示仍走 src/bigPic） */
  smallSrc?: string;
  width: number;
  height: number;
}

export const MediaPager = React.memo(function MediaPager({
  images,
  videoPoster,
  width,
  viewportWidth,
  leadInset,
  recycleKey,
  contextMenu = false,
  light = false,
  forumName,
  onImagePress,
  onFallbackPress,
}: {
  images: PagerImage[];
  videoPoster?: string;
  /** 内容列宽 W_c：单图铺满该宽度时的自然高度 = W_c / rᵢ 以此为准 */
  width: number;
  /** 图片带可视视口宽：横跨整卡宽（含左右 padding），左缘贴卡片边框 */
  viewportWidth: number;
  /** 图片带初始左缘对齐内容列左界 L0 的位移（= 卡片 padding + 头像列宽 + 列间距） */
  leadInset: number;
  recycleKey: string;
  /** 图片长按菜单（X 同款），默认关闭 */
  contextMenu?: boolean;
  /** LegendList 自适应渲染 light 模式（快速滚动）：跳过原生右键菜单包装层 */
  light?: boolean;
  /** 所在吧名（长按保存/分享的水印用） */
  forumName?: string;
  onImagePress: (index: number, sourceFrame?: ImageSourceFrame | null) => void;
  /** 视频 poster 点击兜底（无此回调时点击无操作；PostImages 场景不传） */
  onFallbackPress?: () => void;
}) {
  const { isDark } = useThemeColors();

  // 每张图按自身宽高比算显示高度（宽度固定）→ 贴合实际长高，上下不再留大片
  // 空白。之前单图钳制在 200…520、多图写死 260，横图/竖图都被拉出空白带。
  // 仅对极端超高（> MEDIA_HEIGHT_MAX 相对宽比）仍截断显示 + 长图徽标。
  const heightOf = useCallback((i: number): number => {
    const img = images[i];
    if (!img) return MULTI_MEDIA_HEIGHT;
    const ratio =
      img.width > 0 && img.height > 0 ? img.height / img.width : 1;
    // 宽度为 1（未取到）时按方形兜底
    const displayW = width || 300;
    return Math.round(clamp(displayW * Math.max(ratio, 0.01), 1, MEDIA_HEIGHT_MAX));
  }, [images, width]);

  const placeholderBg = isDark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.04)';

  // ── 单图 / 视频 poster ──
  if (images.length <= 1) {
    // 卡片显示用服务端小档（srcPic）：CDN w= 注入停用后 src 即 bigPic(~960px)，
    // 直接解码整页大图是滚动 hitch 的主因（2026-08-29 仪器归因）；查看器仍走全档。
    const img0 = images[0];
    const uri = (img0 && (img0.smallSrc || img0.src)) || videoPoster;
    if (!uri) return null;
    const thumb = thumbnailUrl(uri, THUMB_POST);
    const isVideo = !img0 && !!videoPoster;
    const isLong = !!img0 && img0.height > 0 && img0.width > 0 && img0.height / img0.width > LONG_IMAGE_RATIO;
    const singleHeight = heightOf(0);
    const thumbEl = (
      <Pressable
        onPress={(e) =>
          isVideo
            ? onFallbackPress?.()
            : onImagePress(0, frameFromPressEvent(e, { width, height: singleHeight }))
        }
        onPressIn={stopPropagation}
        onPressOut={stopPropagation}
        accessibilityRole="imagebutton"
        accessibilityLabel={isVideo ? '视频' : '查看图片'}
      >
        <Image
          source={{ uri: thumb }}
          style={{ width, height: singleHeight }}
          contentFit="contain"
          cachePolicy="memory-disk"
          placeholder={placeholderBg}
          placeholderContentFit="cover"
          // 回收复用防闪：首次加载保留 200ms 过渡；本会话已加载过的 URI 瞬时换图
          //（recycleItems 下每行 recyclingKey 变更都会从占位符重走一次 fade）
          transition={isImageWarm(thumb) ? 0 : 200}
          onLoad={() => markImageWarm(thumb)}
          recyclingKey={thumb}
        />
        {isVideo ? (
          <View style={styles.videoBadge}>
            <SymbolView name="play.fill" size={20} tintColor="#FFFFFF" />
          </View>
        ) : null}
        {!isVideo && isLong ? (
          <View style={styles.longBadge} pointerEvents="none">
            <SymbolView name="arrow.down" size={10} tintColor="#FFFFFF" />
            <Text style={styles.longBadgeText}>长图</Text>
          </View>
        ) : null}
      </Pressable>
    );
    const mediaEl = contextMenu && !light && !isVideo && img0 ? (
      <PostImageContextMenu full={img0.originSrc} width={img0.width} height={img0.height} forumName={forumName}>
        {thumbEl}
      </PostImageContextMenu>
    ) : thumbEl;
    return (
      <View style={[styles.mediaWrap, { width, height: singleHeight, backgroundColor: placeholderBg }]}>
        {mediaEl}
      </View>
    );
  }

  // ── 多图横向平滑图片带（X 式）──
  // 独立组件：计数角标需要 hook，不能挂在上面单图早退分支之后（条件 hook）。
  return (
    <MultiImageStrip
      images={images}
      width={width}
      viewportWidth={viewportWidth}
      leadInset={leadInset}
      recycleKey={recycleKey}
      contextMenu={contextMenu}
      light={light}
      forumName={forumName}
      onImagePress={onImagePress}
    />
  );
});

/**
 * 多图横向平滑图片带（X 式，仅 images.length ≥ 2 时挂载）
 *
 * 统一行高：自然高度 h′ᵢ = W_c / rᵢ（rᵢ = wᵢ/hᵢ），基准行高 H0 = min(h′ᵢ)，
 * 最终行高 H = clamp(H0, STRIP_HEIGHT_MIN, STRIP_HEIGHT_MAX)。
 * 每张图宽度 w″ᵢ = H × rᵢ —— 全组等高、宽度随自身宽高比伸缩，不拉伸不裁切。
 * 整组图片带高度恒定，滑动全程无尺寸突跳（替代旧版"翻页后按当前页重算高度"）。
 */
const MultiImageStrip = React.memo(function MultiImageStrip({
  images,
  width,
  viewportWidth,
  leadInset,
  recycleKey,
  contextMenu,
  light = false,
  forumName,
  onImagePress,
}: {
  images: PagerImage[];
  width: number;
  viewportWidth: number;
  leadInset: number;
  recycleKey: string;
  contextMenu?: boolean;
  /** 自适应渲染 light 模式：跳过原生右键菜单包装层 */
  light?: boolean;
  forumName?: string;
  onImagePress: (index: number, sourceFrame?: ImageSourceFrame | null) => void;
}) {
  const { isDark } = useThemeColors();
  const placeholderBg = isDark ? 'rgba(255,255,255,0.06)' : 'rgba(0,0,0,0.04)';
  const scrollRef = useRef<ScrollView>(null);
  // 行切换时（recycleKey 变化，列表行组件复用/re-key）：把图片带归位到
  // 初始位置（左缘对齐内容列）
  useEffect(() => {
    scrollRef.current?.scrollTo?.({ x: 0, animated: false });
  }, [recycleKey]);

  const ratios = images.map((img) => (img.width > 0 && img.height > 0 ? img.width / img.height : 1));
  const naturalHeights = ratios.map((r) => width / Math.max(r, 0.01));
  const stripHeight = Math.round(clamp(Math.min(...naturalHeights), STRIP_HEIGHT_MIN, STRIP_HEIGHT_MAX));
  const itemWidths = ratios.map((r) => stripHeight * r);

  // 计数角标「i/N」：视口中心落在第几张图上。仅在整数序号变化时 setState
  //（一次甩动最多 N 次提交），滚动帧本身不做重渲。
  const [activeIndex, setActiveIndex] = useState(0);
  const itemCenters = useMemo(() => {
    let acc = leadInset;
    return itemWidths.map((w) => {
      const center = acc + w / 2;
      acc += w + STRIP_GAP;
      return center;
    });
  }, [itemWidths, leadInset]);
  const handleStripScroll = useCallback(
    (e: { nativeEvent: { contentOffset: { x: number } } }) => {
      const center = e.nativeEvent.contentOffset.x + viewportWidth / 2;
      let idx = 0;
      while (idx + 1 < itemCenters.length && itemCenters[idx + 1] <= center) idx++;
      setActiveIndex((prev) => (prev === idx ? prev : idx));
    },
    [itemCenters, viewportWidth],
  );

  // 视口横跨整卡宽（负 margin 抵消 contentCol 缩进），左缘贴卡片边框起点：
  // 图片带初始左缘在 L0（内容列左界），左滑可越入头像列空白区直到卡片左缘，
  // 超出视口的任何部分即时裁切（裁切界 = 卡片左右边缘；含卡片圆角由卡片
  // overflow hidden 处理）。contentContainer 左侧 leadInset 提供"越入空间"。
  // 外层 View 承载裁切与计数角标（ScrollView 内无法挂 absolute 覆盖层）。
  return (
    <View
      style={[
        styles.stripViewport,
        { width: viewportWidth, height: stripHeight, marginLeft: -leadInset },
      ]}
    >
      <ScrollView
        ref={scrollRef}
        horizontal
        showsHorizontalScrollIndicator={false}
        decelerationRate="normal"
        directionalLockEnabled
        nestedScrollEnabled
        style={StyleSheet.absoluteFill}
        onScroll={handleStripScroll}
        scrollEventThrottle={100}
        contentContainerStyle={[styles.stripContent, { paddingLeft: leadInset, gap: STRIP_GAP }]}
      >
        {images.map((img, i) => {
          const w = itemWidths[i];
          // 卡片档用 srcPic 小档（缺失回落 src/bigPic）：同上，避免解码 960px 大图
          const thumb = thumbnailUrl(img.smallSrc || img.src, THUMB_POST);
          const isLong = img.height > 0 && img.width > 0 && img.height / img.width > LONG_IMAGE_RATIO;
          const thumbEl = (
            <Pressable
              onPress={(e) => onImagePress(i, frameFromPressEvent(e, { width: w, height: stripHeight }))}
              onPressIn={stopPropagation}
              onPressOut={stopPropagation}
              accessibilityRole="imagebutton"
              accessibilityLabel={`第${i + 1}张图片`}
              style={{ width: w, height: stripHeight }}
            >
              <Image
                source={{ uri: thumb }}
                style={{ width: w, height: stripHeight, backgroundColor: placeholderBg }}
                contentFit="cover"
                cachePolicy="memory-disk"
                placeholder={placeholderBg}
                placeholderContentFit="cover"
                transition={isImageWarm(thumb) ? 0 : 200}
                onLoad={() => markImageWarm(thumb)}
                recyclingKey={thumb}
              />
              {isLong ? (
                <View style={styles.longBadge} pointerEvents="none">
                  <SymbolView name="arrow.down" size={10} tintColor="#FFFFFF" />
                  <Text style={styles.longBadgeText}>长图</Text>
                </View>
              ) : null}
            </Pressable>
          );
          return contextMenu && !light ? (
            <PostImageContextMenu
              key={`${recycleKey}-${i}`}
              full={img.originSrc}
              width={img.width}
              height={img.height}
              forumName={forumName}
            >
              {thumbEl}
            </PostImageContextMenu>
          ) : (
            <React.Fragment key={`${recycleKey}-${i}`}>{thumbEl}</React.Fragment>
          );
        })}
      </ScrollView>
      {/* 计数角标：右下角「当前/总数」——首图占满时提示可左滑看更多 */}
      <View style={styles.countBadge} pointerEvents="none">
        <Text style={styles.countBadgeText}>
          {activeIndex + 1}/{images.length}
        </Text>
      </View>
    </View>
  );
});

const styles = StyleSheet.create({
  mediaWrap: {
    borderRadius: Radius.card - 4,
    borderCurve: 'continuous',
    overflow: 'hidden',
  },
  videoBadge: {
    position: 'absolute',
    top: '50%',
    left: '50%',
    marginTop: -22,
    marginLeft: -22,
    width: 44,
    height: 44,
    borderRadius: 22,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(0,0,0,0.45)',
    justifyContent: 'center',
    alignItems: 'center',
  },
  /* 长图徽标：右下角深色胶囊（对齐 Kotlin 长图右下角标识） */
  longBadge: {
    position: 'absolute',
    right: 8,
    bottom: 8,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 3,
    paddingHorizontal: 7,
    paddingVertical: 3,
    borderRadius: 10,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(0,0,0,0.55)',
  },
  longBadgeText: {
    color: '#FFFFFF',
    fontSize: 11,
    fontWeight: '600',
  },
  /* 多图计数角标：视口右下角「当前/总数」（与长图徽标同视觉语言） */
  countBadge: {
    position: 'absolute',
    right: 8,
    bottom: 8,
    paddingHorizontal: 7,
    paddingVertical: 2,
    borderRadius: 10,
    borderCurve: 'continuous',
    backgroundColor: 'rgba(0,0,0,0.55)',
    overflow: 'hidden',
  },
  countBadgeText: {
    color: '#FFFFFF',
    fontSize: 11,
    fontWeight: '600',
    fontVariant: ['tabular-nums'],
  },
  /* 多图图片带：视口贴卡片左右边框，滚动内容自行裁切；圆角交给卡片 overflow hidden */
  stripViewport: {
    overflow: 'hidden',
  },
  stripContent: {
    flexDirection: 'row',
    alignItems: 'stretch',
  },
});