// 从 TiebaPhotoBrowser.swift 拆出（H10 千行文件拆分）：浏览会话（转场与手势状态机）。
// 纯搬运：整类型逐字搬走。

import JXPhotoBrowser
import Nuke
import UIKit

/// 查看器 cell 的弱引用盒：框架会复用 cell，会话若强引用会把离屏 cell（连同一张解码图）留在内存里。
private final class TiebaPhotoBrowserCellBox {
  weak var cell: TiebaPhotoBrowserImageCell?

  init(_ cell: TiebaPhotoBrowserImageCell) {
    self.cell = cell
  }
}

@MainActor
final class TiebaPhotoBrowserSession: NSObject, @preconcurrency JXPhotoBrowserDelegate {
  let items: [TiebaPhotoItem]
  let initialIndex: Int
  let contextTitle: String?
  /// 手动「查看原图」的页（下标集合）：这些页改用原图档重载，菜单项随之消失
  ///（旧 JS ImageViewer 的 manualOriginalPages，逐页生效、翻页不回退）。
  private var manualOriginalPages: Set<Int> = []
  /// 超分结果内存 LRU（key = 该档 URL + 变体 + 尺寸）：只在内存、关闭查看器即释放、不写盘。
  private var superResolutionCache: [SuperResolutionKey: UIImage] = [:]
  /// LRU 使用顺序（尾部最新）；超上限时从头部淘汰。
  private var superResolutionRecency: [SuperResolutionKey] = []
  /// 单飞：一次只跑一张（正在跑的下标 + 任务，关闭/换档时取消）。
  private var superResolutionIndex: Int?
  private var superResolutionTask: Task<Void, Never>?
  /// 当前屏上各页的 cell（弱引用盒）：超分输入要取"这一页正在显示的那版像素"。
  private var visibleCells: [Int: TiebaPhotoBrowserCellBox] = [:]
  private weak var host: UIViewController?
  private(set) var browser: TiebaPhotoBrowserViewController?
  private let actions = TiebaPhotoBrowserActionController()

  private let transitionFrame: CGRect?
  /// 初始页以外的退出重算查询（见 SourceFrameProvider）；nil = 只认初始页几何。
  private let sourceFrameProvider: TiebaPhotoBrowser.SourceFrameProvider?
  /// 被点那一格已加载的压缩图（权威转场源）；nil = 退回窗口扫描找源图视图。
  private let sourceImage: UIImage?
  /// 展示完成回调（见 TiebaPhotoBrowser.present）；触发一次后即清空。
  private var onPresented: (@MainActor @Sendable () -> Void)?
  /// 关闭回调（见 TiebaPhotoBrowser.present）；触发一次即丢（会话随即释放）。
  private var onClose: (@MainActor @Sendable () -> Void)?
  private var sourceThumbnailView: TiebaPhotoSourceThumbnailView?
  /// 安装时的替身几何：翻回初始页且宿主算不出当前矩形时恢复。
  private var sourceThumbnailInitialFrame: CGRect?
  /// 进场黑底（撤除见 removePresentBackdrop）。
  private var presentBackdrop: UIView?

  /// 会话级预取器：列表预取在查看器打开期间暂停（TiebaKindListView:727），
  /// 查看器自己按同一像素尺寸预取相邻页，翻页不再空转等 willDisplay 才发请求。
  private let prefetcher = TiebaNuke.makePrefetcher()

  private var chrome: TiebaPhotoBrowserChromeOverlay?
  private var indicator: JXPageIndicatorOverlay?
  private var chromeVisible = true
  private var chromeAutoHideWorkItem: DispatchWorkItem?
  private var lastSafeAreaInsets: UIEdgeInsets = .zero
  private var didFinish = false

  /// 长按菜单项 = 旧查看器 VIEWER_IMAGE_ACTIONS（ImageViewer.tsx:74-78）：
  /// 保存 / 保存原图 / 分享 / 查看原图（末项逐页追加，见 ImageViewer.tsx:1282-1288）。
  /// 动作在原生执行（TiebaPhotoBrowserActionController），不再上报 JS；「保存原图」
  /// 需要 originUrl、「查看原图」需要服务端 showOriginalBtn（缺失时该项不展示，
  /// 见 TiebaPhotoItem）。
  /// 改前症状：动作 id 以裸字符串（save / save-original / view-original / share）在四个类型间
  /// 流转，`perform` 用 `default: break` 收尾 ⇒ 拼错或新增动作是**静默无反应**。
  /// 改后行为：动作收敛成本枚举，菜单表/过滤/执行三处都吃它；Vendor 边界（cell 回传的字符串）
  /// 只解析一次，未知值走 assertionFailure 而不是静默丢弃。
  static let menuActions: [(action: TiebaPhotoBrowserAction, title: String, icon: String)] = [
    (action: .save, title: "保存图片", icon: "square.and.arrow.down"),
    (action: .saveOriginal, title: "保存原图", icon: "arrow.down.to.line"),
    (action: .viewOriginal, title: "查看原图", icon: "photo"),
    (action: .share, title: "分享图片", icon: "square.and.arrow.up"),
    // 本仓新增（旧查看器没有）：对"当前这一档已加载像素"做 2× 超分，只换内存图。
    (action: .superResolution, title: "超分辨率", icon: "wand.and.stars"),
  ]

  init(
    items: [TiebaPhotoItem],
    initialIndex: Int,
    transition: TiebaPhotoTransition,
    sourceImage: UIImage?,
    sourceFrameProvider: TiebaPhotoBrowser.SourceFrameProvider?,
    onClose: (@MainActor @Sendable () -> Void)?,
    onPresented: (@MainActor @Sendable () -> Void)?,
    host: UIViewController
  ) {
    self.items = items
    self.sourceImage = sourceImage
    self.initialIndex = initialIndex
    self.host = host
    self.contextTitle = transition.contextTitle
    self.transitionFrame = transition.frame
    self.sourceFrameProvider = sourceFrameProvider
    self.onClose = onClose
    self.onPresented = onPresented
    super.init()
  }

  // MARK: 启动 / 收尾

  func start() -> Bool {
    guard let host else { return false }
    // UIViewController.view 在 Swift 里是隐式解包可选：显式标注类型避免
    // `host.view.window` 被推成 Optional 链。
    let hostView: UIView = host.view
    guard hostView.tiebaIsOnScreen else { return false }

    let browser = TiebaPhotoBrowserViewController()
    browser.delegate = self
    browser.initialIndex = initialIndex
    // 减少动态：直接无动画进出（旧查看器 reduceMotion 下也是瞬时开关）。
    browser.transitionType = UIAccessibility.isReduceMotionEnabled ? .none : .zoom
    browser.scrollDirection = .horizontal
    // 循环翻页至少要两张：单张会被循环虚拟数据源复制成 10 个同图页，滑一下只是
    // 同一张重载一次（长图尤其明显）。回弹拖动一并关掉——单张不该有左右位移。
    let hasMultipleItems = items.count > 1
    browser.isLoopingEnabled = hasMultipleItems
    browser.collectionView.bounces = hasMultipleItems
    browser.isDismissGestureEnabled = true
    browser.register(
      TiebaPhotoBrowserImageCell.self,
      forReuseIdentifier: TiebaPhotoBrowserImageCell.tiebaReuseIdentifier
    )
    browser.onDismissed = { [weak self] in self?.finish() }
    browser.onSafeAreaInsetsDidChange = { [weak self] insets in self?.applySafeArea(insets) }
    browser.onDidAppear = { [weak self] in
      guard let self else { return }
      self.removePresentBackdrop()
      self.prefetchNeighbors(of: self.browser?.pageIndex ?? self.initialIndex)
      // 展示完成回调只发一次（viewDidAppear 在转场动画结束后才到）。
      let presented = self.onPresented
      self.onPresented = nil
      presented?()
    }
    self.browser = browser

    installSourceThumbnail(hostView: hostView)
    installPresentBackdrop(on: browser)

    let indicator = JXPageIndicatorOverlay()
    indicator.hidesForSinglePage = true
    indicator.position = .bottom(padding: 28)
    browser.addOverlay(indicator)
    self.indicator = indicator

    let chrome = TiebaPhotoBrowserChromeOverlay(title: contextTitle)
    chrome.onClose = { [weak self] in self?.browser?.dismissSelf() }
    chrome.onAction = { [weak self] action in
      guard let self else { return }
      let index = self.browser?.pageIndex ?? self.initialIndex
      guard self.items.indices.contains(index) else { return }
      self.actions.perform(action: action, item: self.items[index])
    }
    browser.addOverlay(chrome)
    self.chrome = chrome

    let events = TiebaPhotoBrowserEventOverlay()
    events.onPageChanged = { [weak self] index in
      guard let self else { return }
      self.scheduleChromeAutoHide()
      self.prefetchNeighbors(of: index)
    }
    browser.addOverlay(events)

    // 保存/分享胶囊提示（进度/结果）挂在浏览器 view 顶层。
    let pillHost: UIView = browser.view
    actions.presenter = browser
    actions.attach(to: pillHost)

    browser.present(from: host)
    // 防御：宿主已在转场中/被别的 present 抢占时 UIKit 会丢弃本次展示，
    // 此时不会有 viewDidDisappear 回调 → 静态会话永不释放（后续 present
    // 全被拒）。下一 runloop 校验 present 链，未接上就按关闭收尾。
    DispatchQueue.main.async { [weak self] in
      guard let self, let browser = self.browser else { return }
      if browser.presentingViewController == nil && !browser.isBeingPresented {
        self.finish()
      }
    }
    return true
  }

  func dismiss(animated: Bool) {
    guard let browser else { return }
    if !animated {
      // 关掉转场代理，让 UIKit 走无动画拆除（reduceMotion 直关路径）。
      browser.transitioningDelegate = nil
      browser.transitionType = .none
    }
    browser.dismissSelf()
  }

  private func finish() {
    guard !didFinish else { return }
    didFinish = true
    // 正在跑的超分立刻取消（结果只对当前会话有意义），并丢掉所有内存图。
    superResolutionTask?.cancel()
    superResolutionTask = nil
    superResolutionIndex = nil
    superResolutionCache.removeAll()
    superResolutionRecency.removeAll()
    visibleCells.removeAll()
    sourceThumbnailView?.removeFromSuperview()
    sourceThumbnailView = nil
    removePresentBackdrop()
    prefetcher.stopPrefetching()
    chromeAutoHideWorkItem?.cancel()
    chromeAutoHideWorkItem = nil
    browser = nil
    // 关闭回调（宿主恢复打开期间暂停的状态）：与旧 onEvent 同时点、同线程（主）。
    let close = onClose
    onClose = nil
    close?()
    TiebaPhotoBrowser.sessionDidFinish()
  }

  // MARK: 源缩略图桥

  /// 建临时源缩略图：几何 + 垫图取自**被点那一格已加载的压缩图**（调用方点名，
  /// 权威源；横滑带格 / 单图 / 九宫格同一条路径）。它恒隐藏，只承担转场起止几何，
  /// 由 JXZoomPresentAnimator 拿它的 image 做"缩略图放大到全屏"的缩放动画。
  ///
  /// ⚠️ 源图拿不到时**不装缩略图**（框架降级 Fade）。绝不按矩形截屏：那截到的是
  /// "那个矩形位置上的屏幕内容"，源图未解析时会露出整张卡片（真机实证）。
  private func installSourceThumbnail(hostView: UIView) {
    guard let window = hostView.window else { return }
    let resolved: (frame: CGRect, image: UIImage)
    if let sourceImage, let frame = transitionFrame, frame.width >= 2, frame.height >= 2 {
      resolved = (frame, sourceImage)
    } else if let scanned = transitionSource(in: window), let image = scanned.image {
      resolved = (scanned.frame, image)
    } else {
      return
    }

    let thumbView = TiebaPhotoSourceThumbnailView(frame: hostView.convert(resolved.frame, from: nil))
    thumbView.image = resolved.image
    thumbView.contentMode = .scaleAspectFill
    thumbView.clipsToBounds = true
    thumbView.backgroundColor = .clear
    thumbView.isUserInteractionEnabled = false
    thumbView.isHidden = true
    hostView.addSubview(thumbView)
    sourceThumbnailView = thumbView
    // 初始页几何快照：翻回第一页/重算失败时恢复（不退回被点图的矩形）。
    sourceThumbnailInitialFrame = thumbView.frame
  }

  /// 转场源 = 被点图片视图的窗口 frame + 已解码图（免截屏、免下载）。
  /// 矩形若是卡片/媒体容器（图片视图完整落在其中）→ 连几何一起收敛到图片视图；
  /// 若是揭示移位后的目标位（图片视图与矩形只差一个纵向位移）→ 几何保留矩形
  /// （退出飞回才落在已就位处），垫图仍换真图，避免把矩形里的文字截进去。
  /// 都解析不到（未加载/非图片）→ (原矩形, 无图)，调用方矩形本身就是合法几何。
  ///
  /// ⚠️ 顺序是"同尺寸最近"优先、"完整落在矩形内"兜底：移位后的矩形容不下真图
  /// （两者差一个纵向位移），而卡片里的吧头像/角标小图恰好完整落在矩形内——反过来
  /// 先做 contained 就会拿吧头像当转场源（2026-09-15 用户报"点被屏幕底边裁掉的图，
  /// 先弹出吧头像再显示真实图片"）。
  private func transitionSource(in window: UIWindow) -> (frame: CGRect, image: UIImage?)? {
    guard let rect = transitionFrame, rect.width >= 2, rect.height >= 2,
          rect.width.isFinite, rect.height.isFinite else { return nil }
    if let near = TiebaPhotoBrowserSession.imageView(matching: rect, in: window) {
      return (rect, near.image)
    }
    if let contained = TiebaPhotoBrowserSession.imageView(containedIn: rect, in: window) {
      return (contained.convert(contained.bounds, to: nil), contained.image)
    }
    return (rect, nil)
  }

  /// 窗口层级里"完整落在 rect 内"的图片视图（有图、可见）：先要命中矩形中心
  /// 的（容器矩形里可能有多格），再比面积（卡片里还有头像/角标小图标）。
  private static func imageView(containedIn rect: CGRect, in window: UIWindow) -> UIImageView? {
    let container = rect.insetBy(dx: -1, dy: -1)
    let center = CGPoint(x: rect.midX, y: rect.midY)
    return bestImageView(in: window) { _, frame in
      guard container.contains(frame) else { return nil }
      let area = frame.width * frame.height
      return frame.contains(center) ? 1e12 + area : area
    }
  }

  /// 与 rect 同尺寸、离 rect 中心最近的可见图片视图（尺寸差 ≤2pt）：揭示移位后
  /// 的矩形只与真图差一个纵向位移，取最近者避免抓到别处尺寸相同的图。
  private static func imageView(matching rect: CGRect, in window: UIWindow) -> UIImageView? {
    let center = CGPoint(x: rect.midX, y: rect.midY)
    return bestImageView(in: window) { _, frame in
      guard abs(frame.width - rect.width) <= 2, abs(frame.height - rect.height) <= 2 else {
        return nil
      }
      return -hypot(frame.midX - center.x, frame.midY - center.y)
    }
  }

  /// 遍历窗口层级里可见、有图、尺寸非空的图片视图，交给 score 打分取最大者
  /// （score 返回 nil = 不合格）。窗口树数百个视图，present 一次的量级。
  private static func bestImageView(
    in window: UIWindow,
    score: (UIImageView, CGRect) -> CGFloat?
  ) -> UIImageView? {
    var best: (view: UIImageView, score: CGFloat)?
    func walk(_ view: UIView) {
      for sub in view.subviews where !sub.isHidden && sub.alpha > 0.01 {
        if let imageView = sub as? UIImageView, imageView.image != nil, !imageView.bounds.isEmpty,
           let value = score(imageView, sub.convert(sub.bounds, to: window)),
           best == nil || value > best!.score {
          best = (imageView, value)
        }
        walk(sub)
      }
    }
    walk(window)
    return best?.view
  }

  static func displayScale(for view: UIView) -> CGFloat {
    if let scale = view.window?.screen.scale, scale > 0 { return scale }
    let traitScale = view.traitCollection.displayScale
    return traitScale > 0 ? traitScale : 1
  }

  // MARK: 进场黑底

  /// 框架 Zoom 进场从 clear 渐变到 black（JXZoomPresentAnimator.swift:75），这
  /// 0.25s 下层列表的卡片（连文字）会透出来，像"先飞卡片再飞图"。垫一层不透明
  /// 黑底把进场起始帧限成"源图 + 黑底"，进场一结束即撤（下拉的渐透手感不变）。
  private func installPresentBackdrop(on browser: JXPhotoBrowserViewController) {
    let backdrop = UIView()
    backdrop.backgroundColor = .black
    backdrop.frame = browser.view.bounds
    backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    backdrop.isUserInteractionEnabled = false
    // B4：黑底之上再垫一层「源图的模糊版」，模糊半径 0 → 18 跟着系统转场一起补间
    //（移植自上游 submodules/Settings/WallpaperGalleryScreen/Sources/BlurredImageNode.swift:9-46,97-112）。
    // 底**仍是不透明黑**：上面"把进场起始帧限成源图+黑底"的语义不变（列表照样被挡住），
    // 只是围着源图的那一圈从纯黑变成源图的模糊色，飞图时不再像掉进一个黑洞。
    // 半径能补间靠 TiebaBlurLayer 借 opacity 的 CAAction 当模板：这里不写时长/曲线，
    // 用的就是系统给这次动画的那一份。
    if let sourceImage = self.sourceImage {
      let backdropBlur = TiebaBlurView(image: sourceImage)
      backdropBlur.frame = backdrop.bounds
      backdropBlur.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      backdropBlur.blurRadius = 0.0
      backdrop.addSubview(backdropBlur)
      UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
        backdropBlur.blurRadius = 18.0
      }
    }
    browser.view.insertSubview(backdrop, at: 0)
    presentBackdrop = backdrop
  }

  private func removePresentBackdrop() {
    presentBackdrop?.removeFromSuperview()
    presentBackdrop = nil
  }

  // MARK: 相邻页预取

  /// 预取 index ± 1（循环模式下取环绕页）：请求形态必须与展示完全一致
  /// （同一 URL + 同一处理器），否则内存缓存键不同、预取无效；页码变化重置任务集。
  private func prefetchNeighbors(of index: Int) {
    guard let browser, items.count > 1 else {
      prefetcher.stopPrefetching()
      return
    }
    let pixelSize = downsamplingPixelSize(for: browser)
    var indexes = Set<Int>()
    for offset in [-1, 1] {
      let neighbor = (index + offset + items.count) % items.count
      indexes.insert(neighbor)
    }
    indexes.remove(index)
    // 预取与展示必须同键：处理器由同一个工厂按（item 比例 + 展示框）算，
    // 容器尺寸取与 willDisplay 同一份（browser.view.bounds.size）。
    let containerSize = browser.view.bounds.size
    prefetcher.stopPrefetching()
    prefetcher.startPrefetching(
      with: indexes.map {
        // [R3-4] 必须走 displayItem(at:)：长按"查看原图"过的页是按原图档展示的，
        // 预取若用原始 items 就取了大图档 —— Nuke 缓存键含 URL，两档永不相等，
        // 下载/解码/占缓存全白做，翻回时 willDisplay 再发一次真实请求。
        TiebaPhotoBrowserImageLoader.request(
          displayItem(at: $0),
          pixelSize: pixelSize,
          containerSize: containerSize
        )
      }
    )
  }

  // MARK: JXPhotoBrowserDelegate

  func numberOfItems(in browser: JXPhotoBrowserViewController) -> Int {
    items.count
  }

  func photoBrowser(
    _ browser: JXPhotoBrowserViewController,
    cellForItemAt index: Int,
    at indexPath: IndexPath
  ) -> JXPhotoBrowserAnyCell {
    let cell = browser.dequeueReusableCell(
      withReuseIdentifier: TiebaPhotoBrowserImageCell.tiebaReuseIdentifier,
      for: indexPath
    )
    if let imageCell = cell as? TiebaPhotoBrowserImageCell {
      visibleCells[index] = TiebaPhotoBrowserCellBox(imageCell)
      imageCell.onSingleTap = { [weak self] in self?.toggleChrome() }
      imageCell.onMenuAction = { [weak self] rawAction in
        guard let self, self.items.indices.contains(index) else { return }
        // Vendor 边界：cell 回传的是字符串，进业务层前收敛成枚举（未知值不再静默吞掉）。
        guard let action = TiebaPhotoBrowserAction(rawValue: rawAction) else {
          assertionFailure("未知的查看器动作：\(rawAction)")
          return
        }
        // 「查看原图」「超分辨率」都是**视图状态**（逐页换图 + 重载），不是保存/分享那类动作：
        // 前者切档（会重新下载原图档），后者只把当前已加载的像素换成超分结果（零请求）。
        if action == .viewOriginal {
          self.showOriginal(at: index)
          return
        }
        if action == .superResolution {
          self.startSuperResolution(at: index)
          return
        }
        self.actions.perform(action: action, item: self.items[index])
      }
      imageCell.onLoadFailed = { [weak self] in self?.actions.showTransientFailure("图片加载失败") }
      imageCell.onDismissInteractionChange = { [weak self] interacting in
        self?.handleDismissInteraction(interacting)
      }
    }
    return cell
  }

  func photoBrowser(
    _ browser: JXPhotoBrowserViewController,
    willDisplay cell: JXPhotoBrowserAnyCell,
    at index: Int
  ) {
    guard let imageCell = cell as? TiebaPhotoBrowserImageCell,
          items.indices.contains(index) else { return }
    visibleCells[index] = TiebaPhotoBrowserCellBox(imageCell)
    imageCell.configure(
      item: displayItem(at: index),
      index: index,
      targetPixelSize: downsamplingPixelSize(for: browser),
      containerSize: browser.view.bounds.size,
      // 该页已算过超分就交内存图（URL 不变、零请求）；否则 nil = 正常走 Nuke。
      overrideImage: cachedSuperResolution(at: index)
    )
  }

  /// 该页实际要展示的项：手动「查看原图」的页换成原图档（其余页原样）。切档后
  /// canViewOriginal 变 false → 菜单里「查看原图」消失（与旧 JS 判据一致）。
  private func displayItem(at index: Int) -> TiebaPhotoItem {
    guard manualOriginalPages.contains(index) else { return items[index] }
    return items[index].showingOriginal()
  }

  /// 长按「查看原图」：记下该页改用原图档，然后整页重载（JXPhotoBrowser 的
  /// reloadData 保当前页与循环位置，会重新走 willDisplay → 用原图档配置）。
  private func showOriginal(at index: Int) {
    guard items.indices.contains(index), items[index].originUrl != nil,
          manualOriginalPages.insert(index).inserted else { return }
    // 换档后像素来源变了：已算好的超分结果（还有正在跑的那张）必须作废，否则会把
    // "省流档的超分图"顶在"原图档"上 —— 两档像素并不相同，用户会看到一张不属于该档的图。
    discardSuperResolution(at: index, cancelRunning: true)
    browser?.reloadData()
  }

  // MARK: 超分辨率（长按「超分辨率」）

  /// 对**当前这一页正在显示的那一档已加载像素**做 2× 超分：
  ///   · 输入 = cell 上已经上屏的像素（省流档就是省流档、原图档就是原图档），绝不按 originUrl 再下一遍；
  ///   · 4MP 上限按这一版的实际像素算（菜单已按同一判据置灰，这里是二次守卫）；
  ///   · 模型加载与推理都在 actor 执行体上（外面包 Task.detached(priority:.userInitiated)），不占主线程；
  ///   · **渐进式**：先算当前可见视口内的块，算完立刻换屏上的图（直接改 cell 的图，不重配 ⇒ 缩放/位移不跳），
  ///     其余区域后台补齐，每约 1/3 再发一张快照；
  ///   · 结果只进内存 LRU（key = 该档 URL + 变体 + 尺寸），关闭查看器即释放，不写盘、零网络请求。
  private func startSuperResolution(at index: Int) {
    guard items.indices.contains(index) else { return }
    guard superResolutionIndex == nil else { return }
    guard let cell = visibleCells[index]?.cell,
          let source = cell.superResolutionSource,
          TiebaSuperResolutionLimits.canUpscale(width: source.width, height: source.height) else {
      actions.showTransientFailure("这张图还在加载，或尺寸不适合超分")
      return
    }
    let key = superResolutionKey(for: index)
    if let cached = superResolutionCache[key] {
      // 命中缓存：同一张图（同一档 + 同一尺寸）第二次点不再跑模型。
      touchSuperResolution(key)
      cell.updateProgressiveImage(cached)
      actions.showSuccess("超分完成（缓存）")
      return
    }
    superResolutionIndex = index
    actions.showProgress(text: "加载模型…", progress: nil)
    // 可见视口 → 源图像素坐标（渐进式的"优先区"：这部分先算完就先清晰）。
    let priority = cell.visibleImageFraction.map { fraction in
      CGRect(
        x: fraction.minX * CGFloat(source.width),
        y: fraction.minY * CGFloat(source.height),
        width: fraction.width * CGFloat(source.width),
        height: fraction.height * CGFloat(source.height)
      )
    }
    let onPartial: @Sendable (CGImage, Int, Int) -> Void = { [weak self] image, done, total in
      Task { @MainActor in
        self?.applySuperResolutionPartial(index: index, key: key, image: image, done: done, total: total)
      }
    }
    let progress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
      Task { @MainActor in self?.updateSuperResolutionProgress(done: done, total: total, index: index) }
    }
    superResolutionTask = Task.detached(priority: .userInitiated) { [weak self] in
      do {
        let image = try await TiebaSuperResolutionEngine.shared.upscale(
          source,
          priority: priority,
          onPartial: onPartial,
          progress: progress
        )
        await self?.completeSuperResolution(index: index, key: key, image: image)
      } catch {
        await self?.failSuperResolution(index: index, error: error)
      }
    }
  }

  private func updateSuperResolutionProgress(done: Int, total: Int, index: Int) {
    guard superResolutionIndex == index, total > 0 else { return }
    actions.showProgress(text: "超分中 \(done)/\(total)", progress: Double(done) / Double(total))
  }

  /// 渐进式快照：立刻换屏上的图（不重配 ⇒ 缩放/位移不跳），并写进缓存供翻页回来复用。
  private func applySuperResolutionPartial(
    index: Int,
    key: SuperResolutionKey,
    image: CGImage,
    done: Int,
    total: Int
  ) {
    guard superResolutionIndex == index else { return }
    let ui = UIImage(cgImage: image)
    storeSuperResolution(ui, key: key)
    visibleCells[index]?.cell?.updateProgressiveImage(ui)
    actions.showProgress(
      text: total > 0 ? "超分中 \(done)/\(total)" : "超分中",
      progress: total > 0 ? Double(done) / Double(total) : nil
    )
  }

  private func completeSuperResolution(index: Int, key: SuperResolutionKey, image: CGImage) {
    guard superResolutionIndex == index else { return }
    superResolutionIndex = nil
    superResolutionTask = nil
    let ui = UIImage(cgImage: image)
    storeSuperResolution(ui, key: key)
    visibleCells[index]?.cell?.updateProgressiveImage(ui)
    actions.showSuccess("超分完成")
  }

  private func failSuperResolution(index: Int, error: Error) {
    guard superResolutionIndex == index else { return }
    superResolutionIndex = nil
    superResolutionTask = nil
    switch error {
    case TiebaSuperResolutionError.cancelled:
      actions.hideProgress()
    case TiebaSuperResolutionError.tooManyPixels:
      actions.showTransientFailure("图片太大，不超分")
    case TiebaSuperResolutionError.modelUnavailable:
      actions.showTransientFailure("超分模型不可用")
    default:
      actions.showTransientFailure("超分失败")
    }
    // 失败/取消都保持原图不动：缓存没写入，cell 上仍是原来那张（渐进式已显示的快照也来自同一张图）。
  }

  // MARK: 超分缓存（内存 LRU）

  /// key = 该档的 URL + 变体（省流/原图）+ 服务端声明的尺寸。
  /// 变体不同 ⇒ URL 不同 ⇒ 天然不会把省流档的超分图顶到原图档上。
  private struct SuperResolutionKey: Hashable {
    let url: String
    let isOriginalVariant: Bool
    let pixelWidth: Int
    let pixelHeight: Int
  }

  private static let superResolutionCacheLimit = 3

  private func superResolutionKey(for index: Int) -> SuperResolutionKey {
    let item = items[index]
    let isOriginal = manualOriginalPages.contains(index)
    return SuperResolutionKey(
      url: (isOriginal ? (item.originUrl ?? item.url) : item.url).absoluteString,
      isOriginalVariant: isOriginal,
      pixelWidth: Int(item.width.rounded()),
      pixelHeight: Int(item.height.rounded())
    )
  }

  private func cachedSuperResolution(at index: Int) -> UIImage? {
    let key = superResolutionKey(for: index)
    guard let image = superResolutionCache[key] else { return nil }
    touchSuperResolution(key)
    return image
  }

  private func storeSuperResolution(_ image: UIImage, key: SuperResolutionKey) {
    superResolutionCache[key] = image
    touchSuperResolution(key)
    while superResolutionRecency.count > Self.superResolutionCacheLimit {
      let evicted = superResolutionRecency.removeFirst()
      superResolutionCache[evicted] = nil
    }
  }

  private func touchSuperResolution(_ key: SuperResolutionKey) {
    superResolutionRecency.removeAll { $0 == key }
    superResolutionRecency.append(key)
  }

  /// 换档（查看原图）时取消正在跑的那张：像素来源已变，结果不再属于这一页。
  /// 缓存不用清（key 含变体，旧档的条目只会自然淘汰）。
  private func discardSuperResolution(at index: Int, cancelRunning: Bool) {
    if cancelRunning, superResolutionIndex == index {
      superResolutionTask?.cancel()
      superResolutionTask = nil
      superResolutionIndex = nil
      actions.hideProgress()
    }
  }

  func photoBrowser(
    _ browser: JXPhotoBrowserViewController,
    didEndDisplaying cell: JXPhotoBrowserAnyCell,
    at index: Int
  ) {
    (cell as? TiebaPhotoBrowserImageCell)?.cancelLoading()
  }

  /// Zoom 转场源视图：**转场当下**向宿主现算当前图的窗口矩形（翻页后 / 列表揭示
  /// 移位后都认最新几何）；算不到、且是初始页才退回安装时快照。
  ///
  /// ⚠️ 初始页原来恒用安装时矩形：揭示移位（展示后 0.35s 滚列表）没落定、或期间
  /// 列表又动过，大图就会飞回"原位置隔壁"再闪回真缩略图（真机实证）。
  /// 其余页算不到 → nil，框架降级 Fade（绝不能退回被点图的矩形：那会飞回错误的图）。
  func photoBrowser(_ browser: JXPhotoBrowserViewController, thumbnailViewAt index: Int) -> UIView? {
    guard let thumbnail = sourceThumbnailView else { return nil }
    if let container = thumbnail.superview,
       let rect = sourceFrameProvider?(index),
       rect.origin.x.isFinite, rect.origin.y.isFinite,
       rect.width.isFinite, rect.height.isFinite,
       rect.width >= 2, rect.height >= 2 {
      thumbnail.frame = container.convert(rect, from: nil)
      return thumbnail
    }
    guard index == initialIndex, let frame = sourceThumbnailInitialFrame else { return nil }
    thumbnail.frame = frame
    return thumbnail
  }

  /// 有意覆盖为"恒隐藏"：临时视图只是转场几何/图像载体，屏上真缩略图由原生
  /// 列表持有（Modal 底下本来就在，无需揭示）。默认实现会在转场时显隐该视图——
  /// 列表已滚动时会在错误位置露出重复缩略图。
  func photoBrowser(_ browser: JXPhotoBrowserViewController, setThumbnailHidden hidden: Bool, at index: Int) {
    sourceThumbnailView?.isHidden = true
  }

  // MARK: Chrome（顶栏）显隐

  private func toggleChrome() {
    setChromeVisible(!chromeVisible)
  }

  private func setChromeVisible(_ visible: Bool) {
    chromeVisible = visible
    chrome?.setVisible(visible, animated: true)
    // UIView.animate 的动画闭包归主 actor；本类不是 @MainActor（delegate 是
    // ObjC 协议，不能用 actor 隔离满足），但会话所有入口都在主线程——present
    // 内部切主（见文件头）、JXPhotoBrowser delegate / 手势回调都在主线程。
    // 与 ActionController.pill（:685）同一依据：assumeIsolated 只是把这条既有
    // 契约显式化，同步执行，没有真正的跨域。
    MainActor.assumeIsolated {
      // 与顶栏同一条动作：顶栏走可中断转场，页码点也要从当前状态续跑——否则连点时
      // 每次从 0/1 重头来（用户口径「连点顿挫」）。
      TiebaAnimation.animate(duration: 0.2, options: [.beginFromCurrentState]) {
        self.indicator?.alpha = visible ? 1 : 0
      }
    }
    // 旧查看器：单击切换后不排自动收起；手势结束后才排（见 handleDismissInteraction）。
    if !visible {
      chromeAutoHideWorkItem?.cancel()
      chromeAutoHideWorkItem = nil
    }
  }

  private func handleDismissInteraction(_ interacting: Bool) {
    if interacting {
      chromeAutoHideWorkItem?.cancel()
      chromeAutoHideWorkItem = nil
      chrome?.setVisible(false, animated: true)
      MainActor.assumeIsolated {
        // [按上游归位] 0.15 → TiebaAnimationDuration.fastFade（上游 0.15 档，值逐字不变）。
        // 语义正好对得上："手指开始拖动 → 页码点让位"，就是上游那档"手指离开后的余韵"。
        TiebaAnimation.animate(duration: TiebaAnimationDuration.fastFade) {
          self.indicator?.alpha = 0
        }
      }
      return
    }
    // 回弹（未达关闭阈值）：恢复用户设定的显隐态，并按旧查看器 2.6s 后自动收起。
    chrome?.setVisible(chromeVisible, animated: true)
    MainActor.assumeIsolated {
      TiebaAnimation.animate(duration: 0.2) {
        self.indicator?.alpha = self.chromeVisible ? 1 : 0
      }
    }
    if chromeVisible { scheduleChromeAutoHide() }
  }

  private func scheduleChromeAutoHide() {
    chromeAutoHideWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.chromeVisible else { return }
      self.setChromeVisible(false)
    }
    chromeAutoHideWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: item)
  }

  private func applySafeArea(_ insets: UIEdgeInsets) {
    guard insets != lastSafeAreaInsets else { return }
    lastSafeAreaInsets = insets
    // 页码点位置于安全区之上（旧底部缩略条 paddingBottom = max(insets.bottom,16)）。
    indicator?.position = .bottom(padding: max(insets.bottom, 16) + 8)
    actions.updatePillBottomInset(insets.bottom)
    if let browser, let indicator {
      // position 变更走 reloadData 应用（JXPageIndicatorOverlay.swift:90-100）。
      indicator.reloadData(numberOfItems: items.count, pageIndex: browser.pageIndex)
    }
  }

  // MARK: 工具

  private func downsamplingPixelSize(for browser: JXPhotoBrowserViewController) -> CGSize {
    let size = browser.view.bounds.size
    let scale = TiebaPhotoBrowserSession.displayScale(for: browser.view)
    return CGSize(width: max(size.width, 1) * scale, height: max(size.height, 1) * scale)
  }
}

// MARK: - 业务动作（保存 / 保存原图 / 分享，全原生）

/// 取代旧 JS 链路（src/services/media.ts saveImageToGallery / shareFile）：
/// - 保存：Nuke 数据层下载原始字节 → PHPhotoLibrary 写相册（GIF 写原始 GIF
///   数据，相册里仍是动图）；写库前后底部胶囊显示进度/结果。
/// - 分享：下载 → 临时文件 → UIActivityViewController（iPad 走 popover 锚点）。
/// - 失败/权限：UIAlertController，文案与旧查看器一致
///   （"权限不足"/"请在设置中允许访问相册以保存图片"、"保存失败"）。
/// @MainActor：方法全在改 UIKit 状态（pill/presenter/相册写入回调），且被
/// Nuke 的 @MainActor @Sendable 回调捕获 self；会话（唯一构造方，见 :701）本身
/// 就在主 actor 上，跟着收敛到主 actor 后闭包捕获不再跨域。
