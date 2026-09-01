import { apiPost } from '../client';
import type { AxiosResponse } from '../client';
import { TiebaApiError, assertSuccessPayload } from '../interceptors';
// round-54：getTbs/getStoken 收敛为 authState 单一出处（删除本文件的
// AuthSQLiteStorage 直读实现，保留 || '' 兜底语义）。
import { getTbs as getTbsState, getStoken as getStokenState } from '../authState';
import { thumbnailUrl, THUMB_LIST } from '@/utils/thumbnail';
import { EMOTICON_NAME_MAP, buildEmoticonSrc } from '@/constants/emoticons';
import type { ForumInfo, MediaInfo, PostInfo, SubPostInfo } from '@/types';

/** 获取真实 tbs（反 token）；只读接口可容忍空值。—— 委托 authState.getTbs */
export function getTbs(): string {
  return getTbsState() || '';
}

/**
 * 时间戳契约（跨代理）：proto/JSON 秒级时间戳统一转毫秒输出。
 * - 已是毫秒（>= 1e11，13 位）保持不变
 * - 秒级（10 位）×1000
 * UI 层按"helpers 输出已是毫秒"消费。
 */
export function toMillis(v: number): number {
  if (!v || !isFinite(v)) return 0;
  return v >= 100000000000 ? v : v * 1000;
}

/** 写接口强制要求真实 tbs，不再返回假值 '1'。 */
export async function requireTbs(): Promise<string> {
  const tbs = getTbsState();
  if (tbs) return tbs;
  // P0 续期：tbs 缺失/过期时自动向 /c/s/login 重新获取一次（对齐 aiotieba __init_tbs）
  try {
    const { fetchTbs } = await import('./auth');
    const refreshed = await fetchTbs();
    if (refreshed) return refreshed;
  } catch (e) {
    if (__DEV__) console.warn('[requireTbs] refresh failed:', e);
  }
  throw new TiebaApiError('缺少 tbs，无法执行此操作，请刷新页面后重试', 400, 400);
}

/** 获取 stoken —— 委托 authState.getStoken */
export function getStoken(): string {
  return getStokenState() || '';
}

// ============================================================
// Helpers
// ============================================================

export interface TiebaRes<T> { code: number; data: T; message?: string; error_code?: string; error_msg?: string; }
export interface ClientDataRes<T> { data: T; }

export function extractData<T>(response: AxiosResponse<T>): T { return response.data; }

/**
 * Throw a TiebaApiError when a protobuf response carries a non-zero error.
 */
export function assertProtoSuccess(decoded: {
  error?: { error_code?: number; error_msg?: string };
}): void {
  assertSuccessPayload(decoded, false);
}

/**
 * POST a form action and throw on non-zero API code. Returns the full
 * response body for callers that need nested payloads.
 */
export async function postFormAction<T = any>(
  url: string,
  body: Record<string, string | number | boolean | undefined>,
  signal?: AbortSignal,
): Promise<T> {
  const response = extractData(await apiPost<T>(url, body, undefined, signal));
  assertSuccessPayload(response, false);
  return response;
}
/**
 * Build a uid → user lookup map. `keyOf` picks the uid field(s): mapProtoThread
 * accepts several aliases while mapProtoPosts aligns with Kotlin
 * PbPageRepository (user.id only).
 */
function buildUserMap(userList: any[], keyOf: (u: any) => string): Map<string, any> {
  const map = new Map<string, any>();
  for (const u of userList) {
    const uid = String(keyOf(u) ?? '');
    if (uid) map.set(uid, u);
  }
  return map;
}

/**
 * 映射吧列表单条（snake_case / camelCase 兼容）为 ForumInfo（camelCase 输出）。
 * 超集实现，供 user.ts userLikeForum（/c/f/forum/like forum_list）与
 * forumFollowed.ts allForumGuideFlow（like_forum）共用；兼容服务端两种下发形态。
 * 注意：forumId 兜底含 fid（/c/f/forum/like 新形态无 forum_id 时缺失）。
 */
export function mapForumInfo(item: any): ForumInfo {
  return {
    forumId: String(item.forum_id ?? item.forumId ?? item.fid ?? ''),
    forumName: item.forum_name ?? item.forumName ?? '',
    name: item.forum_name ?? item.forumName ?? '',
    avatar: item.avatar ?? '',
    slogan: item.slogan ?? '',
    memberCount: Number(item.member_count ?? item.memberCount ?? 0),
    threadCount: Number(item.thread_count ?? item.threadCount ?? 0),
    levelName: item.level_name ?? item.levelName ?? '',
    levelId: Number(item.level_id ?? item.levelId ?? 0),
    isLike: item.is_like === '1' || item.is_like === 1 || item.isLike === true,
    isSign: item.is_sign === '1' || item.is_sign === 1 || item.isSign === true,
    signCount: item.sign_count != null || item.signCount != null
      ? Number(item.sign_count ?? item.signCount)
      : undefined,
  };
}

/**
 * 图床 http/协议相对 → https（ATS 明文拦截）—— 单实现（round-54：删除本文件
 * TIEBA_IMG_RE 窄化双实现，统一委托 utils/thumbnail.ts 的 thumbnailUrl）。
 * 行为差异：thumbnailUrl 对所有 http:// 与 // 开头 URL 升级 https（iOS ATS 本就
 * 拦截所有明文，非图床域名的 http 图此前恒裂，升级只会更好），file:/ph:/data:
 * 本地 URI 原样透传。thumbnailUrl 的 width 形参已随 CDN 尺寸注入停用而失效
 * （仅要求 >0），此处传列表档常量仅为满足守卫。
 */
export function toHttpsImgUrl(src: string): string {
  return thumbnailUrl(src, THUMB_LIST);
}

export function mapMediaList(raw: any): MediaInfo[] {
  const list = [raw?.media, raw?.media_list].find(Array.isArray) ?? (Array.isArray(raw) ? raw : []);
  const result: MediaInfo[] = [];
  for (const m of list) {
    if (!m || typeof m !== 'object') continue;
    const mediaType = String(m.type ?? '');
    // ⚠️ 只有显式视频类型/字段才算视频。贴吧 media 的数字 type（1/2/3…）
    // 是图片类型（普通图/动图/长图），不能当视频——之前误判导致所有
    // 帖子左上角都出现播放标识、封面图被当成视频走播放器。
    const isVideo =
      mediaType === 'video' ||
      !!(m.vsrc ?? m.video_src ?? m.videoSrc ?? m.video);
    // ⚠️ 列表/卡片显示用“服务端已算好的中等尺寸图”(bigPic ~960px) 优先：
    // 2026-08 Tieba CDN 已停用客户端注入的 w= 尺寸段（一律返回默认「贴」占位图），
    // 只有服务端带 sign 的尺寸 URL（bigPic/srcPic）与裸 /pic/item/ 原图真实可显示。
    // 故 src 直接取服务端派生图原样显示（thumbnailUrl 不再改写），裸原图兜底。
    const src = toHttpsImgUrl(String(
      m.bigPic ?? m.big_pic ?? m.bigSrc ?? m.big_src ??
      m.srcPic ?? m.src_pic ?? m.src ??
      m.originPic ?? m.origin_pic ?? m.originSrc ?? m.origin_src ?? '',
    ));
    if (!src) continue;
    const smallRaw = String(m.srcPic ?? m.src_pic ?? '');
    // 动图判定：只看 URL 后缀（.gif）——**不能**把 dynamicPic「值非空」当
    // 判定源：服务端对几乎所有图片都下发 dynamicPic（多为动图封面/静态
    // 派生链），2026-09-01 曾实测全图 GIF 徽标 + 查看器全走静态原链。
    // 判定 = dynamicPic / originPic / bigPic / src 任一源带 .gif 后缀。
    const dynamicRaw = String(m.dynamicPic ?? m.dynamic_pic ?? '');
    const originRaw = String(m.originPic ?? m.origin_pic ?? '');
    const bigRaw = String(m.bigPic ?? m.big_pic ?? '');
    const srcRaw = String(m.src ?? '');
    const isGif = /\.gif(?:\?|#|$)/i.test(
      `${dynamicRaw} ${originRaw} ${bigRaw} ${srcRaw}`,
    );
    // 动图链：数据里第一个带 .gif 后缀的 URL（优先级 dynamicPic >
    // originPic > bigPic > src）。列表一直用 src(=bigPic) 能播；大图/帖内
    // 强制原链若固定取 originPic 而服务端把 originPic 做成静态 jpg 派生、
    // 动图链在 bigPic，就会「外面能播、大图不播」（2026-09-01 用户实测）。
    const gifChain = isGif
      ? [dynamicRaw, originRaw, bigRaw, srcRaw].find((u) =>
          /\.gif(?:\?|#|$)/i.test(u),
        ) ?? ''
      : '';
    result.push({
      type: isVideo ? 'video' : 'image',
      src,
      originSrc:
        toHttpsImgUrl(String(
          gifChain ||
          (m.originPic ?? m.origin_pic ?? m.originSrc ?? m.origin_src ?? m.bigPic ?? m.big_pic ?? ''),
        )) || undefined,
      // srcPic 是比 bigPic 更小的一档（若服务端提供且与 src 不同），
      // 供「省流」档使用；与 src 相同/缺失时不重复出现。
      smallSrc:
        smallRaw && smallRaw !== String(m.bigPic ?? m.big_pic ?? '')
          ? toHttpsImgUrl(smallRaw) || undefined
          : undefined,
      poster:
        String(m.poster ?? m.video_poster ?? m.videoPoster ?? '') ||
        (isVideo ? src : undefined),
      width: Number(m.width ?? 0) || 300,
      height: Number(m.height ?? 0) || 300,
      // 服务端长图/查看原图标记（Media.is_long_pic / show_original_btn，proto 字段 19/20；
      // protobufjs 已解码的 camelCase 或 JSON 兜底 snake_case 双读）。
      // Kotlin 同字段（ForumPageBean.MediaInfoBean）：isLongPic 由服务端下发
      // （= 客户端 ForumBeanCaster 以 height > 屏幕精确高度 判定），showOriginalBtn GIF 恒为 0。
      isLongPic: (m.isLongPic ?? m.is_long_pic) === 1,
      showOriginalBtn: (m.showOriginalBtn ?? m.show_original_btn) === 1,
      isGif,
      duration: m.duration != null ? Number(m.duration) : undefined,
    });
  }
  return result;
}

/**
 * 广告/直播卡片判定 —— 与 Kotlin 过滤判据【完全一致】（唯一判据：ala_info 存在）。
 *
 * Kotlin 证据（TiebaLite Android repo，全部过滤点只用 `.filter { it.ala_info == null }`）：
 * - FrsPageRepository.kt:40/63  `.filter { it.ala_info == null } // 去他妈的直播`
 * - GeneralTabListRepository.kt:47 `.filter { it.ala_info == null }`
 * - PersonalizedRepository.kt:17-28（收集 thread_list 中 ala_info != null 的 id，
 *   同时从 thread_list 与 thread_personalized 剔除）
 * - PersonalizedViewModel.kt:79/106  UI 层再 `.filter { it.get { ala_info } == null }`
 *
 * 判据：`ala_info`（ThreadInfo.proto 字段 113，AlaLiveInfo 直播/信息流广告卡片）
 * 在 wire 上存在（非 null/undefined）即广告/直播卡片。protobufjs 对未设置的
 * message 字段返回 undefined；空对象 {} 视为存在（wire 上出现了该字段号），
 * 与 Kotlin protobuf 语义 `ala_info != null` 等价。
 * 对 null/undefined/非对象安全返回 false。
 */
export function isAdThread(raw: any): boolean {
  if (!raw || typeof raw !== 'object') return false;
  const ala = raw.alaInfo ?? raw.ala_info;
  return ala != null;
}

/**
 * 已映射 ThreadInfo 的广告判定：mapProtoThread 产物带 `isAd` 标记（= isAdThread(raw)），
 * 直接命中；未带标记的对象（JSON 兜底路径直接透传的 FeedItem）回退到 isAdThread
 * 按 ala_info 原始键判定——与 Kotlin PersonalizedViewModel 的 UI 层二次过滤
 * `.filter { it.get { ala_info } == null }` 语义一致。对缺失/非对象安全返回 false。
 */
export function isAdThreadInfo(t: any): boolean {
  if (!t || typeof t !== 'object') return false;
  if (t.isAd === true) return true;
  return isAdThread(t);
}

/** Map raw protobuf/JSON thread objects to UI ThreadInfo. */
export function mapProtoThread(
  raw: any,
  opts?: { forum?: any; userList?: any[]; forumName?: string },
): any {
  if (!raw) return {};
  const userList = opts?.userList ?? [];
  const userMap = buildUserMap(userList, (u) => u.id ?? u.uid ?? u.user_id ?? '');
  const authorId = String(raw.authorId ?? raw.author_id ?? raw.author?.id ?? '');
  // ⚠️ raw.author 可能是"存在但为空对象 {}"（proto3 解码产物），`??` 不会
  // 回退到 userMap → 作者名/头像全空。必须判空：author 有键才用内嵌，
  // 否则从 userList 按 authorId 匹配（对齐 Kotlin userList.first { id == authorId }）。
  const rawAuthor = raw.author && typeof raw.author === 'object' && Object.keys(raw.author).length > 0
    ? raw.author
    : undefined;
  const author = rawAuthor ?? userMap.get(authorId) ?? {};
  const forum = opts?.forum ?? {};
  // 论坛对象在 ThreadInfo 里是 SimpleForum forumInfo=155（avatar=4）——
  // 解码产物字段名 forumInfo；早期实现只读 raw.forum，吧头像从未落到卡片。
  const forumInfo = raw.forumInfo ?? raw.forum_info;
  const forumName = opts?.forumName ?? raw.forumName ?? raw.forum_name ?? forumInfo?.name ?? forum?.name ?? '';
  const abstractRaw = raw._abstract ?? raw.abstract;
  const abstract = Array.isArray(abstractRaw)
    ? abstractRaw
        .map((a: any) => (typeof a === 'string' ? a : (a?.text ?? a?.txt ?? a?.content ?? '')))
        .join('')
    : String(abstractRaw ?? '');
  const originRaw = raw.originThreadInfo ?? raw.origin_thread_info;
  const mediaList = mapMediaList(raw);
  return {
    id: String(raw.id ?? raw.threadId ?? raw.thread_id ?? ''),
    // 广告/直播标记（对齐 Kotlin 响应侧 ala_info 过滤）：各信息流入口
    // （吧内三 tab / 自定义 tab / 动态流 / 话题页）据此在数据层剔除。
    isAd: isAdThread(raw),
    threadId: String(raw.threadId ?? raw.thread_id ?? raw.id ?? ''),
    // 首楼 post id（ThreadInfo.proto 字段 40）——帖级点赞 opAgree 的 post_id
    // 必须用它（Kotlin 全链路铁律：PersonalizedPage/ConcernPage/HotPage/
    // ForumThreadListPage 均 Agree(threadId, firstPostId,…)，RN 使用点见
    // useFeedCardActions.like）。此前未映射 → 列表卡片点赞一直拿 threadId
    // 当 post_id，与服务端预期不符（其 post_id 锚定首楼）。
    firstPostId: String(raw.firstPostId ?? raw.first_post_id ?? ''),
    title: raw.title ?? '',
    forumId: String(raw.forumId ?? raw.forum_id ?? raw.fid ?? forumInfo?.id ?? forum?.id ?? ''),
    forumName: forumName || raw.fname || '',
    forumAvatar: forumInfo?.avatar ?? forum?.avatar ?? raw.forumAvatar ?? raw.forum_avatar ?? '',
    authorId,
    authorName: author.name ?? author.userName ?? author.user_name ?? '',
    authorNameShow:
      author.nameShow ?? author.name_show ?? author.showNickname ?? author.show_nickname ?? author.name ?? '',
    authorPortrait: author.portrait ?? '',
    authorLevelId: Number(author.levelId ?? author.level_id ?? 0),
    replyNum: Number(raw.replyNum ?? raw.reply_num ?? 0),
    viewNum: Number(raw.viewNum ?? raw.view_num ?? 0),
    lastTime: toMillis(Number(raw.lastTimeInt ?? raw.last_time_int ?? raw.lastTime ?? raw.last_time ?? 0)),
    createTime: toMillis(Number(raw.createTime ?? raw.create_time ?? 0)),
    isTop: (raw.isTop ?? raw.is_top ?? 0) === 1,
    isGood: (raw.isGood ?? raw.is_good ?? 0) === 1,
    isVideo:
      (raw.isVideo ?? raw.is_video ?? 0) === 1 ||
      !!raw.videoInfo ||
      !!raw.video_info ||
      mediaList.some((m) => m.type === 'video'),
    mediaList,
    abstract,
    // 字段裁剪（P1）：firstPostContent 无任何 UI 读取（grep src/app、src/components 确认），
    // 且为整篇首楼全文，占用大，从输出白名单中移除。
    zanNum: Number(raw.agreeNum ?? raw.agree_num ?? raw.agree?.agreeNum ?? raw.agree?.agree_num ?? 0),
    shareNum: Number(raw.shareNum ?? raw.share_num ?? 0),
    hasAgree: (raw.agree?.hasAgree ?? raw.agree?.has_agree ?? raw.hasAgree ?? raw.has_agree ?? 0) === 1,
    isShareThread: (raw.isShareThread ?? raw.is_share_thread ?? 0) === 1,
    originThreadInfo: originRaw
      ? {
          title: originRaw.title ?? '',
          content: originRaw.content ?? '',
          forumName: originRaw.fname ?? originRaw.forumName ?? '',
          media: mapMediaList(originRaw),
        }
      : undefined,
  };
}

/** Map protobuf Post objects to PostInfo format expected by UI */
export function mapProtoPosts(rawPosts: any[], threadId: string, userList: any[] = []): PostInfo[] {
  // Build user lookup map (mirrors Kotlin PbPageRepository: userList.first { user.id == post.author_id })
  const userMap = buildUserMap(userList, (u) => u.id ?? '');

  return rawPosts.map((p: any) => {
    // Lookup author: embedded in post, or from userList by authorId
    // ⚠️ p.author 可能是空对象 {}（proto3 解码产物），`??` 不会回退到
    // userMap → 回复者头像/名称全空。必须判空（与 mapProtoThread 同因）。
    const authorId = String(p.authorId ?? p.author?.id ?? '');
    const rawAuthor = p.author && typeof p.author === 'object' && Object.keys(p.author).length > 0
      ? p.author
      : undefined;
    const author = rawAuthor ?? userMap.get(authorId) ?? {};
    const rawSubPosts = p.subPostList?.subPostList ?? p.subPostList?.sub_post_list ?? [];
    // 字段裁剪（性能 P1）：UI 预览最多展示前 3 条楼中楼（PostCard slice(0,3)），
    // 完整楼中楼走 pbFloor 单独加载，故这里只映射前 3 条，避免整篇 subPosts 全文驻留内存。
    const cappedSubPosts = Array.isArray(rawSubPosts) ? rawSubPosts.slice(0, 3) : [];
    const mappedSubPosts: SubPostInfo[] = cappedSubPosts.map((sp: any) => {
      const spAuthorId = String(sp.authorId ?? sp.author_id ?? sp.author?.id ?? '');
      const spRawAuthor = sp.author && typeof sp.author === 'object' && Object.keys(sp.author).length > 0
        ? sp.author
        : undefined;
      const spAuthor = spRawAuthor ?? userMap.get(spAuthorId) ?? {};
      return {
        id: String(sp.id ?? ''),
        postId: String(p.id ?? ''),
        authorId: String(sp.authorId ?? sp.author_id ?? spAuthor.id ?? ''),
        authorName: spAuthor.name ?? '',
        authorNameShow: spAuthor.nameShow ?? spAuthor.name ?? '',
        authorPortrait: spAuthor.portrait ?? '',
        authorLevelId: Number(spAuthor.levelId ?? 0) || undefined,
        content: mapProtoContent(sp.content ?? []),
        createTime: toMillis(Number(sp.time ?? 0)),
        // ⚠️ 仅 JSON 兜底生效：proto SubPost 无 reply_to_user_name 字段
        //（protos_src/SubPost.proto 无此字段），proto 路径恒 ''。
        replyToUserName: sp.replyToUserName ?? sp.reply_to_user_name ?? '',
        ipLocation: sp.location?.addr ?? sp.ipAddress ?? spAuthor.ipAddress ?? '',
        agreeNum: Number(sp.agree?.agreeNum ?? sp.agreeNum ?? 0),
        isAgree: (sp.agree?.hasAgree ?? 0) === 1,
      };
    });
    return {
      id: String(p.id ?? ''),
      threadId: String(p.tid ?? threadId),
      forumId: '',
      forumName: '',
      floor: Number(p.floor ?? 0),
      authorId: String(p.authorId ?? author.id ?? ''),
      authorName: author.name ?? '',
      authorNameShow: author.nameShow ?? author.name ?? '',
      authorPortrait: author.portrait ?? '',
      authorLevelId: Number(author.levelId ?? 0),
      // ⚠️ 仅 JSON 兜底生效：proto Post 无 is_lz 字段（protos_src/Post.proto
      // 无 is_lz），proto 路径恒 false —— 楼主判定由 UI 侧按 floor==1 处理。
      authorIsLz: (p.isLz ?? 0) === 1,
      content: mapProtoContent(p.content ?? []),
      createTime: toMillis(Number(p.time ?? 0)),
      subPostNum: Number(p.subPostNumber ?? 0),
      subPosts: mappedSubPosts,
      agreeNum: Number(p.agreeNum ?? p.agree?.agreeNum ?? 0),
      disagreeNum: Number(p.agree?.disagreeNum ?? 0),
      isAgree: (p.agree?.hasAgree ?? 0) === 1,
      // 踩状态从 proto 映射（proto 无 has_disagree 字段时保持 false，服务端下发则取真实值）
      isDisagree: (p.agree?.hasDisagree ?? p.agree?.has_disagree ?? p.isDisagree ?? p.is_disagree ?? 0) === 1,
      // 主楼/楼层 IP 属地：Post 无 ip 字段，属地挂在 author 上（User.ip_address=127，
      // SwiftProtobuf ToJsonName→ipAddress）；JSON 兜底 location.addr（楼中楼同款）。
      ipLocation: p.location?.addr ?? p.ipAddress ?? author.ipAddress ?? p.author?.ip ?? p.ip ?? '',
    };
  });
}

/** Map protobuf PbContent array to PostContent format (对齐 PostContent 渲染器期望的形状) */
export function mapProtoContent(rawContent: any[]): any[] {
  if (!Array.isArray(rawContent)) return [];
  return rawContent.map((c: any) => {
    const type = Number(c.type ?? 0);
    // PbContent types: 0=text, 1=link, 2=emoji, 3=image, 4=at, 5=video, 9=voice, 10=phone, 20=graffiti/image
    switch (type) {
      case 3:
      case 20: {
        // Image — 扁平结构 {src,width,height,originSrc}，渲染器直接读取
        // Kotlin 使用 bsize 字段（格式 "width,height"）解析尺寸
        let w = Number(c.width ?? 0);
        let h = Number(c.height ?? 0);
        if ((!w || !h) && c.bsize) {
          const parts = String(c.bsize).split(',');
          if (parts.length === 2) {
            w = parseInt(parts[0], 10) || 0;
            h = parseInt(parts[1], 10) || 0;
          }
        }
        if (!w) w = 300;
        if (!h) h = 300;
        // URL 优先级对齐 Kotlin: cdnSrc > bigCdnSrc > src
        const imgSrc = c.cdnSrc || c.bigCdnSrc || c.cdnSrcActive || c.src || '';
        const imgOrigin = c.originSrc || c.bigSrc || c.bigCdnSrc || c.src || '';
        // 动图判定（供帖内 GIF 徽标）：动图专用链 PbContent.dynamic（字段 16）
        // + 各 URL 源后缀。**不换渲染链**：帖内默认静态档、点「查看原图」
        // 用 originSrc 原档可播（2026-09-01 用户确认该机制保留）。
        const dynamicChain = String(c.dynamic ?? '');
        const gifChain = [
          dynamicChain,
          c.cdnSrc,
          c.bigCdnSrc,
          c.cdnSrcActive,
          c.originSrc,
          c.bigSrc,
          c.src,
        ].find((u: unknown) => typeof u === 'string' && /\.gif(?:\?|#|$)/i.test(u));
        return {
          type: 'image',
          src: imgSrc,
          originSrc: imgOrigin,
          isGif: !!gifChain,
          width: w,
          height: h,
          // PbContent.is_long_pic(34)/show_original_btn(35)；Kotlin PicContentRender
          // 同字段驱动长图/查看原图入口（Extensions.kt:262-276 showOriginalBtn == 1）
          isLongPic: (c.isLongPic ?? c.is_long_pic) === 1,
          showOriginalBtn: (c.showOriginalBtn ?? c.show_original_btn) === 1,
        };
      }
      case 2: {
        // Emoji/Emoticon — 贴吧经典表情渲染为内联图片
        // Proto field `c` (field 11) = emoticon name (e.g. "滑稽")
        // Proto field `text` (field 2) = emoticon ID (e.g. "image_emoticon25") or formatted "(#name)"
        const emoticonName = c.c ?? '';
        const emojiText = c.text ?? '';

        // Priority 1: Use `c` field as emoticon name (matches Kotlin: EmoticonManager.registerEmoticon(it.text, it.c))
        if (emoticonName) {
          const numByName = EMOTICON_NAME_MAP[emoticonName];
          if (numByName) {
            return {
              type: 'emoticon',
              text: emoticonName,
              src: buildEmoticonSrc(numByName),
            };
          }
        }

        // Priority 2: text field is image_emoticon{N} format
        if (/^image_emoticon\d+$/.test(emojiText)) {
          const num = parseInt(emojiText.replace('image_emoticon', ''), 10);
          return {
            type: 'emoticon',
            text: emojiText,
            src: buildEmoticonSrc(num),
          };
        }

        // Priority 3: text field is (#name) format
        const emoticonMatch = emojiText.match(/^\(#(.+?)\)$/);
        if (emoticonMatch) {
          const name = emoticonMatch[1];
          const num = EMOTICON_NAME_MAP[name];
          if (num) {
            return {
              type: 'emoticon',
              text: name,
              src: buildEmoticonSrc(num),
            };
          }
        }

        // Priority 4: text field is a plain emoticon name
        const numByText = EMOTICON_NAME_MAP[emojiText];
        if (numByText) {
          return {
            type: 'emoticon',
            text: emojiText,
            src: buildEmoticonSrc(numByText),
          };
        }

        // Fallback: render as unicode emoji
        return { type: 'emoji', text: emoticonName || emojiText };
      }
      case 1:
        // Link — 渲染器读取 url 字段
        return { type: 'link', text: c.text ?? c.link ?? '', url: c.link ?? c.text ?? '' };
      case 5: {
        // Video — 渲染器需要 src/poster/width/height
        // Kotlin 实证（PbContentRender.kt VideoContentRender、Extensions.kt case 5）：
        // 视频真实地址读 pb `link` 字段（videoUrl），`src` 是封面图（w=960 缩略图 jpg），
        // 不能当播放源（AVPlayer -11828 Cannot Open）
        const vw = Number(c.width ?? 0) || 280;
        const vh = Number(c.height ?? 0) || 158;
        return {
          type: 'video',
          src: c.link ?? c.src ?? '',
          poster: c.cdnSrc ?? c.src ?? '',
          width: vw,
          height: vh,
        };
      }
      case 9:
        // Voice — 对齐 Kotlin PbContentRender：URL 由 voice_md5 拼装
        //（https://tiebac.baidu.com/c/p/voice?voice_md5=..&play_from=pb_voice_play），
        // 语音段 src 恒空，不能直接用段内 src
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const voiceMd5 = (c as any).voiceMD5 ?? (c as any).voice_md5 ?? '';
        return {
          type: 'audio',
          src: voiceMd5
            ? `https://tiebac.baidu.com/c/p/voice?voice_md5=${voiceMd5}&play_from=pb_voice_play`
            : (c.src ?? ''),
          duration: Number(c.duringTime ?? 0),
        };
      case 4:
        // At user
        return { type: 'at', text: c.text ?? '', uid: String(c.uid ?? '') };
      default:
        // Text (type 0 or unknown)
        return { type: 'text', text: c.text ?? '' };
    }
  });
}


