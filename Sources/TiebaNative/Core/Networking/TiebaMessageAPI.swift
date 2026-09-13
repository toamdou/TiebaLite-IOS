// 消息中心数据访问（原 src/services/api/endpoints/messages.ts + notificationStore）：
// /c/s/msg 计数 + replyme / atme / agreeme 三类列表（signed 通道，pn 从 0 起）。
// 行字典 = TiebaSimpleRows 的 message 变体（键名与旧 MessageRow 同源）。
import Foundation
import UIKit
import UserNotifications
import os

private let messageLog = Logger(subsystem: "com.tiebalite.app", category: "message")

struct TiebaNotificationCounts {
  var reply = 0
  var at = 0
  var agree = 0
  var total: Int { reply + at + agree }

  static let zero = TiebaNotificationCounts()
}

enum TiebaMessageTab: String, CaseIterable {
  case reply
  case at
  case agree

  var title: String {
    switch self {
    case .reply: return "回复我的"
    case .at: return "提到我的"
    case .agree: return "赞我的"
    }
  }

  var path: String {
    switch self {
    case .reply: return "/c/u/feed/replyme"
    case .at: return "/c/u/feed/atme"
    case .agree: return "/c/u/feed/agreeme"
    }
  }

  var emptyTitle: String {
    switch self {
    case .reply: return "暂无回复"
    case .at: return "暂无@提到我"
    case .agree: return "暂无收到的赞"
    }
  }

  var emptyDescription: String {
    switch self {
    case .reply: return "还没有人回复你的贴子"
    case .at: return "暂时没有 @你 的内容"
    case .agree: return "你收到的赞会显示在这里"
    }
  }
}

struct TiebaMessageItem {
  var id = ""
  var tab: TiebaMessageTab = .reply
  var fromUserId = ""
  var fromUserName = ""
  var fromUserPortrait = ""
  var threadId = ""
  var threadTitle = ""
  var postId = ""
  var content = ""
  /// 毫秒（服务端秒级 ×1000，已是毫秒原样）。
  var createTime: Double = 0
  var isRead = false
}

enum TiebaMessageAPI {
  /// 未读计数：POST /c/s/msg（bookmark=1）。计数在顶层 message 对象
  /// （replyme/atme/agreeme），兼容 data 包装与平铺三种形状。
  static func counts() async throws -> TiebaNotificationCounts {
    let response = try await TiebaNativeClient.shared.postForm(
      urlString: "https://c.tieba.baidu.com/c/s/msg",
      fields: ["bookmark": "1"],
      includeCommon: true,
      includeSign: true,
      requestId: "native-msg-\(UUID().uuidString)",
      timeout: 15
    )
    let raw = (response["message"] as? [String: Any])
      ?? (response["data"] as? [String: Any])
      ?? response
    func count(_ key: String, _ alt: String) -> Int {
      max(TiebaJSON.intValue(raw[key] ?? raw[alt]) ?? 0, 0)
    }
    var counts = TiebaNotificationCounts()
    counts.reply = count("replyme", "reply")
    counts.at = count("atme", "at")
    counts.agree = count("agreeme", "agree")
    return counts
  }

  /// 分类列表：pn 从 0 起（hasMore 只反映当前分类）。
  static func list(tab: TiebaMessageTab, pn: Int) async throws -> (items: [TiebaMessageItem], hasMore: Bool) {
    let response = try await TiebaNativeClient.shared.postForm(
      urlString: "https://c.tieba.baidu.com\(tab.path)",
      fields: ["pn": String(max(pn, 0))],
      includeCommon: true,
      includeSign: true,
      requestId: "native-msg-\(tab.rawValue)-\(UUID().uuidString)",
      timeout: 15
    )
    let data = (response["data"] as? [String: Any]) ?? response
    let key = tab == .reply ? "reply_list" : (tab == .at ? "at_list" : "agree_list")
    let list = (data[key] as? [[String: Any]]) ?? (response[key] as? [[String: Any]]) ?? []
    return (list.map { mapItem($0, tab: tab) }, hasMore(response))
  }

  /// 页面出现时把当前计数写成通知基线（原 resetNotificationBaseline：避免
  /// 已读过的增量再次提醒）+ 同步应用角标。
  static func markSeen(counts: TiebaNotificationCounts) {
    let uid = TiebaBackgroundSnapshot.shared.uid
    guard !uid.isEmpty else { return }
    let payload: [String: Any] = [
      "reply": counts.reply,
      "at": counts.at,
      "agree": counts.agree,
      "total": counts.total,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: payload),
      let text = String(data: data, encoding: .utf8)
    {
      do {
        try TiebaKvStore.shared.set(key: "tiebalite_last_notif_counts_\(uid)", value: text)
      } catch {
        messageLog.error("notification baseline write failed: \(error.localizedDescription, privacy: .public)")
      }
    }
    // 原生后台轮询的基线也要同写（JS 侧同款：setNotificationCounts），否则后台
    // 任务会用旧基线把刚看过的增量再提醒一次。
    TiebaBackgroundSync.shared.setNotificationCounts(
      uid: uid,
      reply: counts.reply,
      at: counts.at,
      agree: counts.agree,
      total: counts.total
    )
    TiebaNavigator.shared.setTabBadge(index: 2, text: counts.total > 99 ? "99+" : (counts.total > 0 ? String(counts.total) : ""))
    Task { try? await UNUserNotificationCenter.current().setBadgeCount(counts.total) }
  }

  /// 行字典（TiebaSimpleRows 的 message 变体；字号/色板键与旧 MessageRow 一致）。
  static func row(for item: TiebaMessageItem, palette: TiebaSimpleRowPalette) -> [String: Any] {
    let icon = typeIcon(item.tab, palette: palette)
    return [
      "variant": "message",
      "a11y": "\(item.fromUserName) \(item.content)",
      "avatar": TiebaSimpleRowParser.avatarURL(item.fromUserPortrait)?.absoluteString ?? "",
      "avatarInitial": item.fromUserName.isEmpty ? "吧" : String(item.fromUserName.prefix(1)),
      "unread": !item.isRead,
      "name": item.fromUserName,
      "nameSize": 15,
      "nameWeight": 600,
      "nameLineHeight": 20,
      "icon": icon.name,
      "iconSize": 13,
      "content": item.content.isEmpty ? "..." : item.content,
      "contentSize": 15,
      "contentWeight": 400,
      "contentLineHeight": 20,
      "contentLines": 2,
      "threadTitle": item.threadTitle.isEmpty ? "" : "原贴: \(item.threadTitle)",
      "threadSize": 12,
      "threadWeight": 400,
      "threadLineHeight": 16,
      "time": TiebaTimeLabel.label(millis: item.createTime),
      "timeSize": 11,
      "timeWeight": 400,
      "timeLineHeight": 13,
      "colors": [
        "bg": hex(palette.base.card),
        "unreadDotColor": hex(palette.base.primary),
        "iconColor": hex(icon.color),
      ],
    ]
  }

  private static func typeIcon(_ tab: TiebaMessageTab, palette: TiebaSimpleRowPalette) -> (name: String, color: UIColor) {
    switch tab {
    case .reply: return ("arrowshape.turn.up.left.fill", palette.base.primary)
    case .at: return ("at", palette.base.warning)
    case .agree: return ("hand.thumbsup.fill", palette.success)
    }
  }

  /// mapMessageItem（messages.ts）：replyer 子对象优先，unread 是未读权威。
  private static func mapItem(_ raw: [String: Any], tab: TiebaMessageTab) -> TiebaMessageItem {
    var item = TiebaMessageItem()
    item.tab = tab
    let replyer = (raw["replyer"] as? [String: Any]) ?? (raw["replyer_info"] as? [String: Any]) ?? [:]
    let threadId = text(raw["thread_id"] ?? raw["threadId"] ?? raw["tid"])
    let postId = text(raw["post_id"] ?? raw["postId"] ?? raw["pid"])
    item.threadId = threadId
    item.postId = postId
    item.id = text(raw["id"] ?? raw["reply_id"] ?? raw["msg_id"])
    if item.id.isEmpty {
      item.id = postId.isEmpty ? threadId : "\(threadId)_\(postId)"
    }
    item.fromUserId = text(
      replyer["id"] ?? raw["user_id"] ?? raw["userId"] ?? raw["from_user_id"] ?? raw["fromUserId"] ?? raw["uid"]
    )
    item.fromUserName = text(
      replyer["name_show"] ?? replyer["name"] ?? raw["user_name"] ?? raw["userName"] ?? raw["name"]
    )
    item.fromUserPortrait = text(
      replyer["portrait"] ?? raw["user_portrait"] ?? raw["userPortrait"] ?? raw["portrait"]
    )
    item.threadTitle = text(raw["thread_title"] ?? raw["threadTitle"] ?? raw["title"])
    item.content = text(raw["content"] ?? raw["reply_content"] ?? raw["replyContent"] ?? raw["summary"])
    let time = TiebaJSON.doubleValue(
      raw["time"] ?? raw["create_time"] ?? raw["createTime"] ?? raw["reply_time"] ?? raw["agree_time"]
    ) ?? 0
    item.createTime = time >= 100_000_000_000 ? time : time * 1000
    item.isRead = !(TiebaJSON.boolValue(raw["unread"] ?? raw["is_read"] ?? raw["isRead"]) ?? false)
    return item
  }

  private static func hasMore(_ raw: [String: Any]) -> Bool {
    let data = raw["data"] as? [String: Any]
    let value = (data?["page"] as? [String: Any])?["has_more"]
      ?? (raw["page"] as? [String: Any])?["has_more"]
      ?? data?["has_more"]
      ?? raw["has_more"]
    return TiebaJSON.boolValue(value) ?? false
  }

  /// 单值 → 非空串（列/字段可能是 text 或 number，统一走 TiebaJSON）。
  private static func text(_ value: Any?) -> String {
    TiebaJSON.stringValue(value) ?? ""
  }

  static func hex(_ color: UIColor) -> String {
    let traits = UITraitCollection(userInterfaceStyle: TiebaNavigator.shared.chromeTheme.dark ? .dark : .light)
    let resolved = color.resolvedColor(with: traits)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
    if a >= 0.999 {
      return String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
    return String(format: "rgba(%d,%d,%d,%.2f)", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), a)
  }
}

/// 时间标签（原 useTimeLabel → relativeTime / absoluteTime，按 timestampStyle 偏好）。
enum TiebaTimeLabel {
  static func label(millis: Double) -> String {
    TiebaPreferenceSnapshot.string("timestampStyle") == "absolute" ? absolute(millis) : relative(millis)
  }

  static func relative(_ millis: Double) -> String {
    guard millis >= 946_684_800_000 else { return "" }
    let now = Date()
    let diff = max(0, now.timeIntervalSince1970 * 1000 - millis)
    let minute = 60_000.0, hour = 3_600_000.0, day = 86_400_000.0
    if diff < minute { return "刚刚" }
    if diff < hour { return "\(Int(diff / minute))分钟前" }
    if diff < day { return "\(Int(diff / hour))小时前" }
    let then = Date(timeIntervalSince1970: millis / 1000)
    let calendar = Calendar.current
    if calendar.isDateInYesterday(then) {
      let comps = calendar.dateComponents([.hour, .minute], from: then)
      return String(format: "昨天 %02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }
    if diff < 7 * day { return "\(Int(diff / day))天前" }
    let comps = calendar.dateComponents([.year, .month, .day], from: then)
    return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
  }

  static func absolute(_ millis: Double) -> String {
    guard millis >= 946_684_800_000 else { return "" }
    let comps = Calendar.current.dateComponents(
      [.year, .month, .day, .hour, .minute],
      from: Date(timeIntervalSince1970: millis / 1000)
    )
    return String(
      format: "%04d-%02d-%02d %02d:%02d",
      comps.year ?? 0, comps.month ?? 0, comps.day ?? 0, comps.hour ?? 0, comps.minute ?? 0
    )
  }
}
