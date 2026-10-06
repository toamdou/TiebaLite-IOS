// 从"正在滚动的系统手势"手里接管（移植自上游 MinimizedContainer.swift:732-735 的三行）。
//
//   scrollView.isScrollEnabled = false
//   panGestureRecognizer.isEnabled = false; panGestureRecognizer.isEnabled = true
//   setContentOffset(contentOffset, animated: false)
//
// 先取消当前识别、再让它能被重新识别，然后把位置钉在当前值 —— 于是"我接管了"和
// "系统还在滑"不会同时成立。
//
// ⚠️ 隐式契约：翻覆 `isEnabled` 依赖 UIKit「禁用会取消进行中的识别、重新启用后仍可识别」
// 这一行为（非文档承诺，但自 iOS 3 起稳定）。失效时的退化为"手势没被取消"，不会崩，
// 只是接管的那一下还残留惯性。本仓没有替代手段：UIScrollView 不暴露"取消当前手势"的公开 API。
import UIKit

@MainActor
enum TiebaScrollGestureHandoff {
  /// 取消 scrollView 上正在进行的手势/惯性，并把内容位置钉在当前值。
  /// 与上游不同的是**立刻恢复可滚动**：本仓是"换页/接管一瞬间"，不是上游那种
  /// "收起来期间整段禁用"。
  static func cancelInFlightScroll(_ scrollView: UIScrollView?) {
    guard let scrollView, scrollView.isScrollEnabled else { return }
    let offset = scrollView.contentOffset
    scrollView.isScrollEnabled = false
    let pan = scrollView.panGestureRecognizer
    pan.isEnabled = false
    pan.isEnabled = true
    scrollView.setContentOffset(offset, animated: false)
    scrollView.isScrollEnabled = true
  }
}
