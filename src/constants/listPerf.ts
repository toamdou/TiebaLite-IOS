/**
 * LegendList v3 性能配置（共享常量，2026-08-29）。
 *
 * experimental_adaptiveRender：快速滚动（速度 > 阈值，native 默认 3 px/ms）
 * 时行组件内 useAdaptiveRender() 收到 'light' 模式，各行自行降级渲染。
 * 当前消费点：TweetCard 媒体条在 light 下跳过 PostImageContextMenu 原生
 * 包装层（减少快速滚动中挂载的原生视图数）。
 */
import type { AdaptiveRenderConfig } from '@legendapp/list/react-native';

export const FEED_ADAPTIVE_RENDER: AdaptiveRenderConfig = {};
