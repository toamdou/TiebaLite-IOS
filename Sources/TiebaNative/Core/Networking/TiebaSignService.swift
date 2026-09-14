// 首页「一键签到」的原生实现（原 signStore/runSignBatch 的前台面）：
// 官方批量 msign（与后台自动签到同一条通道）为主，失败/关闭官方接口时按吧串行
// sign 兜底；结果走应用内 pill + 触觉，勾号回填关注列表。
// 展示位二选一（设置）：灵动岛 Live Activity / 通知栏进度横幅。
import Foundation
import UIKit
import UserNotifications

/// /c/c/forum/msign 的唯一请求构造点：前台一键签到与后台自动签到（BGTask）共用，
/// 避免 user_id / stoken 这类参数在两条路径上漂移。
nonisolated enum TiebaSignAPI {
  static func msign(forumIds: [String], timeout: Double = 25) async throws -> [[String: Any]] {
    let snapshot = TiebaBackgroundSnapshot.shared
    let response = try await TiebaNativeClient.shared.postForm(
      urlString: "https://c.tieba.baidu.com/c/c/forum/msign",
      fields: [
        "forum_ids": forumIds.joined(separator: ","),
        "tbs": snapshot.tbs,
        "authsid": "null",
        "stoken": snapshot.stoken,
        "user_id": snapshot.uid,
      ],
      includeCommon: true,
      includeSign: true,
      requestId: "native-msign-\(UUID().uuidString)",
      timeout: timeout
    )
    return response["sign_list"] as? [[String: Any]] ?? []
  }
}

@MainActor
final class TiebaSignService {
  static let shared = TiebaSignService()

  private(set) var isSigning = false
  /// 状态变化（首页刷新签到按钮图标）。
  var onStateChange: (() -> Void)?
  /// 结果落地（首页重拉关注列表勾号）。
  var onFinished: (() -> Void)?

  /// 逐吧进度（设置页「进度列表」消费；首页只看 isSigning）。
  struct ProgressItem {
    var forumId = ""
    var forumName = ""
    /// pending / signing / success / failed
    var status = "pending"
    var exp = 0
  }
  private(set) var progressItems: [ProgressItem] = []
  private(set) var progressDone = 0
  private(set) var progressSuccess = 0
  private(set) var progressFail = 0
  private(set) var progressExp = 0
  /// 最新一次失败原因（设置页错误区块用；开始新一次签到即清空）。
  private(set) var lastError: String?
  /// 进度观察者（onStateChange/onFinished 是单消费者，设置页另走这一路）。
  private var progressObservers: [UUID: () -> Void] = [:]
  private var cancelRequested = false

  /// 请求取消：当前吧结束后停止（旧页「取消签到」同语义）。
  func cancel() { cancelRequested = true }

  @discardableResult
  func addProgressObserver(_ observer: @escaping () -> Void) -> UUID {
    let id = UUID()
    progressObservers[id] = observer
    return id
  }

  func removeProgressObserver(_ id: UUID) {
    progressObservers.removeValue(forKey: id)
  }

  private func notifyProgress() {
    for observer in progressObservers.values { observer() }
  }

  private let alreadySignedCode = 1101

  private init() {}

  func start(presenter: UIViewController) {
    guard !isSigning else { return }
    let snapshot = TiebaBackgroundSnapshot.shared
    guard !snapshot.tbs.isEmpty else {
      TiebaSceneHaptics.fire("action-fail")
      Self.toast("未登录或登录信息已过期，请重新登录", on: presenter)
      return
    }
    isSigning = true
    cancelRequested = false
    lastError = nil
    progressItems = []
    progressDone = 0
    progressSuccess = 0
    progressFail = 0
    progressExp = 0
    notifyProgress()
    onStateChange?()

    let silent = TiebaPreferenceSnapshot.bool("signSilent", default: false)
    let bannerMode = TiebaPreferenceSnapshot.string("signDisplayMode") == "notification"
    let islandMode = !bannerMode
      && TiebaPreferenceSnapshot.bool("liveActivitySignEnabled", default: true)
    var activityId: String? = islandMode ? startActivity(total: 0) : nil
    if bannerMode {
      Notifications.setProgress(done: 0, total: 0, silent: silent)
    }

    Task { @MainActor in
      var success = 0
      var fail = 0
      var exp = 0
      var signedIds: [String] = []
      do {
        let forums = try await TiebaFollowedForums.fetchAll(force: true)
        let targets = forums.filter { !$0.isSign }
        guard !targets.isEmpty else {
          finishDisplay(activityId: activityId, banner: bannerMode, success: 0, fail: 0, exp: 0)
          isSigning = false
          onStateChange?()
          TiebaSceneHaptics.fire("action-success")
          Self.toast("今天所有关注的吧都已签到过了", on: presenter)
          return
        }
        Notifications.setProgress(done: 0, total: targets.count, silent: silent)
        updateActivity(activityId, done: 0, total: targets.count, name: "", success: 0, fail: 0, exp: 0)
        progressItems = targets.map { ProgressItem(forumId: $0.forumId, forumName: $0.forumName) }
        notifyProgress()

        let official = TiebaPreferenceSnapshot.bool("useOfficialSign", default: true)
          && !TiebaPreferenceSnapshot.bool("slowSignMode", default: false)
        var remaining = targets
        if official {
          let outcomes = try await signBatch(targets)
          for item in outcomes {
            if item.signed { success += 1; exp += item.exp; signedIds.append(item.forumId) }
            else { fail += 1 }
            if let index = progressItems.firstIndex(where: { $0.forumId == item.forumId }) {
              progressItems[index].status = item.signed ? "success" : "failed"
              progressItems[index].exp = item.exp
            }
          }
          progressSuccess = success
          progressFail = fail
          progressExp = exp
          progressDone = success + fail
          notifyProgress()
          remaining = targets.filter { forum in !outcomes.contains { $0.forumId == forum.forumId } }
        }
        let failAutoStop = TiebaPreferenceSnapshot.bool("failAutoStop", default: true)
        let slow = TiebaPreferenceSnapshot.bool("slowSignMode", default: false)
        for (index, forum) in remaining.enumerated() {
          if cancelRequested { break }
          if let itemIndex = progressItems.firstIndex(where: { $0.forumId == forum.forumId }) {
            progressItems[itemIndex].status = "signing"
            notifyProgress()
          }
          let result = try? await signOne(forum)
          if let result, result.signed {
            success += 1
            exp += result.exp
            signedIds.append(forum.forumId)
          } else {
            fail += 1
          }
          if let itemIndex = progressItems.firstIndex(where: { $0.forumId == forum.forumId }) {
            progressItems[itemIndex].status = (result?.signed ?? false) ? "success" : "failed"
            progressItems[itemIndex].exp = result?.exp ?? 0
          }
          progressSuccess = success
          progressFail = fail
          progressExp = exp
          progressDone = success + fail
          notifyProgress()
          if failAutoStop, !(result?.signed ?? false), fail > 0 { break }
          if index < remaining.count - 1 {
            // slowSignMode 对齐 Kotlin 的 3.5–8s 随机间隔；常规路径 1.2s 防风控。
            let delay = slow ? Double.random(in: 3.5...8.0) : 1.2
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
          }
        }
        TiebaFollowedForums.markSigned(signedIds)
        finishDisplay(activityId: activityId, banner: bannerMode, success: success, fail: fail, exp: exp)
        activityId = nil
        isSigning = false
        onStateChange?()
        if fail == 0, success > 0 {
          TiebaSceneHaptics.fire("action-success")
        } else if success > 0 {
          TiebaSceneHaptics.fire("action-warning")
        } else {
          TiebaSceneHaptics.fire("action-fail")
        }
        if success > 0 || fail > 0 {
          Self.toast(
            fail > 0
              ? "成功 \(success) 个吧，失败 \(fail) 个，+\(exp) 经验"
              : "成功签到 \(success) 个吧，+\(exp) 经验",
            on: presenter
          )
        }
        // 勾号回填 + 由调用方（页面）失效缓存重拉服务端 is_sign（JS 同款时序）。
        onFinished?()
      } catch {
        lastError = error.localizedDescription
        finishDisplay(activityId: activityId, banner: bannerMode, success: success, fail: fail, exp: exp)
        activityId = nil
        isSigning = false
        onStateChange?()
        TiebaSceneHaptics.fire("action-fail")
        Self.toast("签到失败：\(error.localizedDescription)", on: presenter)
      }
    }
  }

  // MARK: - 接口

  private struct SignOutcome {
    var forumId = ""
    var signed = false
    var exp = 0
  }

  /// 官方批量：/c/c/forum/msign（error_code 1101 = 已签）。
  private func signBatch(_ forums: [TiebaForumInfo]) async throws -> [SignOutcome] {
    let list = try await TiebaSignAPI.msign(forumIds: forums.map(\.forumId))
    var outcomes: [SignOutcome] = []
    for item in list {
      var outcome = SignOutcome()
      outcome.forumId = Self.string(item["forum_id"] ?? item["forumId"])
      let code = Self.int(item["error_code"] ?? item["errorCode"])
      outcome.signed = code == 0 || code == alreadySignedCode
      outcome.exp = outcome.signed ? Self.int(item["exp"]) : 0
      if !outcome.forumId.isEmpty { outcomes.append(outcome) }
    }
    return outcomes
  }

  /// 单吧：统一走 TiebaForumFeedAPI.sign（/c/c/forum/sign 的唯一实现）。
  private func signOne(_ forum: TiebaForumInfo) async throws -> SignOutcome {
    let result = try await TiebaForumFeedAPI.sign(
      forumName: forum.forumName,
      tbs: TiebaBackgroundSnapshot.shared.tbs,
      forumId: forum.forumId
    )
    var outcome = SignOutcome()
    outcome.forumId = forum.forumId
    outcome.signed = result.isSuccess || result.errorCode == alreadySignedCode
    outcome.exp = result.exp
    return outcome
  }

  // MARK: - 展示位

  private func startActivity(total: Int) -> String? {
    try? TiebaLiveActivityManager.shared.start(
      payload: TiebaLiveActivityPayload(raw: activityState(
        done: 0, total: total, name: "", success: 0, fail: 0, exp: 0, signing: true
      ))
    )
  }

  private func updateActivity(_ id: String?, done: Int, total: Int, name: String, success: Int, fail: Int, exp: Int) {
    guard let id else { return }
    let state = activityState(
      done: done, total: total, name: name, success: success, fail: fail, exp: exp, signing: true
    )
    Task { await TiebaLiveActivityManager.shared.update(activityId: id, state: LiveActivityKitAttributes.ContentState(raw: state)) }
  }

  private func finishDisplay(activityId: String?, banner: Bool, success: Int, fail: Int, exp: Int) {
    if banner {
      Notifications.cancelProgress()
      return
    }
    guard let activityId else { return }
    let done = success + fail
    let state = activityState(
      done: done, total: max(done, 1), name: "", success: success, fail: fail, exp: exp, signing: false
    )
    Task {
      await TiebaLiveActivityManager.shared.end(
        activityId: activityId,
        state: LiveActivityKitAttributes.ContentState(raw: state),
        dismissalPolicy: "default"
      )
    }
  }

  /// buildSignSnapshot（signSnapshot.ts）的原生同义实现（相位只有 signing/完成）。
  private func activityState(
    done: Int, total: Int, name: String, success: Int, fail: Int, exp: Int, signing: Bool
  ) -> [String: Any] {
    let ratio = total > 0 ? min(max(Double(done) / Double(total), 0), 1) : 1
    var meta = ["已完成 \(done)/\(total)", "成功 \(success)", "失败 \(fail)"]
    if exp > 0 { meta.append("获得 \(exp) 经验") }
    let status = signing ? "\(done)/\(total)" : "完成"
    var state: [String: Any] = [
      "title": signing ? "一键签到" : "签到完成",
      "subtitle": signing
        ? (name.isEmpty ? "正在准备签到" : "正在签到 \(name)")
        : "成功 \(success) 个\(fail > 0 ? "，失败 \(fail) 个" : "")",
      "body": meta.joined(separator: " · "),
      "currentForum": name,
      "status": status,
      "pill": status,
      "progress": ratio,
      "imageName": signing ? "checkmark.circle.fill" : "checkmark.seal.fill",
      "tintColorHex": "#3B82F6",
      "accent": signing ? "#60A5FA" : "#30D158",
      "leading": signing ? "签到" : "签到",
      "trailing": signing ? "\(done)/\(total)" : "\(done)/\(total)",
    ]
    if signing {
      state["date"] = Date().addingTimeInterval(60).timeIntervalSince1970 * 1000
      state["extra"] = ["currentForum": name, "success": "\(success)", "fail": "\(fail)", "exp": "\(exp)"]
    }
    return state
  }

  // MARK: - 工具

  private enum Notifications {
    static let progressId = "sign-progress"

    /// 进度横幅：同一 id 覆盖式投递（deliver 内部 add 同 id 即替换）。
    static func setProgress(done: Int, total: Int, silent: Bool) {
      TiebaNotificationCenter.shared.deliver(
        identifier: progressId,
        title: "正在签到",
        body: "\(done) / \(total) 个吧",
        badge: 0,
        interruptionLevel: silent ? .passive : .active,
        dataType: "sign_progress"
      )
    }

    static func cancelProgress() {
      TiebaNotificationCenter.shared.cancel(identifier: progressId)
    }
  }

  private static func toast(_ text: String, on presenter: UIViewController) {
    let pill = TiebaSignToastView()
    presenter.view.addSubview(pill)
    pill.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      pill.centerXAnchor.constraint(equalTo: presenter.view.centerXAnchor),
      pill.bottomAnchor.constraint(equalTo: presenter.view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
    ])
    pill.show(success: true, text: text)
  }

  private static func string(_ value: Any?) -> String {
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return ""
  }

  private static func int(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return number.intValue }
    if let string = value as? String { return Int(string) ?? 0 }
    return 0
  }
}

// MARK: - 结果 toast（玻璃 pill）

/// 签到结果 toast：尺寸沿用旧查看器 pill（圆角 18 / 图标 18 / 2.2s 自动消失），
/// 材质走系统玻璃（部署底线 iOS 26，UIGlassEffect 恒可用），不再手写深色底。
/// ⚠️ TiebaPhotoBrowser 里还有同名用途的旧 pill（那个文件不在本批改动范围）。
private final class TiebaSignToastView: UIView {
  private static let horizontalPadding: CGFloat = 16
  private static let verticalPadding: CGFloat = 9
  private static let contentGap: CGFloat = 6
  private static let indicatorSize: CGFloat = 18

  private let iconView = UIImageView()
  private let label = UILabel()
  private var hideWorkItem: DispatchWorkItem?

  init() {
    super.init(frame: .zero)
    layer.cornerRadius = 18
    layer.cornerCurve = .continuous
    clipsToBounds = true
    isUserInteractionEnabled = false
    isHidden = true
    alpha = 0

    let backdrop = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    backdrop.translatesAutoresizingMaskIntoConstraints = false
    addSubview(backdrop)

    iconView.tintColor = .label
    iconView.contentMode = .scaleAspectFit
    iconView.translatesAutoresizingMaskIntoConstraints = false
    addSubview(iconView)

    label.textColor = .label
    label.font = .systemFont(ofSize: 14, weight: .medium)
    label.textAlignment = .center
    label.lineBreakMode = .byTruncatingTail
    label.translatesAutoresizingMaskIntoConstraints = false
    label.setContentCompressionResistancePriority(.required, for: .horizontal)
    addSubview(label)

    NSLayoutConstraint.activate([
      backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
      backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
      backdrop.topAnchor.constraint(equalTo: topAnchor),
      backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

      iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalPadding),
      iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
      iconView.widthAnchor.constraint(equalToConstant: Self.indicatorSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.indicatorSize),

      label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Self.contentGap),
      label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.horizontalPadding),
      label.topAnchor.constraint(equalTo: topAnchor, constant: Self.verticalPadding),
      label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.verticalPadding),
      label.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func show(success: Bool, text: String) {
    iconView.image = UIImage(
      systemName: success ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    )
    label.text = text
    isHidden = false
    UIView.animate(withDuration: 0.18) { self.alpha = 1 }
    hideWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.hideToast() }
    hideWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: item)
  }

  private func hideToast() {
    hideWorkItem?.cancel()
    hideWorkItem = nil
    UIView.animate(withDuration: 0.18, animations: { self.alpha = 0 }) { _ in
      self.isHidden = true
    }
  }
}
