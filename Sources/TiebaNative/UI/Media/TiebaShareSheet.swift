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
import UIKit

/// 跨桥抛错用的最小错误类型（与 TiebaCookieError 同形）：errorDescription 会成为
/// JS 侧 Error.message，文案与旧包 expo-sharing 的 reject 保持同义。
struct TiebaShareError: LocalizedError {
  let message: String

  var errorDescription: String? { message }
}

@MainActor
enum TiebaShareSheet {
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
    let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
    controller.title = dialogTitle
    controller.completionWithItemsHandler = { _, _, _, _ in completion?() }
    if let popover = controller.popoverPresentationController {
      // iPad：必须给锚点，否则 present 崩溃；无箭头居中展开（查看器既有形态）。
      // 旧包把锚点放在 (midX, maxY) 且不限制箭头方向，这里统一成查看器那套，
      // 避免同一 App 两处分享面板形态不同。
      popover.sourceView = presenter.view
      popover.sourceRect = sourceRect ?? CGRect(
        x: presenter.view.bounds.midX,
        y: presenter.view.bounds.maxY - 44,
        width: 1,
        height: 1
      )
      popover.permittedArrowDirections = []
    }
    presenter.present(controller, animated: true)
    return true
  }

  /// JS 门面入口（TiebaNative.sharePresent）：文件已由 JS 侧落盘，直接分享。
  /// 宿主缺失/文件不可读时抛错——没有静默返回：调用方 await 返回后要清理临时
  /// 文件，"面板没出现却 resolve"会让失败变成无反馈。
  static func presentFromTop(fileUri: String, dialogTitle: String?) async throws {
    guard let url = URL(string: fileUri), url.isFileURL else {
      throw TiebaShareError(message: "分享只受理本地文件 URL（file://）：\(fileUri)")
    }
    guard FileManager.default.isReadableFile(atPath: url.path) else {
      throw TiebaShareError(message: "文件不存在或不可读：\(url.lastPathComponent)")
    }
    guard let presenter = TiebaTopViewController.find() else {
      throw TiebaShareError(message: "没有可用的宿主视图控制器")
    }
    // 已有面板（分享面板/菜单/Alert）时不再叠加：UIKit 会拒绝这次 present，
    // completion 永不回调 → JS 侧 await 永挂、临时文件不清理。显式失败，
    // 让调用方走自己的错误分支（旧包 expo-sharing 没有这道闸，会静默挂住）。
    guard presenter.presentedViewController == nil else {
      throw TiebaShareError(message: "已有其它面板在呈现，无法打开分享面板")
    }
    // 面板关闭前不返回：completion 在系统回调里 resume（成功/取消/失败都调）。
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      let didPresent = present(fileURL: url, dialogTitle: dialogTitle, from: presenter) {
        continuation.resume()
      }
      if !didPresent {
        continuation.resume(throwing: TiebaShareError(message: "宿主视图不在窗口上，无法呈现分享面板"))
      }
    }
  }
}
