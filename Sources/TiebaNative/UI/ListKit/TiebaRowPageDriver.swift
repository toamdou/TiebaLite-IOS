// ============================================================
// TiebaLite — 行页发布驱动（TiebaRowPageDriver）
//
// 通用列表页共用的「造行 → 后台整页测量 → 回主线程换页」流程：publish 在主线程
// 取行，Task.detached 跑 TiebaKindRowPages.prepareBlocking，回主后只在 pageKey
// 仍是本次发布的页时才 setPage——旧页测量后到不得覆盖新页（唯一竞态修复点）。
// ============================================================

import Foundation

@MainActor
public final class TiebaRowPageDriver {
  private let list: TiebaKindListContentView
  private let keyPrefix: String
  private var pageSeq = 0
  private var lastWidth: CGFloat = 0
  /// 上次的造行闭包：宽度变化（旋转/分屏）时用它以同页键重推。
  /// 调用方必须传 `[weak self]` 闭包，否则 page → driver → 闭包 → page 成环。
  private var lastMakeRows: (() -> [[String: Any]])?

  /// 当前页键（fresh 发布时 = "\(keyPrefix)-\(pageSeq)"；未发布 = ""）。
  public private(set) var pageKey = ""

  public init(list: TiebaKindListContentView, keyPrefix: String) {
    self.list = list
    self.keyPrefix = keyPrefix
  }

  /// 宿主 viewDidLayoutSubviews 调用。宽度量化后与上次不同才重推（同页键）：
  /// 首次拿到宽度时把 publish 早期暂存的请求补发。
  public func updateWidth(_ width: CGFloat) {
    let quantized = TiebaLayout.quantize(width)
    guard quantized != lastWidth else { return }
    lastWidth = quantized
    guard !pageKey.isEmpty, let makeRows = lastMakeRows else { return }
    publish(fresh: false, makeRows: makeRows)
  }

  /// 发布整页：fresh=true 换页键（数据集合变了），false = 同页重推（展开态/
  /// 回填/换色，保留滚动位置）。无宽度时先记 pending，等 updateWidth 补发。
  /// makeRows 在宽度变化时会被再次调用，因此是 @escaping；调用方用 `[weak self]`
  /// 闭包，避免 page → driver → 闭包 → page 的环。
  public func publish(fresh: Bool, makeRows: @escaping () -> [[String: Any]]) {
    if fresh {
      pageSeq += 1
      pageKey = "\(keyPrefix)-\(pageSeq)"
    }
    guard !pageKey.isEmpty else { return }
    lastMakeRows = makeRows
    guard lastWidth > 0 else { return }   // 宽度未就位：updateWidth 会用同一闭包补发
    let key = pageKey
    let width = lastWidth
    let box = RowsBox(rows: makeRows())
    Task { @MainActor [weak self] in
      await Task.detached(priority: .userInitiated) {
        TiebaKindRowPages.shared.prepareBlocking(
          pageKey: key,
          rows: box.rows,
          containerWidth: width
        )
      }.value
      guard let self, self.pageKey == key else { return }
      self.list.setPage(pageKey: key)
    }
  }

  private struct RowsBox: @unchecked Sendable {
    let rows: [[String: Any]]
  }
}
