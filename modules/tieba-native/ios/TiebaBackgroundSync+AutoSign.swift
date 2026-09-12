import Foundation
import UserNotifications

/// Baidu Tieba returns error_code 1101 for a forum that is already signed
/// today. Both /c/c/forum/msign and /c/c/forum/sign use it. It is a
/// successful state, never a failure.
private let alreadySignedErrorCode = 1101

// 与 commonParams 同款：固定 en_US_POSIX + Gregorian，签到"今天"判定
// 不受地区/日历设置影响。
private let autoSignDayFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.calendar = Calendar(identifier: .gregorian)
  formatter.dateFormat = "yyyyMdd"
  return formatter
}()

/// 自动签到：BGProcessingTask 工作体、签到协调状态（day-scoped、uid 命名空间）、
/// 签到提醒本地通知。
extension TiebaBackgroundSync {
  func performAutoSign() async throws {
    let snapshot = TiebaBackgroundSnapshot.shared
    guard !snapshot.tbs.isEmpty, !snapshot.forumIds.isEmpty else { return }

    let day = dayKey()

    // Coordination with the foreground sign channel:
    // 1. Forums a native auto-sign already completed today are persisted under
    //    `autoSignSuccessKey(uid)`. Skip them so a re-run (or a run that fires
    //    after the user signed manually in the foreground) does not re-hit the
    //    server.
    // 2. The server is idempotent: msign returns error_code 1101 for forums
    //    already signed today (by this app or another client). Those are
    //    classified as "已签到" (successful state), NOT as failures, so the
    //    completion notification never misreports "失败 N".
    var targets = snapshot.forumIds
    let alreadySignedToday = loadAutoSignSuccessIds(uid: snapshot.uid, day: day)
    if !alreadySignedToday.isEmpty {
      targets = targets.filter { !alreadySignedToday.contains($0) }
    }
    if targets.isEmpty {
      return
    }

    let response = try await TiebaNativeClient.shared.postForm(
      urlString: "https://c.tieba.baidu.com/c/c/forum/msign",
      fields: [
        "forum_ids": targets.joined(separator: ","),
        "tbs": snapshot.tbs,
        "authsid": "null",
        "stoken": snapshot.stoken,
        // Kotlin 对照（2026-08-31）：OfficialTiebaApi.mSignFlow 传真实
        // AccountUtil.getUid()——旧版 user_id 恒空串（原 TODO 亦明言待对齐），
        // 与 Kotlin 不一致，服务端对空 uid 的 msign 可能静默拒绝。
        "user_id": snapshot.uid
      ],
      includeCommon: true,
      includeSign: true,
      requestId: "background-msign-\(UUID().uuidString)",
      timeout: 25
    )
    let list = response["sign_list"] as? [[String: Any]] ?? []

    var success = 0
    var fail = 0
    var alreadySigned = 0
    var exp = 0
    var successIds = Set(alreadySignedToday)

    for item in list {
      let code = int(item["error_code"])
      if code == alreadySignedErrorCode {
        alreadySigned += 1
        recordSignSuccess(item["forum_id"], in: &successIds)
      } else if code == 0 {
        success += 1
        exp += int(item["exp"])
        recordSignSuccess(item["forum_id"], in: &successIds)
      } else {
        fail += 1
      }
    }

    saveAutoSignSuccessIds(uid: snapshot.uid, day: day, ids: Array(successIds))
    saveLastAutoSignSummary(
      uid: snapshot.uid,
      day: day,
      success: success,
      fail: fail,
      alreadySigned: alreadySigned,
      exp: exp
    )

    if !list.isEmpty {
      let body: String
      if alreadySigned > 0 {
        body = "成功签到 \(success) 个吧，已签到 \(alreadySigned) 个，失败 \(fail) 个，获得 \(exp) 经验"
      } else {
        body = "成功签到 \(success) 个吧，失败 \(fail) 个，获得 \(exp) 经验"
      }
      sendNotification("一键签到完成", body, identifier: "sign_complete")
    }
  }

  private func recordSignSuccess(_ rawForumId: Any?, in ids: inout Set<String>) {
    let forumId = string(rawForumId)
    if !forumId.isEmpty { ids.insert(forumId) }
  }

  // ----------------------------------------------------------------
  // Auto-sign coordination state (day-scoped, uid-namespaced)
  // ----------------------------------------------------------------

  // getLastAutoSignSummary / clearAutoSignSummary 已于 2026-08-25 删除：
  // 全仓零引用（JS 侧从未接桥，前台签到走自己的协调状态），保留
  // saveLastAutoSignSummary / clearBackgroundSnapshot 的写路径。
  private func dayKey(_ date: Date = Date()) -> String {
    autoSignDayFormatter.string(from: date)
  }

  private func loadAutoSignSuccessIds(uid: String, day: String) -> [String] {
    guard let raw = defaults.string(forKey: autoSignSuccessKey(uid)),
          let json = decodeJSON(raw) as? [String: Any],
          json["day"] as? String == day
    else {
      return []
    }
    return json["ids"] as? [String] ?? []
  }

  private func saveAutoSignSuccessIds(uid: String, day: String, ids: [String]) {
    saveJSON(["day": day, "ids": ids], forKey: autoSignSuccessKey(uid))
  }

  private func saveLastAutoSignSummary(
    uid: String,
    day: String,
    success: Int,
    fail: Int,
    alreadySigned: Int,
    exp: Int
  ) {
    let payload: [String: Any] = [
      "day": day,
      "success": success,
      "fail": fail,
      "alreadySigned": alreadySigned,
      "exp": exp,
      "timestamp": Int(Date().timeIntervalSince1970 * 1000)
    ]
    saveJSON(payload, forKey: autoSignSummaryKey(uid))
  }

  func scheduleSignReminder(hour: Int, minute: Int) {
    let content = UNMutableNotificationContent()
    content.title = "一键签到"
    content.body = "已安排，将在系统空闲时尝试"
    content.sound = .default
    content.badge = 1
    content.userInfo = ["type": "auto_sign_reminder"]

    var date = DateComponents()
    date.hour = hour
    date.minute = minute
    let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: true)
    let request = UNNotificationRequest(identifier: "auto_sign_reminder", content: content, trigger: trigger)
    // 投递结果回读：未授权时 add 会失败，静默丢弃等于提醒悄悄失效。
    UNUserNotificationCenter.current().add(request) { error in
      if let error {
        Self.log.error("add sign reminder failed: \(error.localizedDescription, privacy: .public)")
      }
    }
  }

  func cancelSignReminder() {
    UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["auto_sign_reminder"])
  }
}
