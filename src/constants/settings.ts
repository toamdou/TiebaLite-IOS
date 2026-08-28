/**
 * Shared settings-page option lists.
 */

import type { Href, ImperativeRouter } from 'expo-router';
import { hapticForScene } from '@/theme/hapticsMap';

export const DEFAULT_SORT_OPTIONS = [
  { label: '按回复时间', value: '0' },
  { label: '按发贴时间', value: '1' },
];

export const FORUM_FAB_OPTIONS = [
  { label: '刷新', value: 'refresh' },
  { label: '回到顶部', value: 'back_to_top' },
  { label: '不显示', value: 'hide' },
];

/** 帖内图片加载三档（档位名对齐 Kotlin strings.xml；WiFi 档需网络状态模块，暂不提供） */
export const IMAGE_LOAD_TYPE_LABELS: Record<string, string> = {
  smart_origin: '智能省流量',
  all_origin: '始终高质量',
  all_no: '始终无图',
};

export const IMAGE_WATERMARK_LABELS: Record<string, string> = {
  none: '不添加',
  username: '用户名',
  forum_name: '吧名',
};

/** 阅读字号档位（乘数，作用于帖子正文字号） */
export const FONT_SCALE_OPTIONS: { label: string; value: string }[] = [
  { label: '小', value: '0.9' },
  { label: '标准', value: '1' },
  { label: '大', value: '1.15' },
  { label: '特大', value: '1.3' },
];

/** 启动默认页档位（值 = (tabs) 路由名） */
export const START_TAB_OPTIONS: { label: string; value: string }[] = [
  { label: '关注', value: 'index' },
  { label: '动态', value: 'explore' },
  { label: '消息', value: 'notifications' },
  { label: '我的', value: 'profile' },
];

/** 时间显示格式档位 */
export const TIMESTAMP_STYLE_OPTIONS: { label: string; value: string }[] = [
  { label: '相对时间（刚刚、x分钟前）', value: 'relative' },
  { label: '绝对时间（年-月-日 时:分）', value: 'absolute' },
];

/** 消息检查频率档位（分钟；低电量模式自动加倍） */
export const NOTIFICATION_POLL_OPTIONS: { label: string; value: string }[] = [
  { label: '每 30 分钟', value: '30' },
  { label: '每 60 分钟', value: '60' },
  { label: '每 120 分钟', value: '120' },
];

/**
 * 设置页统一跳转：震动反馈 + push。
 * 入参收窄为 typed-routes 的 Href，调用点传静态路由字面量即可，
 * 不再需要 `as any`（expo-router 生成的 .expo/types/router.d.ts 已含全部设置路由）。
 */
export function navigateToSettingsRoute(router: ImperativeRouter, route: Href): void {
  hapticForScene('press');
  router.push(route);
}
