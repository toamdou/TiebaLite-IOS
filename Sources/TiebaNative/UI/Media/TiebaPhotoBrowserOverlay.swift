// 从 TiebaPhotoBrowser.swift 拆出（H10 千行文件拆分）：缩略图源视图 + 顶栏/页码覆盖层。
// 纯搬运：整类型逐字搬走。

import JXPhotoBrowser
import Nuke
import UIKit

final class TiebaPhotoSourceThumbnailView: UIImageView {}

// MARK: - 顶栏 chrome overlay（关闭 + 页码/标题 + 保存/分享）

/// 旧查看器顶栏（styles.ts topBar / topBarButton）：黑色玻璃条 +
/// 左侧 40pt 圆形关闭钮（xmark 22 bold、白 10% 底、按压 0.55 透明度）+
/// 中间 "n/N" 16pt semibold 与 13pt 上下文标题 + 右侧保存/分享 40pt 圆钮。
/// 动作（save/share）由 session 转给原生 ActionController 执行。
/// 顶栏底/圆钮走系统液态玻璃（部署底线 iOS 26，UIGlassEffect 恒可用）。
final class TiebaPhotoBrowserChromeOverlay: UIView, JXPhotoBrowserOverlay {
  var onClose: (() -> Void)?
  /// 顶栏动作：与长按菜单同一套枚举（单一事实来源）。
  var onAction: ((TiebaPhotoBrowserAction) -> Void)?

  private static let buttonSize: CGFloat = 40
  private static let horizontalPadding: CGFloat = 16
  private static let bottomPadding: CGFloat = 8
  private static let minimumTopPadding: CGFloat = 30

  /// 顶栏底材质：系统液态玻璃（部署底线 iOS 26，恒可用）。
  private static func makeBarEffect() -> UIVisualEffect {
    let effect = UIGlassEffect(style: .regular)
    // 顶栏恒深色（查看器黑底），玻璃带深色调保证白字/白图标可读。
    effect.tintColor = UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.4)
    return effect
  }

  private let blur = UIVisualEffectView(effect: TiebaPhotoBrowserChromeOverlay.makeBarEffect())
  /// A1（报告 37 第一优先）：顶栏这一行里的两块玻璃（关闭圆钮 + 保存/分享胶囊）放进同一个
  /// UIGlassContainerEffect 容器 —— 与吧首页顶栏同一做法（见 UI/Components/TiebaGlassContainerView）。
  /// 容器自己没有材质、不参与渲染；两块玻璃的中心距 ≈ 屏宽 − 2×16 − 40 − 80 ≫ spacing 7.0
  /// ⇒ **稳态观感一字不变**（A1 原来在弹层的落点随 UI/Popups 目录删除，这里重建）。
  private let glassHost = TiebaGlassContainerView()
  private let closeButton = TiebaPhotoBrowserCircleButton(type: .custom)
  /// C3：iPad 指针交互实例必须被**强引用**（UIPointerInteraction.delegate 是 weak），故留一个属性。
  private var closePointer: TiebaPointerInteraction?
  /// C1：保存 + 分享 = **一整块**玻璃胶囊里的两颗等宽圆钮。
  /// 改前：两颗各自带 .glass() 的独立圆钮（两颗玻璃小方块，8pt 缝）—— 看起来是"两个按钮"；
  /// 改后：整组一块胶囊，按钮是它的等分分区（单按钮最小区 = 组高 ⇒ 永远是圆），
  ///       按下反馈由整块胶囊的面积守恒形变承担（A3），按钮自己不再变暗。
  private lazy var actionGroup: TiebaGlassControlGroup = TiebaGlassControlGroup(
    items: [
      TiebaGlassControlGroup.Item(
        symbol: "square.and.arrow.down",
        accessibilityLabel: "保存到相册",
        action: { [weak self] in self?.handleSave() }
      ),
      TiebaGlassControlGroup.Item(
        symbol: "square.and.arrow.up",
        accessibilityLabel: "分享图片",
        action: { [weak self] in self?.handleShare() }
      ),
    ],
    height: TiebaPhotoBrowserChromeOverlay.buttonSize,
    tintColor: .white,
    // 与顶栏底同一枚 tint（查看器黑底 ⇒ 玻璃带深色调保证白字/白图标可读）。
    glassTintColor: UIColor(red: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.4)
  )
  private let counterLabel = UILabel()
  private let titleLabel = UILabel()
  /// 中间「页码 + 标题」列（持有它才能把这一行聚合成一个可访问单元，见 updateCounter）。
  private let centerStack = UIStackView()
  private let title: String?
  private var totalItems = 0
  private var heightConstraint: NSLayoutConstraint?
  private var topPaddingConstraint: NSLayoutConstraint?
  /// chrome 显隐的**可中断 + 可合并**转场（ControlledTransition 的首个落点，见 setVisible）。
  private var visibilityTransition: TiebaControlledTransition?
  private var visibilityProgress: TiebaDisplayLinkAnimator?

  init(title: String?) {
    self.title = title
    super.init(frame: .zero)
    build()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  private func build() {
    backgroundColor = .clear

    blur.isUserInteractionEnabled = false
    blur.translatesAutoresizingMaskIntoConstraints = false
    addSubview(blur)

    // A1：容器铺满整条顶栏（玻璃件都在它的 contentView 里，空白区照旧由本视图接管命中，
    // 与改前逐点相同 —— 容器的 hitTest 只认内容子视图，见 TiebaGlassContainerView）。
    glassHost.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glassHost)
    NSLayoutConstraint.activate([
      glassHost.leadingAnchor.constraint(equalTo: leadingAnchor),
      glassHost.trailingAnchor.constraint(equalTo: trailingAnchor),
      glassHost.topAnchor.constraint(equalTo: topAnchor),
      glassHost.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    configureButton(closeButton, symbol: "xmark", weight: .bold, label: "关闭图片查看器")
    closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)

    // C1：整组一块玻璃胶囊（自带阴影图 + 触摸形变 + 高光），按钮等宽分区。
    actionGroup.translatesAutoresizingMaskIntoConstraints = false
    // A1：同一行的两块玻璃进同一个容器（关闭圆钮见 configureButton）。
    glassHost.contentView.addSubview(actionGroup)
    // C3：iPad 指针 —— 每颗按钮一颗圆形高亮（hover 档显式关掉内容缩放，见 TiebaPointerInteraction）。
    actionGroup.installPointerInteractions()

    counterLabel.textColor = .white
    counterLabel.font = .systemFont(ofSize: 16, weight: .semibold)
    counterLabel.textAlignment = .center

    titleLabel.text = title
    titleLabel.textColor = UIColor.white.withAlphaComponent(0.85)
    titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
    titleLabel.textAlignment = .center
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.isHidden = (title?.isEmpty ?? true)

    centerStack.addArrangedSubview(counterLabel)
    centerStack.addArrangedSubview(titleLabel)
    // ③-6 一行一可访问单元：中间「页码 + 标题」聚合成**一个**元素（原来 VoiceOver 读成
    // 「3/9」「标题」两段孤立文本）。文案随页码在 updateCounter 里更新。
    centerStack.isAccessibilityElement = true
    centerStack.accessibilityTraits = .staticText
    centerStack.axis = .vertical
    centerStack.alignment = .center
    centerStack.spacing = 2
    centerStack.isUserInteractionEnabled = false
    centerStack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(centerStack)

    NSLayoutConstraint.activate([
      blur.topAnchor.constraint(equalTo: topAnchor),
      blur.leadingAnchor.constraint(equalTo: leadingAnchor),
      blur.trailingAnchor.constraint(equalTo: trailingAnchor),
      blur.bottomAnchor.constraint(equalTo: bottomAnchor),
      centerStack.centerXAnchor.constraint(equalTo: centerXAnchor),
      centerStack.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
      centerStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 96),
      centerStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -96),
    ])
  }

  private func configureButton(
    _ button: TiebaPhotoBrowserCircleButton,
    symbol: String,
    weight: UIImage.SymbolWeight,
    label: String
  ) {
    button.translatesAutoresizingMaskIntoConstraints = false
    button.tintColor = .white
    let image = UIImage(
      systemName: symbol,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: weight)
    )
    // 系统液态玻璃圆钮（部署底线 iOS 26，恒可用）。
    var config = UIButton.Configuration.glass()
    config.image = image
    config.baseForegroundColor = .white
    config.cornerStyle = .capsule
    button.configuration = config
    button.accessibilityLabel = label
    // A1：玻璃圆钮进顶栏的玻璃容器（与 actionGroup 同一个 UIGlassContainerEffect）。
    glassHost.contentView.addSubview(button)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: Self.buttonSize),
      button.heightAnchor.constraint(equalToConstant: Self.buttonSize),
    ])
  }

  // MARK: JXPhotoBrowserOverlay

  func setup(with browser: JXPhotoBrowserViewController) {
    translatesAutoresizingMaskIntoConstraints = false
    let container = browser.view!
    let top = topAnchor.constraint(equalTo: container.topAnchor)
    let leading = leadingAnchor.constraint(equalTo: container.leadingAnchor)
    let trailing = trailingAnchor.constraint(equalTo: container.trailingAnchor)
    let height = heightAnchor.constraint(equalToConstant: 78)
    NSLayoutConstraint.activate([top, leading, trailing, height])
    heightConstraint = height

    // A1：几何锚点从本视图换成玻璃容器（容器与 bounds 等值 ⇒ 位置逐值不变）。
    closeButton.leadingAnchor.constraint(
      equalTo: glassHost.leadingAnchor,
      constant: Self.horizontalPadding
    ).isActive = true
    topPaddingConstraint = closeButton.topAnchor.constraint(equalTo: glassHost.topAnchor, constant: Self.minimumTopPadding)
    topPaddingConstraint?.isActive = true
    // C1：胶囊贴右，宽度由 intrinsicContentSize 给（按钮数 × 组高），高度 = 组高。
    actionGroup.trailingAnchor.constraint(
      equalTo: glassHost.trailingAnchor,
      constant: -Self.horizontalPadding
    ).isActive = true
    actionGroup.topAnchor.constraint(equalTo: closeButton.topAnchor).isActive = true
    actionGroup.heightAnchor.constraint(equalToConstant: Self.buttonSize).isActive = true
    closePointer = TiebaPointerInteraction(view: closeButton, style: .circle(nil))

    updateMetrics()
  }

  func reloadData(numberOfItems: Int, pageIndex: Int) {
    totalItems = numberOfItems
    updateCounter(pageIndex: pageIndex)
  }

  func didChangedPageIndex(_ index: Int) {
    updateCounter(pageIndex: index)
    updateMetrics()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateMetrics()
  }

  /// 顶栏内容下缘 = max(安全区顶, 30)（旧 topBar paddingTop: max(insets.top,30)）。
  private func updateMetrics() {
    let insets = superview?.safeAreaInsets ?? safeAreaInsets
    let top = max(insets.top, Self.minimumTopPadding)
    topPaddingConstraint?.constant = top
    heightConstraint?.constant = top + Self.buttonSize + Self.bottomPadding
  }

  private func updateCounter(pageIndex: Int) {
    // 改前症状：单图会话的页码圆点已 hidesForSinglePage，顶栏计数却仍无条件写「1/1」——
    // 同一 chrome 两种页码口径（复检 A7-6）。
    // 改后行为：只有多图会话才写页码；单图/空会话清空并隐藏（counterLabel 在 stack 里，
    // isHidden 会一并收掉它占的宽度）。
    guard totalItems > 1 else {
      counterLabel.text = nil
      counterLabel.isHidden = true
      centerStack.accessibilityLabel = (title?.isEmpty ?? true) ? nil : title
      return
    }
    let safeIndex = max(0, min(pageIndex, max(totalItems - 1, 0)))
    counterLabel.isHidden = false
    counterLabel.text = "\(safeIndex + 1)/\(totalItems)"
    // ③-6：这一行读成一句自然语句（页码 + 上下文标题），而不是两段孤立文本。
    var parts = ["第 \(safeIndex + 1) 张，共 \(totalItems) 张"]
    if let title, !title.isEmpty { parts.append(title) }
    centerStack.accessibilityLabel = parts.joined(separator: "，")
  }

  // MARK: 显隐 / 动作

  /// chrome 显隐：**可中断 + 可合并**的转场（ControlledTransition 的首个落点）。
  /// 改前症状：每次切换都是一段独立的 UIView 动画；连点（tap-tap-tap 切显隐）时后一段从自己的
  /// 起点重播曲线，与前一段「抢动画」，中间有一下顿挫，且两段之间没有语义接续。
  /// 改后行为：新一段 merge 掉上一段未完成的属性，并从**当前呈现值**续跑（NativeAnimator 的
  /// updateAlpha 以 layer.presentation() 为起点），全程只有一条曲线，随时可被下一次切换打断。
  /// 时长/曲线与旧值同形：0.2s + easeInOut 的贝塞尔控制点 (0.42, 0, 0.58, 1)。
  func setVisible(_ visible: Bool, animated: Bool) {
    isUserInteractionEnabled = visible
    // C5（按报告给的 scale + alpha 近似，**不引私有 CAFilter**）：按钮组从"略小 + 透明"
    // 凝聚出来，几何与材质各有各的节奏（B1 的烘焙关键帧，见 TiebaGlassControlGroup.playEntrance）。
    if visible {
      actionGroup.playEntrance()
    }
    let target: CGFloat = visible ? 1 : 0
    guard animated else {
      visibilityProgress?.invalidate()
      visibilityProgress = nil
      visibilityTransition = nil
      alpha = target
      return
    }
    let duration = TiebaAnimationDuration.tapFeedback
    // [按上游调曲线] 改前 curve: .custom(0.42, 0, 0.58, 1)（标准 easeInOut）—— 起步与收尾一样"平"。
    // 改后 curve: .spring —— 引擎的 .spring 在 iOS 26 上就是那颗系统弹簧（mass 1 / stiffness 555.027 /
    // damping 47.118，ζ = 1.000 临界阻尼，出处见 TiebaMotionSpec.Spring.ios26Mass）。
    // 手感变化：**起步更快、尾巴更长** —— chrome 像是"先亮起来再落定"，而不是匀速淡出；
    // 因为 ζ 恰好 = 1.000，**不会过冲**（透明度也不会越过 1 再回来）。
    // 可中断/可合并的语义一字未改：走的仍是 TiebaControlledTransition（本段注释上面那 4 行说的性质全部保留）。
    let transition = TiebaControlledTransition(
      duration: duration,
      curve: .spring,
      interactive: true
    )
    transition.animator.updateAlpha(layer: layer, alpha: target, completion: nil)
    if let previous = visibilityTransition {
      // 顺序要紧：先登记新属性、再 merge —— merge 逐条比对「同 layer + 同 keyPath」的属性，
      // 新表为空时它什么也取消不掉。forceRestart：连点以新目标为准，旧段就地作废。
      transition.merge(with: previous, forceRestart: true)
    }
    visibilityTransition = transition
    visibilityProgress?.invalidate()
    visibilityProgress = TiebaDisplayLinkAnimator(
      duration: duration,
      from: 0.0,
      to: 1.0,
      update: { [weak transition] progress in
        transition?.animator.setAnimationProgress(progress)
      },
      completion: { [weak transition] in
        transition?.animator.finishAnimation()
      }
    )
  }

  @objc private func handleClose() {
    TiebaSceneHaptics.fire("press")
    onClose?()
  }

  @objc private func handleSave() {
    TiebaSceneHaptics.fire("press")
    onAction?(.save)
  }

  @objc private func handleShare() {
    TiebaSceneHaptics.fire("press")
    onAction?(.share)
  }
}

/// 圆形按钮：按压 0.55 透明度（styles.ts topBarButtonPressed，旧查看器
/// 顶栏按钮无高光，仅按压微降不透明度）。
final class TiebaPhotoBrowserCircleButton: UIButton {
  /// C2：按下**即时**、松开才走 0.2s 缓出（报告 ToolbarNode.swift:83-119 的六行配方）。
  /// 两个细节都不能省：
  ///   · 按下先 removeAnimation("opacity") —— 上一次松开的回弹还在跑时，动画会把 alpha 拉回去，
  ///     表现就是"按了不变暗"；
  ///   · 松开用 animateAlpha(0.55 → 1, 0.2) 而不是直接赋值 —— 快速点击时按下已经即时可见，
  ///     松开这一下是"回弹"的情绪，两者不对称才是跟手的关键。
  /// 按压档位 0.55 保持本仓原值（styles.ts topBarButtonPressed），只改时序。
  override var isHighlighted: Bool {
    didSet {
      if isHighlighted {
        layer.removeAnimation(forKey: "opacity")
        alpha = 0.55
      } else {
        alpha = 1.0
        layer.animateAlpha(from: 0.55, to: 1.0, duration: TiebaAnimationDuration.tapFeedback)
      }
    }
  }
}

// MARK: - 页变化事件 overlay（框架的页码通知通道）

/// 页码变化 → chrome 自动收起计时。用 overlay 而不是 KVO：
/// JXPhotoBrowserViewController.pageIndex 的 didSet 只通知 overlays
/// （JXPhotoBrowserViewController.swift:16-30）。
final class TiebaPhotoBrowserEventOverlay: UIView, JXPhotoBrowserOverlay {
  var onPageChanged: ((Int) -> Void)?
  private var lastIndex: Int?

  func setup(with browser: JXPhotoBrowserViewController) {
    isUserInteractionEnabled = false
    isHidden = true
  }

  func reloadData(numberOfItems: Int, pageIndex: Int) {
    // reloadData 在初始定位/布局后触发：只记录基线，不发首帧事件。
    lastIndex = pageIndex
  }

  func didChangedPageIndex(_ index: Int) {
    guard index != lastIndex else { return }
    lastIndex = index
    onPageChanged?(index)
  }
}
