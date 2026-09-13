import Foundation

/// 通知轮询：BGAppRefreshTask 工作体、未读计数读写、本地通知投递。
extension TiebaBackgroundSync {
  func performNotificationSync() async throws {
    let snapshot = TiebaBackgroundSnapshot.shared
    guard !snapshot.bduss.isEmpty else { return }
    let response = try await TiebaNativeClient.shared.postForm(
      urlString: "https://c.tieba.baidu.com/c/s/msg",
      fields: ["bookmark": "1"],
      includeCommon: true,
      includeSign: true,
      requestId: "background-msg-\(UUID().uuidString)",
      timeout: 15
    )
    let data = response["data"] as? [String: Any] ?? response
    let reply = int(data["reply"])
    let at = int(data["at"])
    let agree = int(data["agree"])
    let total = reply + at + agree

    let previous = loadLastCounts(uid: snapshot.uid)
    if let previous {
      let newReply = reply - previous.reply
      let newAt = at - previous.at
      let newAgree = agree - previous.agree
      if total > previous.total {
        if newReply > 0 {
          sendNotification(
            "回复我的 (\(reply))",
            "你有 \(newReply) 条新回复",
            identifier: "msg_reply",
            deepLink: "tiebalite://notifications/0"
          )
        }
        if newAt > 0 {
          sendNotification(
            "提到我的 (\(at))",
            "有 \(newAt) 人@了你",
            identifier: "msg_at",
            deepLink: "tiebalite://notifications/1"
          )
        }
        if newAgree > 0 {
          sendNotification(
            "赞我的 (\(agree))",
            "有 \(newAgree) 人赞了你",
            identifier: "msg_agree",
            deepLink: "tiebalite://notifications/2"
          )
        }
      }
    }
    saveLastCounts(uid: snapshot.uid, reply: reply, at: at, agree: agree, total: total)
    // 角标走统一出口（applicationIconBadgeNumber 自 iOS 17 起废弃）；角标失败
    // 不影响未读计数本身。
    await TiebaNotificationCenter.shared.setBadge(total)
  }

  func setNotificationCounts(uid: String, reply: Int, at: Int, agree: Int, total: Int) {
    saveLastCounts(uid: uid, reply: reply, at: at, agree: agree, total: total)
  }

  func getNotificationCounts(uid: String) -> [String: Any]? {
    guard let counts = loadLastCounts(uid: uid) else { return nil }
    return [
      "reply": counts.reply,
      "at": counts.at,
      "agree": counts.agree,
      "total": counts.total
    ]
  }

  func clearNotificationCounts(uid: String) {
    defaults.removeObject(forKey: lastCountsKey(uid))
  }

  private func loadLastCounts(uid: String) -> (reply: Int, at: Int, agree: Int, total: Int)? {
    guard let raw = defaults.string(forKey: lastCountsKey(uid)),
          let json = decodeJSON(raw) as? [String: Any]
    else {
      return nil
    }
    return (
      reply: int(json["reply"]),
      at: int(json["at"]),
      agree: int(json["agree"]),
      total: int(json["total"])
    )
  }

  private func saveLastCounts(uid: String, reply: Int, at: Int, agree: Int, total: Int) {
    saveJSON(
      ["reply": reply, "at": at, "agree": agree, "total": total],
      forKey: lastCountsKey(uid)
    )
  }

  /// 本地通知投递：轮询（回复/@/赞）与自动签到完成通知共用，跨文件调用故
  /// 保持 internal（原 private 只在单文件内可见）。
  /// silent = 偏好 signSilent（静默模式：横幅照常、不发声、不打断）。
  func sendNotification(
    _ title: String,
    _ body: String,
    identifier: String,
    deepLink: String? = nil,
    silent: Bool = false
  ) {
    TiebaNotificationCenter.shared.deliver(
      identifier: identifier,
      title: title,
      body: body,
      playSound: !silent,
      interruptionLevel: silent ? .passive : nil,
      dataType: "message",
      deepLink: deepLink
    )
  }
}
