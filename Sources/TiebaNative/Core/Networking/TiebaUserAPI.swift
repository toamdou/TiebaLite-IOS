// 账号与用户资料的原生数据访问：资料走 proto cmd=303012（与 JS protoProfile 同
// 请求形状）；账号昵称/头像/计数从原生 KV 的档案缓存现读（AuthSecureStorage 的
// 无凭据缓存，与 JS 同一份键），登录态看后台快照的 BDUSS。
import Foundation
import SwiftProtobuf
import UIKit

/// 账号卡片数据（我的页 / 首页顶栏）。
struct TiebaAccountProfile {
  var uid = ""
  var name = ""
  var nameShow = ""
  var portrait = ""
  var intro = ""
  var fansNum = 0
  var concernNum = 0
  var postNum = 0

  var displayName: String {
    let show = nameShow.isEmpty ? name : nameShow
    return show.isEmpty ? "贴吧用户" : show
  }

  var initials: String {
    String(displayName.prefix(1))
  }
}

/// 用户资料（proto 应答里的字段子集；旧 JS 的 user/statue 两段压平到这里）。
struct TiebaUserProfile {
  var name = ""
  var nameShow = ""
  var portrait = ""
  var intro = ""
  var fansNum = 0
  var concernNum = 0
  var postNum = 0

  var displayName: String {
    let show = nameShow.isEmpty ? name : nameShow
    return show.isEmpty ? "贴吧用户" : show
  }
}

enum TiebaUserAPI {
  private static let accountCacheKey = "@tiebalite:account_profile_cache_v1"

  static var isLoggedIn: Bool { !TiebaBackgroundSnapshot.shared.bduss.isEmpty }

  static var uid: String { TiebaBackgroundSnapshot.shared.uid }

  /// 冷启动快照由 JS bootstrap 写入（同步落 Keychain）——原生页先到时补读一次，
  /// 否则首屏会闪"未登录"（后台任务路径同样在开跑前 load，见 TiebaBackgroundSync）。
  static func refreshLoginSnapshot() {
    guard TiebaBackgroundSnapshot.shared.bduss.isEmpty else { return }
    TiebaBackgroundSnapshot.shared.load()
  }

  /// 档案缓存 TTL：昵称/头像/简介可能被改（本机编辑资料、或别的设备改），
  /// 过期就当作没有缓存、让页面走网络拿新的。
  private static let accountCacheTTL: TimeInterval = 24 * 60 * 60

  /// 冷启动档案缓存：解析失败/缺 uid/过期 → nil（页面回落空态或走网络，不猜）。
  static func cachedAccount() -> TiebaAccountProfile? {
    guard let raw = TiebaKvStore.shared.get(key: accountCacheKey),
      let data = raw.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let ts = TiebaJSON.doubleValue(object["ts"]) ?? 0
    if ts > 0, Date().timeIntervalSince1970 * 1000 - ts > accountCacheTTL * 1000 { return nil }
    var account = TiebaAccountProfile()
    account.uid = TiebaJSON.stringValue(object["uid"]) ?? ""
    account.name = TiebaJSON.stringValue(object["name"]) ?? ""
    account.nameShow = TiebaJSON.stringValue(object["nameShow"]) ?? ""
    account.portrait = TiebaJSON.stringValue(object["portrait"]) ?? ""
    account.intro = TiebaJSON.stringValue(object["intro"]) ?? ""
    account.fansNum = TiebaJSON.intValue(object["fansNum"]) ?? 0
    account.concernNum = TiebaJSON.intValue(object["concernNum"]) ?? 0
    account.postNum = TiebaJSON.intValue(object["postNum"]) ?? 0
    return account.uid.isEmpty ? nil : account
  }

  /// 当前账号：快照 uid + 档案缓存（缓存 uid 不一致时按快照兜底，切号窗口不串号）。
  static func currentAccount() -> TiebaAccountProfile? {
    let uid = TiebaBackgroundSnapshot.shared.uid
    guard !uid.isEmpty else { return nil }
    var account = cachedAccount() ?? TiebaAccountProfile()
    if account.uid.isEmpty || account.uid != uid {
      account.uid = uid
    }
    return account
  }

  /// 唯一实现在 TiebaProfileAPI.profile（proto 303012，参数逐字段同源）；
  /// 这里只投影成本页更窄的视图模型，不复制请求。
  static func profile(uid: String) async throws -> TiebaUserProfile {
    let detail = try await TiebaProfileAPI.profile(uid: uid)
    var profile = TiebaUserProfile()
    profile.name = detail.name
    profile.nameShow = detail.nameShow
    profile.portrait = detail.portrait
    profile.intro = detail.intro
    profile.fansNum = detail.fansNum
    profile.concernNum = detail.concernNum
    profile.postNum = detail.postNum
    return profile
  }

  /// 头像/昵称跳个人主页：未登录 → 登录页；登录但 uid 缺失 → 账号管理（旧页
  /// 顶栏头像的同一分支）。
  static func navigateToOwnProfile() {
    guard isLoggedIn else {
      TiebaNavigator.shared.navigate(.login)
      return
    }
    guard !uid.isEmpty else {
      TiebaNavigator.shared.navigate(.account)
      return
    }
    TiebaNavigator.shared.navigate(.user(uid: uid))
  }
}
