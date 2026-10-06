// 系统分享面板（UIActivityViewController）——替代 expo-sharing，同时收编大图
// 查看器原有的分享呈现代码（此前是 TiebaPhotoBrowserActionController 里的
// private presentShareSheet）。
//
// 为什么必须是共享的一份：查看器（下载字节 → 临时文件 → 分享）与 JS 门面
//（media.ts shareFile / logs.tsx 导出日志，文件已在缓存目录）是同一个系统
// 面板的两种来料，差异只在"谁来准备文件"和"分享结束后删不删"。present 的
// 三条硬约束完全一样，复制第二份就是下一次"改了一处忘了另一处"：
//   1. 宿主 VC：查看器用浏览器自身，JS 侧用顶层 VC（TiebaTopViewController）；
//   2. iPad 必须给 popover 锚点（sourceView/sourceRect），否则 present 崩溃；
//   3. completion 在"面板真正关闭"后回调——JS 侧 media.ts 是在 await 返回后
//      删临时文件，提前 resolve 会让文件在面板还开着时消失（旧包 expo-sharing
//      同样是 completion 回调里 resolve，这是必须保住的行为）。
//
// 旧包 iOS 侧只消费 dialogTitle（落到 UIActivityViewController.title），
// mimeType/UTI 是 Android/Web 参数、从未被读；本实现保持同一取舍。
//
// 文件校验按旧包语义：只受理可读的本地文件（expo-sharing 的
// FileSystemUtilities.isReadableFile 对 file:// 就是查 isReadableFile，
// 失败抛 FilePermissionException）。本仓调用点全是 expo-file-system 落盘的
// file://，非 file 一律报错，不把远程 URL 塞进分享面板（那会让面板先下载、
// 失败时机不可预期）。
import PDFKit
import UIKit
import LinkPresentation

/// 跨桥抛错用的最小错误类型（与 TiebaCookieError 同形）：errorDescription 会成为
/// JS 侧 Error.message，文案与旧包 expo-sharing 的 reject 保持同义。
struct TiebaShareError: LocalizedError {
  let message: String

  var errorDescription: String? { message }
}

/// 分享 PDF 时给面板补一个「首页预览」的 item source。
///
/// [接线 2026-10-05] 只包一层 `LPLinkMetadata`（面板头部的标题 + 图标），**分享内容本身一个字节没变**：
/// `activityViewControllerPlaceholderItem` 与 `itemForActivityType` 返回的都是原来那个 file URL。
/// 非 PDF 文件根本不构造这个对象（present 里直接走原来的 `activityItems: [fileURL]` 路径）。
///
/// 为什么值得做：系统对 PDF 的默认头图是一张通用文档图标，用户在点分享的那一刻无法确认
/// 自己选的是哪一份 PDF；首页缩略图直接给答案。
private final class TiebaPdfActivityItemSource: NSObject, UIActivityItemSource {
  private let url: URL
  private let preview: UIImage

  init(url: URL, preview: UIImage) {
    self.url = url
    self.preview = preview
  }

  func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any {
    self.url
  }

  func activityViewController(
    _ activityViewController: UIActivityViewController,
    itemForActivityType activityType: UIActivity.ActivityType?
  ) -> Any? {
    // 分享的还是原文件：自定义 item source 不允许顺带改变分享载荷。
    self.url
  }

  func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
    let metadata = LPLinkMetadata()
    metadata.title = self.url.lastPathComponent
    metadata.iconProvider = NSItemProvider(object: self.preview)
    metadata.imageProvider = NSItemProvider(object: self.preview)
    return metadata
  }
}

@MainActor
enum TiebaShareSheet {
  /// 分享纯文本（帖子链接/吧链接/主页链接）。
  ///
  /// 收编原先散在 8 个页面里的同一段：构造 UIActivityViewController + iPad
  /// popover 锚点（`(midX, maxY - 44)`、无箭头）+ present。那段连锚点数值都是
  /// 逐字复制的，改一处必漏七处。
  /// - Returns: false = 宿主不在窗口上（调用方自己决定提示文案）。
  @discardableResult
  static func present(
    text: String,
    dialogTitle: String? = nil,
    from presenter: UIViewController,
    sourceRect: CGRect? = nil
  ) -> Bool {
    guard presenter.view.tiebaIsOnScreen, !text.isEmpty else { return false }
    let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
    controller.title = dialogTitle
    applyPopover(to: controller, presenter: presenter, sourceRect: sourceRect)
    presenter.present(controller, animated: true)
    return true
  }

  /// 呈现系统分享面板。
  /// - Parameters:
  ///   - fileURL: 本地文件 URL（分享的就是这个文件本身）。
  ///   - dialogTitle: 面板标题（旧包同名选项）。
  ///   - presenter: 呈现宿主。查看器传浏览器自身，JS 侧传顶层 VC。
  ///   - sourceRect: iPad popover 锚点；nil = 底部居中（分享面板习惯）。
  ///   - completion: 面板关闭后回调（成功/取消/失败都回调；旧包的注释专门
  ///     记过一版只在两个分支 resolve 的 bug——用户选了活动又在其后续弹窗里
  ///     取消时 promise 泄漏，所以这里无条件回调）。
  /// - Returns: false = 宿主不在窗口上（调用方自己决定提示文案，这里不弹 UI）。
  @discardableResult
  static func present(
    fileURL: URL,
    dialogTitle: String? = nil,
    from presenter: UIViewController,
    sourceRect: CGRect? = nil,
    completion: (() -> Void)? = nil
  ) -> Bool {
    guard presenter.view.tiebaIsOnScreen else { return false }
    // [接线] 仅 PDF 走带首页预览的 item source；其它文件 activityItems 就是 [fileURL]，与接线前逐字一致。
    let activityItems: [Any]
    if let preview = self.pdfPreviewIcon(for: fileURL) {
      activityItems = [TiebaPdfActivityItemSource(url: fileURL, preview: preview)]
    } else {
      activityItems = [fileURL]
    }
    let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    controller.title = dialogTitle
    controller.completionWithItemsHandler = { _, _, _, _ in completion?() }
    applyPopover(to: controller, presenter: presenter, sourceRect: sourceRect)
    presenter.present(controller, animated: true)
    return true
  }

  /// PDF 首页预览图标（分享面板头部用）。非 PDF 一律返回 nil —— 这条路径只服务 PDF。
  ///
  /// [接线 2026-10-05] 这一步串起了三件移植件，且全部作用在**新建位图**上，不碰任何既有显示路径：
  ///   1. PDFKit 的 PDFPage.thumbnail(of:for:) 出整页可见的首页图（系统件）；
  ///   2. `TiebaBitmapContext`（UI/Drawing/TiebaDrawingSupport.swift）离屏合成方框 + 白底 + 居中；
  ///   3. `TiebaImageCorners`（UI/Drawing/TiebaImageCorners.swift）切圆角 —— 用移植件的四角几何，
  ///      而不是再手写一条 UIBezierPath + mask。
  /// 尺寸用 `CGSize.fitted`（UI/Components/TiebaUIKitUtils.swift）算等比内接框。
  ///
  /// 成本：读一次 PDF 头 + 渲染 320pt 首页 + 缩小到 96pt 图标。只在用户点「分享」且文件是 PDF 时发生，
  /// 不是滚动路径；预览失败就返回 nil，分享面板退化成原来的通用文档图标（不会失败）。
  private static func pdfPreviewIcon(for fileURL: URL) -> UIImage? {
    guard fileURL.pathExtension.lowercased() == "pdf" else { return nil }
    let box: CGFloat = 96.0
    let boxSize = CGSize(width: box, height: box)
    // 判据（该用系统却自绘）：首页预览直接用 PDFKit —— PDFDocument + PDFPage.thumbnail(of:for:)。
    // 系统件自己处理 mediaBox / 页面旋转 / 裁剪 / 白底，比原来 CGPDFDocument + 离屏上下文
    // 手绘 320pt 页面再缩（UI/Drawing/TiebaPdfThumbnail.swift，已删）短得多，且旋转页现在是正的。
    guard let document = PDFDocument(url: fileURL), let page = document.page(at: 0) else { return nil }
    let pageBounds = page.bounds(for: .mediaBox)
    guard pageBounds.width > 0, pageBounds.height > 0 else { return nil }
    // 按页面宽高比要缩略图：thumbnail 会把整页等比画进给定尺寸，不加边也不裁角。
    let fitted = pageBounds.size.fitted(boxSize)
    let pageImage = page.thumbnail(of: fitted, for: .mediaBox)
    // scale 2：图标最多显示到 ~192px，2x 足够且比默认屏幕 scale（3x）省 55% 位图。
    guard let bitmap = TiebaBitmapContext(size: boxSize, scale: 2.0) else { return nil }
    bitmap.withContext { context in
      UIGraphicsPushContext(context)
      defer { UIGraphicsPopContext() }
      // 白底：PDF 页面本身没有背景，铺白才能在任何外观下面板里看清。
      UIColor.white.setFill()
      context.fill(CGRect(origin: .zero, size: boxSize))
      pageImage.draw(in: CGRect(
        x: (box - fitted.width) / 2.0,
        y: (box - fitted.height) / 2.0,
        width: fitted.width,
        height: fitted.height
      ))
    }

    let corners = TiebaImageCorners(radius: 12.0)
    let arguments = TiebaTransformImageArguments(
      corners: corners,
      imageSize: fitted,
      boundingSize: boxSize,
      intrinsicInsets: UIEdgeInsets()
    )
    corners.apply(to: bitmap, arguments: arguments)
    return bitmap.generateImage()
  }

  /// iPad 锚点（两份 present 共用；无箭头居中展开，避免同一 App 两种面板形态）。
  private static func applyPopover(
    to controller: UIActivityViewController,
    presenter: UIViewController,
    sourceRect: CGRect?
  ) {
    guard let popover = controller.popoverPresentationController else { return }
    // iPad：必须给锚点，否则 present 崩溃；无箭头居中展开（查看器既有形态）。
    popover.sourceView = presenter.view
    popover.sourceRect = sourceRect ?? CGRect(
      x: presenter.view.bounds.midX,
      y: presenter.view.bounds.maxY - 44,
      width: 1,
      height: 1
    )
    popover.permittedArrowDirections = []
  }

  // MARK: - 预热（把系统侧首次构建面板的成本挪出关键路径）

  /// 是否已预热（幂等闸：只有"系统还没查过分享扩展"的首次预热有意义）。
  private static var prewarmed = false

  /// 预热系统分享面板。**为什么需要**：`UIActivityViewController` 的首次构建不等同
  /// 于普通 VC——它要等系统把可用的分享扩展查出来（进程外 sharesheet 服务 +
  /// pluginkit 扩展发现 + 图标解码），这笔成本正落在「用户点分享 → 面板出现」之间，
  /// 是本仓改不动的那一段（系统件）；之后同一份列表由系统缓存。
  /// 做法：建一个同形态的面板并让它 `loadViewIfNeeded()`——**不挂视图树、不 present**，
  /// 随即释放，只把系统那次查询提前到用户还在看菜单 / 等转场的时候。
  /// 幂等且不阻塞调用方：只置闸，构建推到下一拍主队列（调用点都在触摸回调里）。
  static func prewarm() {
    guard !prewarmed else { return }
    prewarmed = true
    Task { @MainActor in
      let controller = UIActivityViewController(activityItems: ["tieba"], applicationActivities: nil)
      controller.loadViewIfNeeded()
    }
  }

}
