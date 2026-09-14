import UIKit

// 原生路由表（替 expo-router 的文件路由）。
//
// 名字仍是「文件路径即路由名」——"thread/[id]"、"settings/about"，方括号段是
// 参数占位。保持这个形状的理由：JS 侧 200+ 文件的 href 写法（'/thread/123'、
// '/forum/某个吧'）与 params 形状完全不用改，迁移期只剩 import 路径一处改动。
//
// ⚠️ 这张表是**唯一**一份：路径解析、标题、呈现方式、是否 tab 根屏全部在此
// 决定，JS 侧不再复制。JS 只说「去 /thread/123」，原生自己解析成
// (name: "thread/[id]", params: {id: "123"})。两处各存一张表必然会漂移。

/// 一个具体路由实例：名字 + 参数。
/// Sendable：TiebaNavigator.makeHost 要把 route 传进主 actor 构造宿主 VC
/// （UIViewController init 是 @MainActor）；纯值类型（String + [String: String]），
/// 显式声明后这个既有传递不再被判成 sending 'route'（public 类型不隐式推断）。
public struct TiebaRoute: Equatable, Hashable, Sendable {
  public var name: String
  public var params: [String: String]

  public init(name: String, params: [String: String] = [:]) {
    self.name = name
    self.params = params
  }

  /// 还原成可读路径（'/thread/123'）。仅用于日志与 JS 侧 usePathname()。
  public var path: String {
    var out = "/"
    let segs = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    var parts: [String] = []
    for seg in segs {
      if seg.hasPrefix("["), seg.hasSuffix("]") {
        let key = String(seg.dropFirst().dropLast())
        parts.append(params[key] ?? "")
      } else {
        parts.append(seg)
      }
    }
    out += parts.joined(separator: "/")
    // 查询串按 key 排序输出，保证同一 params 每次得到同一字符串（usePathname
    // 进了 JS 的依赖数组，顺序不定会让它每次渲染都"变"）。
    let extra = params.filter { key, _ in
      !segs.contains { $0 == "[\(key)]" }
    }
    if !extra.isEmpty {
      let q = extra.keys.sorted().map { "\($0)=\(extra[$0] ?? "")" }.joined(separator: "&")
      out += "?" + q
    }
    return out
  }
}

/// 呈现方式。login 与 thread/[id]/more 在 expo-router 时代是 formSheet，
/// 其余一律压栈。
public enum TiebaRoutePresentation: Equatable {
  case push
  case sheet(detents: [CGFloat], grabber: Bool, cornerRadius: CGFloat)
}

/// 导航栏形态。
public enum TiebaRouteChrome: Equatable {
  /// 系统栏：标题 + 返回箭头（minimal，不带上一屏标题文字）。
  case standard
  /// 无导航栏：tab 根屏、webview、thread/[id]/more（自带把手与标题）。
  case hidden
}

private enum TiebaRouteSegment: Equatable {
  case literal(String)
  case param(String)
}

/// 路由表的一行。
public struct TiebaRouteEntry {
  public let name: String
  public let title: String
  public let presentation: TiebaRoutePresentation
  public let chrome: TiebaRouteChrome
  /// 非空 = 该路由是第 N 个 tab 的根屏（根屏不入栈，只切 tab）。
  public let tabIndex: Int?
  fileprivate let segments: [TiebaRouteSegment]
}

public enum TiebaRouteTable {
  /// tab 根屏（顺序 = 底栏顺序，与 NativeTabs.Trigger 的声明顺序一致）。
  nonisolated(unsafe) public static let tabNames = ["index", "explore", "notifications", "profile"]

  /// 路由表本体。nonisolated(unsafe)：**静态初始化时一次性建好，此后只读**，
  /// 没有任何注册/追加路径（要加路由只能改这个字面量）。三个可变全局都靠
  /// 这条不变量成立——将来若真的要运行时注册路由，这里必须换成带锁的容器，
  /// 而不是继续往这个数组里 append。
  nonisolated(unsafe) public static let entries: [TiebaRouteEntry] = [
    // ── tab 根屏 ──（标题由各屏自绘，chrome = .hidden）
    entry("index", title: "", chrome: .hidden, tabIndex: 0),
    entry("explore", title: "", chrome: .hidden, tabIndex: 1),
    entry("notifications", title: "", chrome: .hidden, tabIndex: 2),
    entry("profile", title: "", chrome: .hidden, tabIndex: 3),

    // ── 压栈页 ──
    entry("forum/[name]", title: ""),
    entry("forum/[name]/detail", title: "吧详情"),
    entry("forum/[name]/bawu", title: "吧务团队"),
    entry("forum/[name]/members", title: "吧成员"),
    entry("forum/[name]/rules", title: "吧规"),
    entry("forum/[name]/search", title: "吧内搜索"),
    entry("thread/[id]", title: ""),
    entry("thread/[id]/subposts", title: "楼中楼"),
    entry("search/index", title: "搜索"),
    entry("user/[uid]", title: ""),
    entry("history", title: "浏览记录"),
    entry("threadstore", title: "我的收藏"),
    entry("webview", title: "", chrome: .hidden),
    entry("topic/[id]", title: "话题"),
    entry("settings/index", title: "设置"),
    entry("settings/theme", title: "个性化"),
    entry("settings/account", title: "账号管理"),
    entry("settings/edit-profile", title: "编辑资料"),
    entry("settings/block", title: "屏蔽设置"),
    entry("settings/habit", title: "使用习惯"),
    entry("settings/haptics", title: "振动设置"),
    entry("settings/image", title: "图片与流量"),
    entry("settings/oksign", title: "一键签到设置"),
    entry("settings/more", title: "更多设置"),
    // settings/logs 已随页面删除：数据源 modules/tieba-system 从未编进 App。
    entry("settings/about", title: "关于"),

    // ── 上推表单（原 expo-router 的 presentation: 'formSheet'）──
    // login 与「更多」在 _layout.tsx 里声明了 formSheet；更多那张固定三档
    // detents + 贴底可拖拽（fitToContents 会不贴底、不可拉伸，用户实测过）。
    // 登录是整页 WKWebView：半屏（0.5）放不下百度通行证页面，且下方会露出底下的
    // 界面（用户实证"窗口不够大 / 最下面透明"）。用近全高（1.0 → .large）。
    entry(
      "login",
      title: "登录",
      presentation: .sheet(detents: [1.0], grabber: true, cornerRadius: 28)
    ),
    entry(
      "thread/[id]/more",
      title: "",
      presentation: .sheet(detents: [0.3, 0.55, 0.9], grabber: true, cornerRadius: 28),
      chrome: .hidden
    ),
    // 找不到页面（原 +not-found）：保留同样语义，避免深链打到未知路由时无反馈。
    entry("+not-found", title: "找不到页面"),
  ]

  /// 按名字查表（含 O(1) 快查表）。同样是一次性构建、只读——见 entries 的说明。
  nonisolated(unsafe) private static let byName: [String: TiebaRouteEntry] = {
    var map: [String: TiebaRouteEntry] = [:]
    for e in entries { map[e.name] = e }
    return map
  }()

  public static func entry(named name: String) -> TiebaRouteEntry? {
    byName[name]
  }

  // MARK: - 路径解析

  /// 路径 → 路由。找不到返回 nil（调用方决定落 +not-found 还是丢弃）。
  ///
  /// 匹配规则：段数相同、字面段逐段相等；参数段收集成 params。多个候选时取
  /// 「字面段最多」的那个（比如 /forum/x/bawu 必须命中 forum/[name]/bawu 而
  /// 不是 forum/[name]）。
  ///
  /// 两条与 expo-router 对齐的规范化（否则老链接/深链会落 +not-found）：
  ///   - `/` 与空串 = tab 0 根屏（'index'）
  ///   - 末段缺省 = index：`/settings` → `settings/index`、`/search` → `search/index`
  public static func parse(path rawPath: String, extraParams: [String: String] = [:]) -> TiebaRoute? {
    var path = rawPath
    var query: [String: String] = [:]
    if let qIdx = path.firstIndex(of: "?") {
      let q = String(path[path.index(after: qIdx)...])
      path = String(path[path.startIndex..<qIdx])
      for pair in q.split(separator: "&") {
        let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let k = kv.first, !k.isEmpty else { continue }
        let v = kv.count > 1 ? String(kv[1]) : ""
        query[String(k)] = v.removingPercentEncoding ?? v
      }
    }
    // 根路径 = 关注页（tab 0），不是"未命中"。
    if path.isEmpty || path == "/" {
      guard let root = byName["index"] else { return nil }
      _ = root
      var merged = query
      for (k, v) in extraParams { merged[k] = v }
      return TiebaRoute(name: "index", params: merged)
    }
    for candidate in [path, path + "/index"] {
      if let hit = match(path: candidate, query: query, extraParams: extraParams) { return hit }
    }
    return nil
  }

  private static func match(
    path: String,
    query: [String: String],
    extraParams: [String: String]
  ) -> TiebaRoute? {
    // 允许调用方直接传路由名（'thread/[id]'）——Stack.Screen / Link 的旧写法里
    // 路径与名字两种都出现过；按段匹配对两者同时成立，无需特判。
    let input = rawSegments(path)
    var best: (entry: TiebaRouteEntry, params: [String: String])?
    for entry in byName.values where entry.segments.count == input.count {
      var params: [String: String] = [:]
      var ok = true
      for (i, seg) in entry.segments.enumerated() {
        let value = input[i]
        switch seg {
        case .literal(let lit):
          // 字面段比较忽略大小写与百分号编码差异（'/forum/%E6%9F%90%E5%90%A7'
          // 与 '/forum/某吧' 是同一个吧）。
          if lit.lowercased() != (value.removingPercentEncoding ?? value).lowercased() { ok = false }
        case .param(let key):
          params[key] = value.removingPercentEncoding ?? value
        }
      }
      guard ok else { continue }
      // 多个候选时取字面段最多的那个：'/forum/x/bawu' 必须命中
      // forum/[name]/bawu，而不是 forum/[name]（后者段数不同已排除，但
      // 段数相同的歧义分支仍要靠这条定序）。
      let literalCount = entry.segments.reduce(0) { acc, s in
        if case .literal = s { return acc + 1 }
        return acc
      }
      let bestLiteral = best.map { b in
        b.entry.segments.reduce(0) { acc, s in
          if case .literal = s { return acc + 1 }
          return acc
        }
      } ?? -1
      if literalCount > bestLiteral { best = (entry, params) }
    }
    guard let hit = best else { return nil }
    var merged = hit.params
    for (k, v) in query { merged[k] = v }
    for (k, v) in extraParams { merged[k] = v }
    return TiebaRoute(name: hit.entry.name, params: merged)
  }

  private static func rawSegments(_ path: String) -> [String] {
    path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
  }

  // MARK: - 入口构造

  private static func entry(
    _ name: String,
    title: String,
    presentation: TiebaRoutePresentation = .push,
    chrome: TiebaRouteChrome = .standard,
    tabIndex: Int? = nil
  ) -> TiebaRouteEntry {
    TiebaRouteEntry(
      name: name,
      title: title,
      presentation: presentation,
      chrome: chrome,
      tabIndex: tabIndex,
      segments: name.split(separator: "/", omittingEmptySubsequences: true).map { seg in
        let s = String(seg)
        if s.hasPrefix("["), s.hasSuffix("]") {
          return .param(String(s.dropFirst().dropLast()))
        }
        return .literal(s)
      }
    )
  }
}
