// 发现页内容表面 + 刷新回顶校验。
// 只放纯值/纯 UI 工具，不碰数据层；新文件仍在 Features/Explore 范围内。
import UIKit

enum TiebaExploreSurface {
  /// 动态卡片 / 热榜卡片 / 首页吧卡片统一使用的圆角与呼吸间距语义。
  static let cardRadius: CGFloat = 20
  static let cardGap: CGFloat = 8
  static let pageTopInset: CGFloat = 8
  static let pageBottomExtra: CGFloat = 20

  /// 主文本用近黑而不是纯黑：在纯白底上减少刺眼的硬对比，同时保留正文可读性。
  static let readablePrimary = UIColor { trait in
    if trait.accessibilityContrast == .high { return .label }
    return trait.userInterfaceStyle == .dark
      ? UIColor(white: 0.92, alpha: 1)
      : UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
  }

  /// 小字号正文/action/meta 的可读色：亮色至少 4.5:1；Increase Contrast 升到 label。
  static let readableSecondary = UIColor { trait in
    if trait.accessibilityContrast == .high { return .label }
    return trait.userInterfaceStyle == .dark
      ? UIColor(white: 0.66, alpha: 1)
      : UIColor(red: 0.408, green: 0.408, blue: 0.435, alpha: 1)
  }

  /// 图标可用 3:1 档，仍比系统 tertiaryLabel 更深，Increase Contrast 用 label。
  static let readableTertiary = UIColor { trait in
    if trait.accessibilityContrast == .high { return .label }
    return trait.userInterfaceStyle == .dark
      ? UIColor(white: 0.60, alpha: 1)
      : UIColor(red: 0.478, green: 0.478, blue: 0.510, alpha: 1)
  }

  /// 「精品」等小字号 warning 前缀在亮底也需 ≥4.5:1。
  static let readableWarning = UIColor { trait in
    if trait.userInterfaceStyle == .dark {
      return trait.accessibilityContrast == .high
        ? UIColor(red: 1, green: 0.82, blue: 0.48, alpha: 1)
        : UIColor(red: 1, green: 0.70, blue: 0.28, alpha: 1)
    }
    return trait.accessibilityContrast == .high
      ? UIColor(red: 0.42, green: 0.23, blue: 0.02, alpha: 1)
      : UIColor(red: 0.64, green: 0.35, blue: 0.02, alpha: 1)
  }

  /// like 状态不是装饰色：小字号红字在亮底也要 ≥4.5:1。
  static let readableLiked = UIColor { trait in
    if trait.userInterfaceStyle == .dark {
      return trait.accessibilityContrast == .high
        ? UIColor(red: 1, green: 0.52, blue: 0.62, alpha: 1)
        : UIColor(red: 1, green: 0.42, blue: 0.54, alpha: 1)
    }
    return trait.accessibilityContrast == .high
      ? UIColor(red: 0.55, green: 0.02, blue: 0.13, alpha: 1)
      : UIColor(red: 0.69, green: 0.05, blue: 0.19, alpha: 1)
  }

  /// 品牌填充（按钮底）：亮/暗都是 #2563EB 的同色相档，配白字 ≥4.5:1。
  static let brandFill = UIColor { trait in
    if trait.accessibilityContrast == .high {
      return UIColor(red: 0.02, green: 0.34, blue: 0.80, alpha: 1)
    }
    return UIColor(red: CGFloat(0x0A) / 255, green: CGFloat(0x6C) / 255, blue: 1, alpha: 1)
  }

  /// 品牌前景（链接/强调文字）：暗色底需要更亮的同色相版本才能满足 4.5:1。
  static let brandForeground = UIColor { trait in
    if trait.userInterfaceStyle == .dark {
      return trait.accessibilityContrast == .high
        ? UIColor(red: 0.76, green: 0.86, blue: 1, alpha: 1)
        : UIColor(red: 0.39, green: 0.66, blue: 1, alpha: 1)
    }
    return trait.accessibilityContrast == .high
      ? UIColor(red: 0.02, green: 0.27, blue: 0.67, alpha: 1)
      : UIColor(red: CGFloat(0x0A) / 255, green: CGFloat(0x6C) / 255, blue: 1, alpha: 1)
  }

  /// 页面/卡片以系统背景为主；整块内容面不再叠 secondary/tonal 灰。
  /// 灰只留在 0.5px 分界、小 chip、头像/图片占位这些低面积元素上。
  static func palette() -> TiebaFeedRowPalette {
    var palette = TiebaFeedRowPalette.default
    palette.card = TiebaAccessibleColors.elevatedSurface
    palette.borderCard = UIColor.separator.withAlphaComponent(0.28)
    palette.placeholder = .tertiarySystemFill
    // 吧名 chip 用低面积品牌 tint，给纯白 feed 一点点颜色锚点；不是大面积灰底。
    palette.chip = brandForeground.withAlphaComponent(0.10)
    palette.onChip = readableSecondary
    palette.avatarFallback = .secondarySystemFill
    palette.primary = brandForeground
    palette.text = readablePrimary
    palette.textSecondary = readableSecondary
    palette.textTertiary = readableTertiary
    palette.liked = readableLiked
    palette.warning = readableWarning
    return palette
  }
}

/// 刷新落位目标：滚动视图自身坐标系里的 top，已把 contentInset/adjustedContentInset
/// 算进去。宿主 container 位于分段 chrome 下方，因此这里不再额外加 chrome 高度。
@MainActor
enum TiebaExploreRefreshAnchor {
  static func targetY(for scrollView: UIScrollView) -> CGFloat {
    -scrollView.adjustedContentInset.top
  }

  static func lock(_ scrollView: UIScrollView) {
    let target = targetY(for: scrollView)
    if abs(scrollView.contentOffset.y - target) > 0.25 {
      scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: target), animated: false)
    }
  }

  #if DEBUG
  /// Debug 只在刷新锚点收尾时调用；Release 编译为空，不会刷日志。
  static func logIfClipped(context: String, scrollView: UIScrollView) {
    let target = targetY(for: scrollView)
    let overshoot = scrollView.contentOffset.y - target
    if overshoot > 0.5 {
      print(
        "[TiebaExploreRefreshAnchor] \(context) clipped by \(String(format: "%.2f", overshoot))pt "
          + "offset=\(scrollView.contentOffset.y) target=\(target) "
          + "adjustedTop=\(scrollView.adjustedContentInset.top)"
      )
    }
  }
  #endif
}
