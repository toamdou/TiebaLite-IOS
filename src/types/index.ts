// ============================================================
// TiebaLite React Native - Core Type Definitions
// Migrated from com.huanchengfly.tieba.post
// ============================================================

// ---------- API Enums ----------
export enum ForumSortType {
  REPLY_TIME = 'REPLY_TIME',
  SEND_TIME = 'SEND_TIME',
}

export enum SearchThreadOrder {
  NEW_FIRST = 5,
  OLD_FIRST = 0,
  RELEVANT = 2,
}

export enum SearchThreadFilter {
  ALL = 1,
  ONLY_THREAD = 2,
}

export enum LoadType {
  REFRESH = 1,
  LOAD_MORE = 2,
}

// ---------- Account ----------
export interface Account {
  id: number;
  uid: string;
  name: string;
  nameShow: string;
  portrait: string;
  bduss: string;
  sToken: string;
  tbs: string;
  cookie: string;
  /** 保留：AuthService.login（AuthService.ts:122）写入、当前无读取方；
   *  删除需同步移除该行（越界文件，留待其所属批次）。 */
  uuid: string;
  zid: string;
  /** Cached profile fields used by cold-start UI before the profile API returns. */
  levelId?: number;
  levelName?: string;
  intro?: string;
  fansNum?: number;
  concernNum?: number;
  postNum?: number;
}

// ---------- User ----------
export interface UserInfo {
  id: string;
  name: string;
  nameShow: string;
  portrait: string;
  levelId: number;
  levelName: string;
  sex: number; // 1=male, 2=female
  intro: string;
  fansNum: number;
  concernNum: number;
  postNum: number;
  totalAgreeNum?: number;
  ipLocation: string;
  tbAge: number;
  isBawu: boolean;
  /** Baidu tieba UID (numeric) */
  tiebaUid?: string;
  /** Whether current user has followed/concerned this user (0=no, 1=yes) */
  hasConcerned?: number;
  /** 吧主 verification badge */
  bazhuGrade?: { desc: string };
  /** 大神 verification badge */
  newGodData?: { status: number; fieldName?: string };
}

export interface UserProfile {
  user: UserInfo;
  statue: {
    postsNum: number;
    concernForumsNum: number;
  };
}

// ---------- Forum ----------
export interface ForumInfo {
  forumId: string;
  forumName: string;
  /** Alias for forumName used in some contexts */
  name?: string;
  avatar: string;
  slogan: string;
  memberCount: number;
  threadCount: number;
  levelName: string;
  levelId: number;
  isLike: boolean;
  isSign: boolean;
  /** 保留：mapForumInfo（endpoints/helpers.ts:111）写入、当前无读取方；
   *  删除需同步改其返回字面量（越界文件）。 */
  signCount?: number;
}

export interface ForumDetail {
  forumId: string;
  forumName: string;
  avatar: string;
  memberCount: number;
  threadCount: number;
  intro: string;
  isLike: boolean;
  /** Forum experience level (user's level in this forum) */
  levelId?: number;
  levelName?: string;
  /** Current experience score (for level progress bar) */
  curScore?: number;
  /** Experience needed for next level */
  levelupScore?: number;
  /** Sign-in info */
  signInInfo?: {
    isSignIn: boolean;
    contSignNum: number;
    userSignRank: number;
    signBonusPoint: number;
  };
  /** Anti-tbs token for sign/like operations */
  tbs?: string;
}

// ---------- Thread / Post ----------
export interface ThreadInfo {
  id: string;
  /** 帖 id（ThreadInfo.proto 字段 2，mapProtoThread 输出；缺省时与 id 相同） */
  threadId?: string;
  /** 首楼 post id（ThreadInfo.proto 字段 40）——帖级点赞 opAgree post_id 用 */
  firstPostId?: string;
  title: string;
  forumId: string;
  forumName: string;
  authorId: string;
  authorName: string;
  authorNameShow: string;
  authorPortrait: string;
  authorLevelId: number;
  replyNum: number;
  viewNum: number;
  lastTime: number;
  createTime: number;
  isTop: boolean;
  isGood: boolean;
  isVideo: boolean;
  mediaList: MediaInfo[];
  abstract: string;
  firstPostContent: PostContent[];
  zanNum?: number;
  shareNum?: number;
  /** Whether current user has agreed */
  hasAgree?: boolean;
  /** Forum avatar for chip display */
  forumAvatar?: string;
  /** Whether this thread is a shared/forwarded thread */
  isShareThread?: boolean;
  /** Original thread info for shared threads */
  originThreadInfo?: {
    title?: string;
    content?: string;
    forumName?: string;
    media?: MediaInfo[];
  };
}

export interface PostInfo {
  id: string;
  threadId: string;
  forumId: string;
  forumName: string;
  floor: number;
  authorId: string;
  authorName: string;
  authorNameShow: string;
  authorPortrait: string;
  authorLevelId: number;
  authorIsLz: boolean;
  content: PostContent[];
  createTime: number;
  subPostNum: number;
  subPosts?: SubPostInfo[];
  agreeNum: number;
  disagreeNum: number;
  isAgree: boolean;
  isDisagree: boolean;
  ipLocation: string;
}

export interface SubPostInfo {
  id: string;
  postId: string;
  authorId: string;
  authorName: string;
  authorNameShow: string;
  authorPortrait: string;
  authorLevelId?: number;
  content: PostContent[];
  createTime: number;
  replyToUserName?: string;
  ipLocation?: string;
  agreeNum?: number;
  isAgree?: boolean;
}

export type PostContent =
  | { type: 'text'; text: string }
  | { type: 'emoji'; text: string }
  | { type: 'emoticon'; text: string; src: string }
  | { type: 'image'; src: string; width: number; height: number; originSrc?: string }
  | { type: 'video'; src: string; poster: string; width: number; height: number }
  | { type: 'audio'; src: string; duration: number }
  | { type: 'link'; text: string; url: string }
  | { type: 'at'; text: string; uid: string }
  | { type: 'topic'; text: string; topicId: string }
  | { type: 'linebreak' }
  | { type: 'poll'; options: PollOption[]; totalVoteNum: number; hasVoted: boolean; votedOptionIndex?: number };

/** A single poll/vote option */
export interface PollOption {
  text: string;
  voteNum: number;
  index: number;
}

// ---------- Media ----------
export interface MediaInfo {
  type: 'image' | 'video';
  src: string;
  originSrc?: string;
  /** 更小一档的服务端派生图（srcPic，比 src/bigPic 更省流量；可能缺失） */
  smallSrc?: string;
  width: number;
  height: number;
  poster?: string;
  duration?: number;
  /** 服务端长图标记（Media.is_long_pic，proto 字段 19；0/未设置=false） */
  isLongPic?: boolean;
  /** 服务端「显示查看原图按钮」标记（Media.show_original_btn，proto 字段 20；GIF 为 0） */
  showOriginalBtn?: boolean;
}

// ---------- Feed / Personalized ----------
// FeedItem.type 已去掉 'user'（grep 确认无生产/消费方，见全量审查 #14）
export interface FeedItem {
  type: 'thread' | 'forum' | 'topic' | 'video_thread';
  threadInfo?: ThreadInfo;
  forumInfo?: ForumInfo;
  topicInfo?: TopicInfo;
}

// ---------- Topic ----------
export interface TopicInfo {
  topicId: string;
  topicName: string;
  topicDesc: string;
  discussNum: number;
  isHot: boolean;
  isNew: boolean;
}

// ---------- Hot Thread (Kotlin protobuf aligned) ----------

/** Mirrors Kotlin RecommendTopicList proto */
export interface HotTopic {
  topicId: string;
  topicName: string;
  type: number;
  discussNum: number;
  /** 1 = new, 2 = hot */
  tag: number;
  topicDesc: string;
  topicPic: string;
}

/** Mirrors Kotlin FrsTabInfo proto — tab for filtering hot threads */
export interface HotTabInfo {
  tabId: number;
  tabType: number;
  tabName: string;
  tabCode: string;
  tabUrl: string;
  tabTitle: string;
  isGeneralTab: number;
}

/** Mirrors Kotlin ThreadInfo proto (hot thread subset) */
export interface HotThreadInfo {
  /** Thread id (different from threadId in some contexts) */
  id: string;
  /** Actual thread id for navigation */
  threadId: string;
  title: string;
  replyNum: number;
  viewNum: number;
  forumId: string;
  forumName: string;
  authorId: string;
  authorName: string;
  authorNameShow: string;
  authorPortrait: string;
  firstPostId: string;
  createTime: number;
  agreeNum: number;
  /** Hot ranking score (displayed as "XXXX热度") */
  hotNum: number;
  /** Whether current user has agreed */
  hasAgree: number;
  /** Tab this thread belongs to */
  tabId: number;
  tabName: string;
}

/** Full hot page data (mirrors Kotlin HotThreadListResponseData) */
export interface HotPageData {
  topics: HotTopic[];
  tabs: HotTabInfo[];
  threads: HotThreadInfo[];
}

// ---------- Search ----------
export interface SearchForumResult {
  forumId: string;
  forumName: string;
  avatar: string;
  memberCount: number;
  threadCount: number;
  isLike: boolean;
}

export interface SearchMediaInfo {
  type: string;       // "pic" | "video"
  width: number;
  height: number;
  bigPic?: string;
  smallPic?: string;
  waterPic?: string;
  src?: string;
  vsrc?: string;
}

export interface SearchUserInfo {
  userName: string;
  showNickname?: string;
  userId: string;
  portrait?: string;
}

export interface SearchThreadResult {
  id: string;
  title: string;
  forumName: string;
  authorName: string;
  authorNameShow?: string;
  authorPortrait?: string;
  replyNum: number;
  likeNum: number;
  shareNum: number;
  createTime: number;
  content: string;
  /** 本地点赞状态（搜索响应不带；TweetCard 化的搜索卡乐观更新写入） */
  hasAgree?: boolean;
  /** Media attachments (images/videos from search results) */
  media: SearchMediaInfo[];
  /** Forum info (avatar for the forum chip) */
  forumAvatar?: string;
  /** Quoted main post (when search result is a quote) */
  mainPost?: {
    title: string;
    content: string;
    user?: SearchUserInfo;
    likeNum?: string;
    shareNum?: string;
    postNum?: string;
    /** Media attachments in the quoted main post */
    media?: SearchMediaInfo[];
  };
  /** Quoted post info (reply being quoted) */
  postInfo?: {
    tid?: number;
    pid?: number;
    title: string;
    content: string;
    user?: SearchUserInfo;
  };
}

export interface SearchUserResult {
  uid: string;
  name: string;
  nameShow: string;
  portrait: string;
  intro: string;
  fansNum: number;
}

export interface SearchPostResult {
  id: string;
  title: string;
  content: string;
  authorName: string;
  authorId: string;
  forumName: string;
  createTime: number;
  replyNum: number;
  /** 楼中楼深链（mo 搜索项带 pid/floor 时） */
  postId?: string;
  floor?: number;
}

// ---------- Messages ----------
export interface MessageItem {
  id: string;
  type: 'reply' | 'at' | 'agree' | 'system';
  fromUserId: string;
  fromUserName: string;
  fromUserPortrait: string;
  threadId: string;
  threadTitle: string;
  postId?: string;
  content: string;
  createTime: number;
  isRead: boolean;
}

export interface NotificationCount {
  reply: number;
  at: number;
  agree: number;
  total: number;
}

// ---------- Sign ----------
export interface SignResult {
  forumId: string;
  forumName: string;
  exp: number;
  signRank: number;
  isSuccess: boolean;
  errorCode?: number;
  errorMsg?: string;
}

// ---------- Favorite ----------
export interface FavoriteThread {
  id: string;
  title: string;
  forumName: string;
  /** 所属吧 id（store_thread 响应 forum_id；缺省 ''） */
  forumId?: string;
  authorName: string;
  /** 作者头像（store_thread 响应 author.user_portrait；缺省回退首字） */
  authorPortrait?: string;
  postId: string;
  floor: number;
  collectTime: number;
  updateTime: number;
  latestReplyNum: number;
  /** 本地收藏时的正文图片快照（服务端 store_list 不带图，见 favoriteImages.ts） */
  images?: string[];
}

// ---------- History ----------
export interface HistoryItem {
  id: string;
  type: 'thread' | 'forum';
  threadId?: string;
  forumName?: string;
  forumId?: string;
  avatar?: string;
  title?: string;
  authorName?: string;
  /** 发帖人头像（帖记录）：visitHistory 存储 portrait id/URL */
  authorPortrait?: string;
  timestamp: number;
}

// ---------- Block ----------
export interface BlockedWord {
  id: string;
  keyword: string;
  isRegex?: boolean;
  category?: 'blacklist' | 'whitelist';
}

export interface BlockedUser {
  id: string;
  uid: string;
  username?: string;
}

// ---------- Theme ----------
export type ThemeName =
  /** 默认 = 初始内置配色（设置图标五彩态，getThemeColors 等价 tieba/dark） */
  | 'default'
  | 'tieba'
  | 'blue'
  | 'black'
  | 'pink'
  | 'red'
  | 'purple'
  | 'dark'
  | 'blue_dark'
  | 'grey_dark'
  | 'amoled_dark'
  /** 毛玻璃：已从可选列表移除（2026-08-28 用户要求），引擎保留兼容旧存值 */
  | 'translucent'
  | 'custom';

export interface ThemeColors {
  theme: ThemeName;
  primary: string;
  accent: string;
  background: string;
  windowBackground: string;
  card: string;
  floorCard: string;
  toolbar: string;
  toolbarSurface: string;
  onToolbarSurface: string;
  navBar: string;
  navBarSurface: string;
  onNavBarSurface: string;
  text: string;
  textSecondary: string;
  textDisabled: string;
  textOnPrimary: string;
  chip: string;
  onChip: string;
  divider: string;
  unselected: string;
  placeholder: string;
  shadow: string;
  indicator: string;
  isNight: boolean;
}

// ---------- App Preferences ----------
export interface AppPreferences {
  fontScale: number;
  autoSign: boolean;
  autoSignTime: string; // HH:mm
  /**
   * 帖内图片加载档位（Kotlin ImageUtil 四档去 WiFi 档）：
   * - smart_origin 智能省流量（默认，缩略图）
   * - all_origin   始终高质量（originSrc）
   * - all_no       始终无图（占位块）
   */
  imageLoadType: 'smart_origin' | 'all_origin' | 'all_no';
  incognitoMode: boolean;
  defaultSortType: string;
  forumFabFunction: string;
  /** Light-mode theme name used by ThemeContext. */
  lightTheme: ThemeName;
  /** Dark-mode theme name used by ThemeContext. */
  darkTheme: ThemeName;
  /** Manual dark-mode override (used when followSystemDarkMode is false). */
  darkMode: boolean;
  /** Follow the iOS system appearance. */
  followSystemDarkMode: boolean;
  toolbarPrimaryColor: boolean;
  statusBarFontDark: boolean;
  showBothUsername: boolean;
  collectSeeLz: boolean;
  collectDescSort: boolean;
  showShortcutInThread: boolean;
  blockVideo: boolean;
  hideMedia: boolean;
  hideBlockedContent: boolean;
  imageWatermarkEnabled: boolean;
  imageWatermark: 'none' | 'username' | 'forum_name';
  imageDarkenWhenNight: boolean;
  useBuiltInBrowser: boolean;
  customPrimaryColor: string;
  slowSignMode: boolean;
  failAutoStop: boolean;
  useOfficialSign: boolean;
  /** Whether one-click sign progress is shown as an iOS Live Activity. */
  liveActivitySignEnabled: boolean;
  /** 签到进度显示位置：灵动岛 Live Activity / 通知栏横幅（二选一）。 */
  signDisplayMode: 'liveActivity' | 'notification';
  /** 签到静默显示：完成通知不发声、不振动（横幅照常显示）。 */
  signSilent: boolean;
  /** 关注吧列表排序：按等级 / 按名称（首页右上角图标切换）。 */
  forumSortMode: 'level' | 'name';
  homePageShowHistoryForum: boolean;
  /** 关注吧列表布局：true = 一行一个；false = 一行两个 */
  forumListSingle: boolean;
  exploreAutoRefresh: boolean;
  /** 剪贴板贴吧链接识别：关闭后不读剪贴板、不再弹"检测到帖子链接" */
  clipboardLinkDetection: boolean;
  /** 双击顶栏（标题/空白区）回顶：搜索/吧页/帖内/楼中楼四页生效 */
  navBarDoubleTapToTop: boolean;
  hapticFeedback: boolean;
  /**
   * 每场景震动风格覆盖（JSON 字符串，形如 {"like":"medium","toggle":"off"}）。
   * 键=HapticsScene；值：impact 场景 'off'|'light'|'medium'|'heavy'|'rigid'|'soft'，
   * selection/notification 场景仅 'default'|'off'。缺省/'default'=用内置映射表。
   * 存 JSON 字符串而非结构化对象：preferencesStore 的 sanitize 按字符串直收，
   * 解析与键值白名单校验在 hapticsMap 消费侧做（坏值静默回落默认）。
   */
  hapticsSceneStyles: string;
  /**
   * 实时连续触觉（手势跟随型）每效果档位：'off'|'light'|'medium'|'strong'。
   * 键=RealtimeEffectId（imageLiftPop/likeCharge），
   * 缺省=medium。存 JSON 字符串，解析与坏值回落同 hapticsSceneStyles 策略
   * （消费侧 theme/hapticsRealtime.ts）。
   */
  hapticsRealtimeStyles: string;
  /**
   * 每场景波形覆盖（JSON 字符串，形如 {"like":"single","toggle":"soft"}）。
   * 键=HapticsScene；值=WAVEFORM_PRESETS 的键（'default'=跟随场景内置波形）。
   * 与 hapticsSceneStyles（力度浓淡）正交：先选波形再按力度缩放强度。
   * 存 JSON 字符串，解析与坏值回落同 hapticsSceneStyles 策略（hapticsMap 消费侧）。
   */
  hapticsWaveforms: string;
  /**
   * 大图清晰度（查看器加载哪一档图）：
   * - origin = 原图（originPic，数 MB，画质最佳）
   * - high   = 高清（bigPic ~960px，手机屏幕观感几乎无差，省 60-80%）
   * - lite   = 省流（srcPic 小档，不存在时回落 bigPic，最省流量）
   */
  dataSaverMode: 'origin' | 'high' | 'lite';
  /** 缓存定期自动清理：0 = 关闭；否则每 N 天启动时自动清一次图片缓存 */
  cacheAutoCleanDays: number;
  /** 图片缓存磁盘上限（MB）：100 / 200 / 400 / 1000 */
  cacheMaxSizeMb: number;
  /** 帖内视频自动播放：可视区自动开播、滚出即收起；关闭=点按播放（默认） */
  videoAutoplay: boolean;
  /** 信息流/帖内入场级联动画：关闭后列表直接静态显示 */
  entranceAnimation: boolean;
  /** 按压缩放效果（列表行/卡片按压弹簧缩放） */
  pressScaleEffect: boolean;
  /** 过滤广告与直播贴（ala_info 判据，Kotlin 同款铁律；关闭=原样展示） */
  filterAdThreads: boolean;
  /** 显示 IP 属地（楼层/楼中楼/主楼/个人主页） */
  showIpLocation: boolean;
  /** 显示作者等级徽标（楼层/楼中楼） */
  showLevelBadge: boolean;
  /** 时间显示格式：relative 相对时间（默认）；absolute 绝对时间 */
  timestampStyle: 'relative' | 'absolute';
  /** 消息通知检查频率（分钟）：30 / 60 / 120，低电量模式自动加倍 */
  notificationPollMinutes: number;
  /** 底栏滚动收纳（iOS 26+ 药丸收纳）：关闭=常驻 */
  tabBarMinimizeEnabled: boolean;
  /** 启动默认页 */
  startTab: 'index' | 'explore' | 'notifications' | 'profile';
}
