import type { AppPreferences } from '@/types';
import { DEFAULT_CUSTOM_PRIMARY } from '@/theme/colors';

/**
 * Default application preferences used when no stored values exist.
 * Kept outside PreferencesStorage so the reactive preference cache can
 * share it without creating a circular import.
 */
export const DEFAULT_PREFERENCES: AppPreferences = {
  fontScale: 1.0,
  autoSign: false,
  autoSignTime: '08:00',
  imageLoadType: 'smart_origin',
  incognitoMode: false,
  defaultSortType: '0',
  forumFabFunction: 'refresh', // 发帖已按产品要求移除；refresh | back_to_top | hide
  /** 默认 = 初始内置配色（设置图标五彩态，等价原 tieba/dark） */
  lightTheme: 'default',
  darkTheme: 'default',
  darkMode: false,
  followSystemDarkMode: true,
  toolbarPrimaryColor: false,
  statusBarFontDark: false,
  showBothUsername: false,
  collectSeeLz: true,
  collectDescSort: false,
  showShortcutInThread: true,
  blockVideo: false,
  hideMedia: false,
  hideBlockedContent: false,
  imageWatermarkEnabled: false,
  imageWatermark: 'none',
  imageDarkenWhenNight: true,
  useBuiltInBrowser: true,
  // 默认主色与 colors.ts DEFAULT_CUSTOM_PRIMARY 同源（避免双源漂移）
  customPrimaryColor: DEFAULT_CUSTOM_PRIMARY,
  slowSignMode: false,
  failAutoStop: true,
  useOfficialSign: true,
  liveActivitySignEnabled: true,
  /** 默认在灵动岛显示签到进度（可在设置改为通知栏） */
  signDisplayMode: 'liveActivity',
  /** 默认关闭静默签到（完成通知带声音提示） */
  signSilent: false,
  /** 默认按等级排序关注吧列表（右上角图标切换为按名称） */
  forumSortMode: 'level',
  homePageShowHistoryForum: true,
  /** 关注吧列表布局：true = 一行一个；false = 一行两个（Kotlin listSingle 对位） */
  forumListSingle: true,
  exploreAutoRefresh: true,
  /** 默认开启剪贴板贴吧链接识别（可在设置关闭；关闭后不读剪贴板） */
  clipboardLinkDetection: true,
  /** 默认开启双击顶栏回顶（可在设置关闭） */
  navBarDoubleTapToTop: true,
  hapticFeedback: true,
  /** 每场景震动风格覆盖：'{}' = 全部用 hapticsMap 内置规范（设置-震动设置可改） */
  hapticsSceneStyles: '{}',
  /** 实时触觉（手势跟随型）每效果档位：缺省 medium；'{}' = 全部适中开 */
  hapticsRealtimeStyles: '{}',
  /** 每场景波形覆盖：'{}' = 全部用 hapticsMap 内置波形（设置-震动设置可改） */
  hapticsWaveforms: '{}',
  /** 大图清晰度：默认 high（bigPic ~960px，省 60-80%）；origin=原图；lite=更省 */
  dataSaverMode: 'high',
  /** 默认不自动清理缓存（设置可选 1/3/7/15/30 天） */
  cacheAutoCleanDays: 0,
  /** 图片缓存磁盘上限默认 400MB（设置可选 100/200/400/1000） */
  cacheMaxSizeMb: 400,
  /** 帖内视频默认不自动播放（点按播放；设置-图片与流量可开） */
  videoAutoplay: false,
  /** 默认开启入场级联动画（设置-个性化-动效可关） */
  entranceAnimation: true,
  /** 默认开启按压缩放效果（设置-个性化-动效可关） */
  pressScaleEffect: true,
  /** 默认过滤广告与直播贴（ala_info 判据，Kotlin 铁律；关闭=原样展示） */
  filterAdThreads: true,
  /** 默认显示 IP 属地 */
  showIpLocation: true,
  /** 默认显示作者等级徽标 */
  showLevelBadge: true,
  /** 默认相对时间（刚刚/x分钟前）；可切绝对时间 */
  timestampStyle: 'relative',
  /** 消息检查频率默认 30 分钟（Kotlin NotifyJobService 同款；低电量自动加倍） */
  notificationPollMinutes: 30,
  /** 底栏默认滚动收纳（iOS 26+ 药丸收纳；关闭=常驻） */
  tabBarMinimizeEnabled: true,
  /** 启动默认页：关注 */
  startTab: 'index',
};
