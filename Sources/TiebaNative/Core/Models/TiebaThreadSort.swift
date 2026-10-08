import UIKit
import Nuke

/// 帖子页回复排序。取值直接是 `pb/page` 的 `r`：服务端在响应里就列出这三档
///（pb_sort_info = 热门(2)/正序(0)/倒序(1)，实测 2026-09-21）。
public enum TiebaThreadSort: Int, CaseIterable, Sendable {
  case hot = 2
  case asc = 0
  case desc = 1

  var title: String {
    switch self {
    case .hot: return "热门"
    case .asc: return "正序"
    case .desc: return "倒序"
    }
  }
}
