/**
 * 贴吧图床缩略图工具
 *
 * Tieba CDN（imgsrc / tiebapic.baidu.com）支持服务端按宽度缩放：
 *   - 原图：  https://imgsrc.baidu.com/forum/pic/item/<hash>.jpg
 *   - 缩略：  https://imgsrc.baidu.com/forum/w%3D360%3Bq%3D90/pic/item/<hash>.jpg
 *   - 旧格式： https://imgsrc.baidu.com/forum/<hash>.jpg
 *            → https://imgsrc.baidu.com/forum/w%3D360%3Bq%3D90/<hash>.jpg
 *
 * 非贴吧图床 / 无 /forum/ 路径（如头像 http://tb.himg.baidu.com/sys/portrait/）的
 * URL 原样返回，不做任何改写。
 */

/** 信息流列表图宽度（全屏查看器相邻页） */
export const THUMB_LIST = 360;
/** 帖子正文图宽度（线程详情页 ImageSegment，兼顾清晰度与内存） */
export const THUMB_POST = 600;
/** 信息流卡片媒体图宽度 */
export const THUMB_CARD = 200;

/**
 * 贴吧图片 URL 统一入口。
 *
 * ⚠️ 2026-08 实测：贴吧 CDN（tiebapic / imgsrc）已停止支持客户端注入的 w= 尺寸段
 * ——任何 `.../forum/w%3D<宽>%3Bq%3D90/...` 注入都会返回默认「贴」占位图（约 4KB），
 * 只有服务端带 sign 的尺寸 URL（ThreadInfo.media 的 bigPic / srcPic）与裸
 * `/forum/pic/item/<hash>.jpg` 原图才真实可显示。因此这里不再改写路径：列表/卡片
 * 用的缩略图由 mapMediaList 直接取服务端算好的尺寸图（bigPic → srcPic 优先）。
 * 本函数保留的意义：统一做 ATS 协议升级（http / 协议相对 → https）与本地 URI 透传。
 *
 * @param width 仅作幂等校验（要求 > 0 才执行协议升级）——CDN 尺寸注入已停用，
 *   宽度不再参与 URL 改写；参数保留只为校验守卫，调用点无需语义性传值。
 */
export function thumbnailUrl(url: string, width: number): string {
  if (!url || typeof url !== 'string') return url;
  if (!(width > 0)) return url;

  // ATS 禁止明文 HTTP：统一升级协议（本地 URI 原样返回）。
  // 前缀互斥：http:// 与 // 开头的 URL 不可能同时以 file:// / ph:// / data: 开头，
  // 本地 URI 守卫冗余已移除——它们走下方 else 直通原样返回。
  return url.startsWith('http://') || url.startsWith('//')
    ? url.replace(/^http:\/\//i, 'https://').replace(/^\/\//, 'https://')
    : url;
}

/**
 * 查看器大图清晰度档位（设置项 dataSaverMode）：
 * - origin：原图（originSrc，可数 MB，画质最佳）
 * - high：高清（src = 服务端 bigPic ~960px，手机屏幕观感几乎无差）
 * - lite：省流（smallSrc = srcPic 小档，缺失时回落 bigPic）
 * 贴吧 CDN 只提供服务端算好的这若干档；viewer 仅做"选哪一档"。
 */
export type ViewerImageMode = 'origin' | 'high' | 'lite';

export function pickViewerImages(
  images: { src?: string; originSrc?: string; smallSrc?: string }[],
  mode: ViewerImageMode,
): string[] {
  return images.map((i) => {
    // GIF 强制原档：动图原链（.gif）才能播放动画；bigPic 派生可能是静态
    // jpg，走 high/lite 档会让大图"动图变静图"（用户 2026-08-30 反馈）
    const gifUri = i.originSrc || i.src || '';
    if (/\.gif(?:\?|#|$)/i.test(gifUri)) return gifUri;
    if (mode === 'origin') return i.originSrc || i.src || '';
    if (mode === 'lite') return i.smallSrc || i.src || i.originSrc || '';
    // high：大图（bigPic）
    return i.src || i.originSrc || '';
  });
}
