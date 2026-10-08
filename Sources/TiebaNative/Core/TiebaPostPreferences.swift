//  帖子页展示偏好（大图档/无图档等）与 URL 选择口径。
//  从 UI/ListKit/TiebaPostRowModel.swift 拆出：UI/Media 的查看器也要读它，
//  且它是纯值语义的口径，不该挂在列表层。

import UIKit
import Nuke

struct TiebaPostPreferences: Sendable {
  var showIpLocation = true
  var showLevelBadge = true
  /// 等级徽标后面接头衔名（如「Lv.5 F2.8」；头衔随作者字段下发）。
  var showLevelTitle = false
  var showBothUsername = false
  var fontScale: CGFloat = 1
  var hideMedia = false
  var blockVideo = false
  var imageDarkenWhenNight = false
  var imageLoadType = "smart_origin"
  var dataSaverMode = "high"
  var isNight = false
  var timestampStyle = "relative"
  var videoAutoplay = false
  /// 1px hairline：trait 的 displayScale 只在 UIKit 上下文非 0（测量在后台队列），
  /// 所以由主线程的 load() 取好、随偏好一起传入（UIScreen.main 自 iOS 26 废弃）。
  var hairline: CGFloat = 1.0 / 3.0

  @MainActor
  static func load() -> TiebaPostPreferences {
    var prefs = TiebaPostPreferences()
    prefs.showIpLocation = TiebaPreferenceSnapshot.bool("showIpLocation", default: true)
    prefs.showLevelBadge = TiebaPreferenceSnapshot.bool("showLevelBadge", default: true)
    prefs.showLevelTitle = TiebaPreferenceSnapshot.bool("showLevelTitle", default: false)
    prefs.showBothUsername = TiebaPreferenceSnapshot.bool("showBothUsername", default: false)
    // 正文级字号倍率（设置→个性化→阅读字号→正文字号；旧键 fontScale 由 TiebaTypography 迁移）
    prefs.fontScale = TiebaTypography.bodyScale()
    prefs.hideMedia = TiebaPreferenceSnapshot.bool("hideMedia", default: false)
    prefs.blockVideo = TiebaPreferenceSnapshot.bool("blockVideo", default: false)
    prefs.imageDarkenWhenNight = TiebaPreferenceSnapshot.bool("imageDarkenWhenNight", default: false)
    prefs.imageLoadType = TiebaPreferenceSnapshot.string("imageLoadType") ?? "smart_origin"
    prefs.dataSaverMode = TiebaPreferenceSnapshot.string("dataSaverMode") ?? "high"
    prefs.timestampStyle = TiebaPreferenceSnapshot.string("timestampStyle") ?? "relative"
    prefs.videoAutoplay = TiebaPreferenceSnapshot.bool("videoAutoplay", default: false)
    prefs.hairline = 1 / max(UITraitCollection.current.displayScale, 1)
    prefs.isNight = TiebaChromeTheme.current.dark
    return prefs
  }

  /// 钳制域必须**覆盖整个偏好范围**（12…24pt ⇒ 0.706…1.412）：原来写死 0.8…2.0
  /// 会把 12～13.6pt 一档全部压成 0.8（用户在小字号端拖滑杆"没反应"）。
  var fontScaleClamped: CGFloat { min(max(fontScale, 0.7), 1.45) }
}

extension TiebaPostPreferences {
  /// 该偏好下这张图该用哪个 URL：无图档 → nil；原图档 → originSrc（缺失回落 src）；
  /// 其余 → src（缺失回落 originSrc）。归一走 TiebaImageURL。
  /// 从 UI/ListKit/TiebaPostRowText.swift 下沉：查看器与列表行都要按同一份口径选图源。
  func displayURL(for image: TiebaThreadImage) -> URL? {
    if imageLoadType == "all_no" { return nil }
    let raw = imageLoadType == "all_origin"
      ? (image.originSrc.isEmpty ? image.src : image.originSrc)
      : (image.src.isEmpty ? image.originSrc : image.src)
    return TiebaImageURL.normalized(raw)
  }
}
