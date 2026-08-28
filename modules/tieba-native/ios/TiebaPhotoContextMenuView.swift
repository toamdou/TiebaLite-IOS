import ExpoModulesCore
import UIKit

/// 长按图片 → iOS 系统上下文菜单（X/Twitter 同款形态）。
///
/// 用法：JS 把一张已渲染的缩略图（RN 子树）作为子视图放进本容器。长按激活时
/// 系统呈现「背景压暗 + 明亮圆角大图预览 + 深/浅色跟随系统的菜单」——
/// previewProvider 返回 UIViewController（iOS 14+ 系统行为）：预览居中、
/// 菜单紧随其正下方，展开/收起动画以缩略图为锚点，全部由系统完成。
///
/// 图片来源：首帧直接截取屏幕上已渲染的缩略图位图（零下载、不跨缓存层），
/// 随后 `TiebaImageIO.loadImage` 后台加载原图（磁盘缓存命中零网络）淡入替换；
/// 加载失败保持首帧（与 X 行为一致，不显示错误 UI）。
/// 菜单项由 JS `actions` 配置（id/title/icon/destructive），点击经 `onAction` 回传。
public final class TiebaPhotoContextMenuView: ExpoView {
  // MARK: - Props

  /// 原图 URL（预览加载目标）
  var fullUrl: String?
  /// 原图像素宽高（预览尺寸计算；<=0 按方形兜底）
  var imageWidth: Double = 0
  var imageHeight: Double = 0
  /// 是否显示放大预览：true = 压暗 + 大图预览 + 菜单在下方（信息流）；
  /// false = 仅菜单在长按位置弹出（大图查看器内，页面本身已是大图）
  var previewEnabled: Bool = true
  /// 菜单项配置：[{ id, title, icon, destructive }]
  var actions: [[String: Any]] = [] {
    didSet { menuActions = actions.compactMap(TiebaPhotoMenuAction.init(dict:)) }
  }

  /// 点击菜单项：onAction(["action": id])
  let onAction = EventDispatcher()
  /// 长按激活、预览/菜单升起动画开始的瞬间（「弹出大图」实时触觉触发点）。
  /// 仅 previewEnabled 时发——查看器内只弹菜单无大图预览，不属于该语义。
  let onMenuPresent = EventDispatcher()

  // MARK: - Private

  private var menuActions: [TiebaPhotoMenuAction] = []

  public required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    addInteraction(UIContextMenuInteraction(delegate: self))
  }

  /// 预览首帧：截取触发视图当前已渲染内容（复用信息流已展示的缩略图位图）。
  /// afterScreenUpdates: false —— 取屏上现有帧，不等待重绘。
  private func snapshotTrigger() -> UIImage? {
    guard bounds.width > 0, bounds.height > 0 else { return nil }
    return UIGraphicsImageRenderer(bounds: bounds).image { _ in
      drawHierarchy(in: bounds, afterScreenUpdates: false)
    }
  }
}

// MARK: - UIContextMenuInteractionDelegate

extension TiebaPhotoContextMenuView: UIContextMenuInteractionDelegate {
  public func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    configurationForMenuAtLocation location: CGPoint
  ) -> UIContextMenuConfiguration? {
    // 菜单即将呈现时才截取首帧（长按已激活，缩略图必然已在屏上）
    let snapshot = snapshotTrigger()

    // previewProvider 懒调用：仅当长按手势真正激活时才创建预览视图，
    // 未触发时零额外渲染/网络开销。previewEnabled=false 时系统只在
    // 长按位置弹出菜单（大图查看器内使用，页面本身已是大图）。
    let previewProvider: UIContextMenuContentPreviewProvider? = previewEnabled
      ? { [weak self] in
          guard let self else { return nil }
          return TiebaPhotoPreviewViewController(
            initialImage: snapshot,
            fullUrl: self.fullUrl,
            pixelWidth: self.imageWidth,
            pixelHeight: self.imageHeight
          )
        }
      : nil

    let actionProvider: UIContextMenuActionProvider = { [weak self] _ in
      guard let self, !self.menuActions.isEmpty else { return nil }
      let children = self.menuActions.map { action in
        let uiAction = UIAction(
          title: action.title,
          image: UIImage(systemName: action.icon)
        ) { [weak self] _ in
          self?.onAction(["action": action.id])
        }
        if action.destructive {
          uiAction.attributes = [.destructive]
        }
        return uiAction
      }
      return UIMenu(children: children)
    }

    return UIContextMenuConfiguration(
      identifier: nil,
      previewProvider: previewProvider,
      actionProvider: actionProvider
    )
  }

  /// 展开动画以缩略图为锚点（系统从源图位置缩放过渡到居中预览）。
  /// previewEnabled=false（大图查看器内）时返回 nil：容器铺满全屏，
  /// 若仍以它为锚会把菜单/动画定位到屏幕中心；nil 让系统退回默认行为——
  /// 菜单直接出现在手指长按位置附近、无缩放动画，贴合手指。
  /// 锚点视图已不在 window（长按期间 FlashList 回收了缩略图 cell）时同样
  /// 返回 nil：飞回动画的目标已死，UIKit 会留下整屏空白（真机实测
  /// "退出预览后整个画面一片空白"，2026-08-27）。
  public func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForHighlighting menuConfiguration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    guard previewEnabled, window != nil else { return nil }
    return UITargetedPreview(view: self)
  }

  /// 收起动画一律不飞回缩略图：预览跑在独立系统窗口（iOS 26+），飞回要把
  /// 预览快照搬回应用窗口完成位移动画——该路径在 iOS 27β 真机两次复现整屏
  /// 留白（含窗口存活、无滚动重排的场景），连同窗口底色误写浮层一起排查后
  /// 仍不能保证安全，直接废除。nil = 系统默认淡出，预览与菜单原地淡走。
  /// 展开（previewForHighlighting）保留目标预览：升起动画发生在系统窗口内，
  /// 是"大图从缩略图位置升起"的观感核心，且只在 window 存活时启用。
  public func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    previewForDismissing menuConfiguration: UIContextMenuConfiguration
  ) -> UITargetedPreview? {
    nil
  }

  /// 长按激活、升起动画开始的瞬间：发 onMenuPresent 给 JS 播「弹出大图」触觉。
  public func contextMenuInteraction(
    _ interaction: UIContextMenuInteraction,
    willDisplayMenuFor configuration: UIContextMenuConfiguration,
    animator: UIContextMenuInteractionAnimating?
  ) {
    guard previewEnabled else { return }
    onMenuPresent(["preview": true])
  }
}

// MARK: - 菜单项模型

private struct TiebaPhotoMenuAction {
  let id: String
  let title: String
  let icon: String
  let destructive: Bool

  init?(dict: [String: Any]) {
    guard let id = dict["id"] as? String,
          let title = dict["title"] as? String else { return nil }
    self.id = id
    self.title = title
    self.icon = dict["icon"] as? String ?? ""
    self.destructive = dict["destructive"] as? Bool ?? false
  }
}

// MARK: - 预览视图控制器

/// 预览内容：明亮圆角图片卡片。系统将其呈现为居中大图、菜单紧随其下、
/// 背景自动压暗（iOS 14+ UIViewController preview 行为）。
final class TiebaPhotoPreviewViewController: UIViewController {
  private let imageView = UIImageView()
  private let fullUrl: String?
  private var loadTask: Task<Void, Never>?

  init(initialImage: UIImage?, fullUrl: String?, pixelWidth: Double, pixelHeight: Double) {
    self.fullUrl = fullUrl

    // 预览尺寸：宽不超过屏宽 - 48，高按原图比例并给下方菜单留空间
    let screen = UIScreen.main.bounds
    let maxWidth = screen.width - 48
    let maxHeight = screen.height * 0.62
    let ratio = pixelWidth > 0 && pixelHeight > 0 ? pixelHeight / pixelWidth : 1
    var previewWidth = min(maxWidth, pixelWidth > 0 ? pixelWidth : 260)
    var previewHeight = previewWidth * ratio
    if previewHeight > maxHeight {
      previewHeight = maxHeight
      previewWidth = previewHeight / max(ratio, 0.01)
    }

    super.init(nibName: nil, bundle: nil)

    preferredContentSize = CGSize(width: previewWidth, height: previewHeight)

    imageView.image = initialImage
    imageView.contentMode = .scaleAspectFit
    imageView.clipsToBounds = true
    imageView.layer.cornerRadius = 16
    imageView.layer.cornerCurve = .continuous
    imageView.backgroundColor = .clear

    // 预览容器透明：只呈现图片本身的圆角卡片，不带系统材质底
    view.isOpaque = false
    view.backgroundColor = .clear
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    imageView.frame = view.bounds
    imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    view.addSubview(imageView)
    startLoadingFullImage()
  }

  private func startLoadingFullImage() {
    guard let fullUrl, !fullUrl.isEmpty else { return }
    loadTask = Task { [weak self] in
      do {
        let image = try await TiebaImageIO.shared.loadImage(fullUrl)
        guard !Task.isCancelled, let self else { return }
        UIView.transition(
          with: self.imageView,
          duration: 0.25,
          options: [.transitionCrossDissolve, .allowUserInteraction]
        ) {
          self.imageView.image = image
        }
      } catch {
        // 弱网 / 加载失败：保持缩略图首帧；不打断菜单交互
      }
    }
  }

  deinit {
    loadTask?.cancel()
  }
}