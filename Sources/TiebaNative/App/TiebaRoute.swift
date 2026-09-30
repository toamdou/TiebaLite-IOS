// 类型化路由：一个 case = 一次跳转，参数是领域值（Int/Bool/String?）。
// 替掉原「调用点拼 path 字符串 → [String: String] 字典 → 再从字符串解回标量」。
//
// ⚠️ `name` 必须与 TiebaRouteTable.entries 的键逐字一致：标题 / 呈现方式 /
// 是否 tab 根屏都按它查表（那两处是唯一的对应关系，改 case 要同步改键）。
// `signature` 只用于连点去重，不参与页面构造（构造只在 TiebaNativeRouteTable）。

public enum TiebaRoute: Equatable, Hashable, Sendable {
  /// 找不到页面（深链解析失败：path = 原样未解析的深链路径，仅进日志/去重）。
  case notFound(path: String)

  // ── tab 根屏（不入栈，navigate 只切 tab）──
  case index
  case explore
  /// 消息根屏；initialTab = 深链 tiebalite://notifications/N 的目标分段。
  case notifications(initialTab: Int?)
  case profile

  // ── 帖子 / 楼中楼 / 帖子更多 ──
  case thread(id: String, postId: String? = nil, seeLz: Bool = false, fromFavorites: Bool = false)
  /// floor = nil 表示楼层未知（标题显示「第?楼」，首包到达后由 floorPost.floor 补）。
  case subposts(
    threadId: String,
    postId: String,
    forumId: String,
    floor: Int?,
    threadAuthorId: String,
    forumName: String,
    threadTitle: String
  )
  case threadMore(id: String, canDelete: Bool, seeLz: Bool, sort: TiebaThreadSort)

  // ── 吧 ──
  case forum(name: String, forumId: String = "")
  case forumDetail(name: String, forumId: String = "")
  case forumRules(name: String, forumId: String = "")
  case forumBawu(name: String, forumId: String = "")
  case forumMembers(name: String, forumId: String = "")
  case forumSearch(name: String, forumId: String = "")

  // ── 搜索 / 话题 / 用户 / 记录 ──
  case search(keyword: String = "")
  case topic(id: String, name: String)
  case user(uid: String, tab: String? = nil)
  case history(tab: String? = nil)
  case threadstore

  // ── 浏览器 / 登录 ──
  case webview(url: String, title: String)
  case login

  // ── 设置群 ──
  case settings
  case settingsTheme
  case settingsHabit
  case settingsHaptics
  case settingsImage
  case settingsOKSign
  case settingsMore
  case settingsAbout
  case account
  case editProfile
  case blockSettings

  /// 路由表键（TiebaRouteTable.entries 的 name）：查标题/呈现方式/tab 序号用。
  public var name: String {
    switch self {
    case .notFound: return "+not-found"
    case .index: return "index"
    case .explore: return "explore"
    case .notifications: return "notifications"
    case .profile: return "profile"
    case .thread: return "thread/[id]"
    case .subposts: return "thread/[id]/subposts"
    case .threadMore: return "thread/[id]/more"
    case .forum: return "forum/[name]"
    case .forumDetail: return "forum/[name]/detail"
    case .forumRules: return "forum/[name]/rules"
    case .forumBawu: return "forum/[name]/bawu"
    case .forumMembers: return "forum/[name]/members"
    case .forumSearch: return "forum/[name]/search"
    case .search: return "search/index"
    case .topic: return "topic/[id]"
    case .user: return "user/[uid]"
    case .history: return "history"
    case .threadstore: return "threadstore"
    case .webview: return "webview"
    case .login: return "login"
    case .settings: return "settings/index"
    case .settingsTheme: return "settings/theme"
    case .settingsHabit: return "settings/habit"
    case .settingsHaptics: return "settings/haptics"
    case .settingsImage: return "settings/image"
    case .settingsOKSign: return "settings/oksign"
    case .settingsMore: return "settings/more"
    case .settingsAbout: return "settings/about"
    case .account: return "settings/account"
    case .editProfile: return "settings/edit-profile"
    case .blockSettings: return "settings/block"
    }
  }

  /// tab 根屏的深链分段：nil = 无参数投递（仅消息根屏消费）。
  var initialTab: Int? {
    guard case .notifications(let initialTab) = self else { return nil }
    return initialTab
  }

  /// 连点去重签名：等价旧的「name + 排序后的参数」。动态段照旧走
  /// TiebaRoutePath.segment：含 ? & / 的吧名不与别的路由串撞车。
  var signature: String {
    switch self {
    case .notFound(let path): return path.isEmpty ? "/+not-found" : path
    case .index: return "/index"
    case .explore: return "/explore"
    case .notifications(let initialTab):
      return "/notifications" + Self.query([("initialTab", initialTab.map(String.init))])
    case .profile: return "/profile"
    case .thread(let id, let postId, let seeLz, let fromFavorites):
      return "/thread/\(Self.segment(id))" + Self.query([
        ("postId", postId),
        ("seeLz", seeLz ? "1" : nil),
        ("fromFavorites", fromFavorites ? "1" : nil),
      ])
    case .subposts(let threadId, let postId, let forumId, let floor, let threadAuthorId, let forumName, let threadTitle):
      return "/thread/\(Self.segment(threadId))/subposts" + Self.query([
        ("postId", postId),
        ("forumId", forumId),
        ("floor", floor.map(String.init)),
        ("threadAuthorId", threadAuthorId),
        ("forumName", forumName),
        ("threadTitle", threadTitle),
      ])
    case .threadMore(let id, let canDelete, let seeLz, let sort):
      // 0/1 都进签名：与旧参数的形状一致（回调式 sheet 只有这几项决定内容）。
      return "/thread/\(Self.segment(id))/more" + Self.query([
        ("canDelete", canDelete ? "1" : "0"),
        ("seeLz", seeLz ? "1" : "0"),
        ("sort", String(sort.rawValue)),
      ])
    case .forum(let name, let forumId):
      return "/forum/\(Self.segment(name))" + Self.query([("forumId", forumId)])
    case .forumDetail(let name, let forumId):
      return "/forum/\(Self.segment(name))/detail" + Self.query([("forumId", forumId)])
    case .forumRules(let name, let forumId):
      return "/forum/\(Self.segment(name))/rules" + Self.query([("forumId", forumId)])
    case .forumBawu(let name, let forumId):
      return "/forum/\(Self.segment(name))/bawu" + Self.query([("forumId", forumId)])
    case .forumMembers(let name, let forumId):
      return "/forum/\(Self.segment(name))/members" + Self.query([("forumId", forumId)])
    case .forumSearch(let name, let forumId):
      return "/forum/\(Self.segment(name))/search" + Self.query([("forumId", forumId)])
    case .search(let keyword):
      return "/search/index" + Self.query([("q", keyword.isEmpty ? nil : keyword)])
    case .topic(let id, let name):
      return "/topic/\(Self.segment(id))" + Self.query([("name", name)])
    case .user(let uid, let tab):
      return "/user/\(Self.segment(uid))" + Self.query([("tab", tab)])
    case .history(let tab):
      return "/history" + Self.query([("tab", tab)])
    case .threadstore: return "/threadstore"
    case .webview(let url, let title):
      return "/webview" + Self.query([("title", title.isEmpty ? nil : title), ("url", url.isEmpty ? nil : url)])
    case .login: return "/login"
    case .settings: return "/settings/index"
    case .settingsTheme: return "/settings/theme"
    case .settingsHabit: return "/settings/habit"
    case .settingsHaptics: return "/settings/haptics"
    case .settingsImage: return "/settings/image"
    case .settingsOKSign: return "/settings/oksign"
    case .settingsMore: return "/settings/more"
    case .settingsAbout: return "/settings/about"
    case .account: return "/settings/account"
    case .editProfile: return "/settings/edit-profile"
    case .blockSettings: return "/settings/block"
    }
  }

  /// 查询串：nil 的值整对丢弃（false/空串在类型化世界里与「没传」等价）。
  private static func query(_ pairs: [(String, String?)]) -> String {
    let parts = pairs.compactMap { key, value in
      value.map { "\(key)=\(TiebaRoutePath.segment($0))" }
    }.sorted()
    return parts.isEmpty ? "" : "?" + parts.joined(separator: "&")
  }

  private static func segment(_ raw: String) -> String {
    TiebaRoutePath.segment(raw)
  }
}
