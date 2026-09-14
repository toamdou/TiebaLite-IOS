// 吧三页（详情 / 吧规 / 吧务）共用的小件：圆形头像（Nuke + 首字占位）与
// 人数格式化（与 utils/index.ts formatCount 同规则）。
import UIKit
import Nuke
import NukeExtensions

final class TiebaForumAvatarView: UIView {
  private let imageView = UIImageView()
  private let initialLabel = UILabel()
  /// 固定显示边长（init 约束死了宽高；下采样目标不依赖布局时机）。
  private let side: CGFloat

  init(size: CGFloat) {
    side = size
    super.init(frame: .zero)
    clipsToBounds = true
    layer.cornerRadius = size / 2
    backgroundColor = .secondarySystemFill
    imageView.contentMode = .scaleAspectFill
    imageView.translatesAutoresizingMaskIntoConstraints = false
    initialLabel.font = .systemFont(ofSize: max(size * 0.4, 10), weight: .semibold)
    initialLabel.textColor = .secondaryLabel
    initialLabel.textAlignment = .center
    initialLabel.translatesAutoresizingMaskIntoConstraints = false
    addSubview(imageView)
    addSubview(initialLabel)
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: size),
      heightAnchor.constraint(equalToConstant: size),
      imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
      imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
      imageView.topAnchor.constraint(equalTo: topAnchor),
      imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
      initialLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
      initialLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func configure(url: String, initial: String) {
    initialLabel.text = String(initial.prefix(1))
    initialLabel.isHidden = false
    guard !url.isEmpty, let target = URL(string: url) else {
      // 无图/换人：取消在途请求并清旧图（NukeExtensions 关联的取消/清图）。
      cancelRequest(for: imageView)
      imageView.image = nil
      return
    }
    // 下采样目标 = 固定边长 × 视图 displayScale（不读 bounds：configure 常早于
    // 首次布局；UIScreen.main 自 iOS 26 废弃）。
    loadImage(
      with: TiebaNuke.secureURL(target),
      options: TiebaNuke.options(maxPixel: side * traitCollection.displayScale),
      into: imageView
    ) { [weak self] result in
      guard let self, case .success = result else { return }
      self.initialLabel.isHidden = true
    }
  }
}

enum TiebaForumFormat {
  /// 与 utils/index.ts formatCount 同规则（亿 / 万 / k，一位小数 half-up）。
  static func count(_ value: Double) -> String {
    guard value.isFinite else { return "" }
    if value >= 100_000_000 { return oneDecimal(value / 100_000_000) + "亿" }
    if value >= 10_000 { return oneDecimal(value / 10_000) + "万" }
    if value >= 1_000 { return oneDecimal(value / 1_000) + "k" }
    if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
    return String(value)
  }

  static func count(_ value: Int) -> String { count(Double(value)) }

  /// toFixed(1) 半进位：先量化到 0.1 再格式化，避免 %.1f 的银行家舍入。
  private static func oneDecimal(_ value: Double) -> String {
    let rounded = (value * 10 + 0.5).rounded(.down) / 10
    return String(format: "%.1f", rounded)
  }
}
