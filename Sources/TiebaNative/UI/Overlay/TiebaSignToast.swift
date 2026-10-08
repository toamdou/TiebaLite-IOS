//  签到结果的玻璃胶囊提示。\n//  从 Core/Networking/TiebaSignService.swift 拆出：提示视图属于 UI 层，\n//  Core 只通过 TiebaAppHooks.showSignToast 请求弹一条结果提示。

import Foundation
import UIKit
import UserNotifications

private final class TiebaSignToastView: UIView {
  private static let horizontalPadding: CGFloat = 16
  private static let verticalPadding: CGFloat = 9
  private static let contentGap: CGFloat = 6
  private static let indicatorSize: CGFloat = 18

  private let iconView = UIImageView()
  private let label = UILabel()
  private var hideWorkItem: DispatchWorkItem?

  init() {
    super.init(frame: .zero)
    layer.cornerRadius = 18
    layer.cornerCurve = .continuous
    clipsToBounds = true
    isUserInteractionEnabled = false
    isHidden = true
    alpha = 0

    let backdrop = TiebaGlassContainerView.makeEffect()
    backdrop.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backdrop)

    iconView.tintColor = .label
    iconView.contentMode = .scaleAspectFit
    iconView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(iconView)

    label.textColor = .label
    label.font = .systemFont(ofSize: 14, weight: .medium)
    label.textAlignment = .center
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    addSubview(label)

    NSLayoutConstraint.activate([
      backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
      backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
      backdrop.topAnchor.constraint(equalTo: topAnchor),
      backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: Self.indicatorSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.indicatorSize),

      label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.contentGap),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
      label.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),
      label.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(success: Bool, text: String) {
    iconView.image = UIImage(
      systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    )
    label.text = text
    isHidden = false
    TiebaAnimation.animate(duration: 0.18) { self.alpha = 1 }
    hideWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.hideToast() }
    hideWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: item)
  }

  private func hideToast() {
    hideWorkItem?.cancel()
    hideWorkItem = nil
    TiebaAnimation.animate(duration: 0.18, animations: { self.alpha = 0 }) { _ in
      self.isHidden = true
    }
  }
}

/// 提示门面：TiebaNavigator 在 install 时把它接进 TiebaAppHooks.showSignToast，
/// Core 侧（TiebaSignService）只发"弹一条签到结果"，不认识任何视图类型。
enum TiebaSignToast {
  /// 贴宿主视图底部居中、安全区上方 24pt（旧 TiebaSignService.toast 的落点，逐点相同）。
  @MainActor
  static func show(_ text: String, on presenter: UIViewController) {
    let pill = TiebaSignToastView()
    presenter.view.addSubview(pill)
    pill.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      pill.centerXAnchor.constraint(equalTo: presenter.view.centerXAnchor),
      pill.bottomAnchor.constraint(equalTo: presenter.view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
    ])
    pill.show(success: true, text: text)
  }
}

