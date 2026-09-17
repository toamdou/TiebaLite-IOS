import UIKit

// 原生页面登记表（类型化路由 → UIViewController），**唯一**一份路由 → 页面映射，
// 也就是**唯一**的页面构造路径：本地跳转与深链解析出的路由都走这里。
//
// 每个 case 的关联值已是领域值（Int/Bool/String?），这里不再从字符串解参数。
//
// ⚠️ 原生页面一律写成**普通 UIViewController**：标题/栏按钮/状态栏/滚动视图
// 跟踪这些壳能力由 TiebaNavigationShell 提供。

/// 原生页面的**可选**契约：只用来声明「本屏的标题 / 状态栏字色」。
///
/// 为什么不直接用 `navigationItem.title`：压栈的是宿主壳（TiebaRouteHostViewController），
/// UINavigationController 只认它的 navigationItem，子 VC 的会被忽略。所以要靠
/// 这两个属性把意图传上去，由壳落到 navigationItem 上。
/// 不实现本协议也完全合法（那就用路由表里的静态标题 + 全局默认状态栏字色）。
@MainActor
public protocol TiebaNativeScreen: UIViewController {
  /// 本屏标题。nil = 用路由表里的标题。
  var screenTitle: String? { get }
  /// nil = 跟随导航壳的全局默认（TiebaNavigator.defaultStatusBarStyle）。
  var preferredScreenStatusBarStyle: UIStatusBarStyle? { get }
  /// 本屏自绘的右侧栏按钮（nil = 无）。宿主落到自己的 navigationItem 上；
  /// 内容随数据变化时页面自己再调 host.syncNativeScreenChrome() 刷新。
  var screenRightBarItems: [UIBarButtonItem]? { get }
  /// 本屏自绘的左侧栏按钮（nil = 保留系统的返回箭头）。
  var screenLeftBarItems: [UIBarButtonItem]? { get }
  /// 应用主题变化（含**跟随系统**时的实时切换，见 TiebaAppBootstrap.observeTraitChanges）。
  /// 导航壳会对在场的每个宿主（含其子 VC 树）回调一次；需要重着色自绘内容的屏在这里
  /// 重取主题重刷（一般就是调自己的 applyPalette）。
  func screenThemeDidChange()
}

public extension TiebaNativeScreen {
  var screenTitle: String? { nil }
  var preferredScreenStatusBarStyle: UIStatusBarStyle? { nil }
  var screenRightBarItems: [UIBarButtonItem]? { nil }
  var screenLeftBarItems: [UIBarButtonItem]? { nil }
  func screenThemeDidChange() {}
}

/// 类型化路由 → 原生页面。路由表（TiebaRoute.name）里登记过的每一条都在这里落地，
/// 返回非可选：**没有**「路由名对不上就换别的页面」的兜底分支。
///
/// @MainActor：VC 构造必须在主线程；调用点在 TiebaNavigator.makeHost 的
/// MainActor.assumeIsolated 块内（导航壳的全部入口本来就在主线程，见其注释）。
@MainActor
public enum TiebaNativeRouteTable {
  public static func make(_ route: TiebaRoute) -> UIViewController {
    switch route {
    // 找不到页面（原 src/app/+not-found.tsx）：纯静态屏，无 store、无网络、不渲染参数。
    case .notFound:
      return TiebaNotFoundViewController()
    // 关于（原 src/app/settings/about.tsx）：表单 + 原生更新检查 + 结果弹窗
    //（页面局部状态，不读共享 store；仅从原生 KV 现读 lightTheme/darkTheme）。
    case .settingsAbout:
      return TiebaAboutViewController()
    // 内置浏览器（原 src/app/webview.tsx）：工具栏 + WKWebView；url/title
    // 是类型化参数（原生解析，JS 侧不参与）。
    case .webview(let url, let title):
      return TiebaWebViewController(url: url, title: title)
    // 吧页（原 src/app/forum/[name].tsx）：frsPage proto + 关注/签到，滚动头 =
    // 吧名片/分段/排序/分类行。
    case .forum(let name, let forumId):
      return TiebaForumViewController(name: name, forumId: forumId)
    // 吧三页（原 src/app/forum/[name]/{detail,rules,bawu}.tsx）：数据走 TiebaForumAPI。
    case .forumDetail(let name, let forumId):
      return TiebaForumDetailViewController(name: name, forumId: forumId)
    case .forumRules(let name, let forumId):
      return TiebaForumRulesViewController(name: name, forumId: forumId)
    case .forumBawu(let name, let forumId):
      return TiebaBawuTeamViewController(name: name, forumId: forumId)
    // 吧成员（原 src/app/forum/[name]/members.tsx）：proto 会员信息 + web 兜底/排行。
    case .forumMembers(let name, let forumId):
      return TiebaForumMembersViewController(name: name, forumId: forumId)
    // 帖子详情（原 src/app/thread/[id].tsx）：pbPage 数据 + post 行列表（主贴卡 +
    // 回复工具栏 = 第 0 行）；浮动胶囊/更多 sheet/跳页/点赞收藏删除全原生。
    case .thread(let id, let postId, let seeLz, let fromFavorites):
      return TiebaThreadViewController(
        threadId: id, postId: postId, seeLz: seeLz, fromFavorites: fromFavorites
      )
    // 楼中楼（原 src/app/thread/[id]/subposts.tsx）：pbFloor 数据 + post 行列表
    //（父楼 = 第 0 行）；点赞/删除/查看器/分页全在原生。
    case .subposts(let threadId, let postId, let forumId, let floor, let threadAuthorId, let forumName, let threadTitle):
      return TiebaSubpostsViewController(
        threadId: threadId,
        postId: postId,
        forumId: forumId,
        floor: floor,
        threadAuthorId: threadAuthorId,
        forumName: forumName,
        threadTitle: threadTitle
      )
    // 帖子「更多」sheet（原 src/app/thread/[id]/more.tsx）：行来自路由参数；
    // 动作经 TiebaThreadMoreSignal 交给帖子页（见该文件）。
    case .threadMore(let id, let canDelete, let seeLz, let reverse):
      return TiebaThreadMoreViewController(
        threadId: id, canDelete: canDelete, seeLz: seeLz, reverse: reverse
      )
    // 登录（原 src/app/login.tsx）：通行证 WKWebView + Cookie 提取 + 原生会话激活。
    case .login:
      return TiebaLoginViewController()
    // 账号管理（原 src/app/settings/account.tsx）：账号列表/切换/移除 + 退出登录。
    case .account:
      return TiebaAccountViewController()
    // 编辑资料（原 src/app/settings/edit-profile.tsx）：头像上传 + 昵称/性别/简介。
    case .editProfile:
      return TiebaEditProfileViewController()
    // 屏蔽设置（原 src/app/settings/block.tsx）：本地屏蔽项读写原生 KV。
    case .blockSettings:
      return TiebaBlockSettingsViewController()
    // 设置群（原 src/app/settings/{index,theme,habit,haptics,image,oksign,more}.tsx）：
    // 分组列表 = TiebaFormListView，偏好读写全原生（TiebaPreferences）。
    case .settings:
      return TiebaSettingsViewController()
    case .settingsTheme:
      return TiebaThemeSettingsViewController()
    case .settingsHabit:
      return TiebaHabitSettingsViewController()
    case .settingsHaptics:
      return TiebaHapticsSettingsViewController()
    case .settingsImage:
      return TiebaImageSettingsViewController()
    case .settingsOKSign:
      return TiebaOKSignViewController()
    case .settingsMore:
      return TiebaMoreSettingsViewController()
    // 话题详情（原 src/app/topic/[id].tsx）：feed 行 + 滚动页头，数据走 TiebaTopicAPI。
    case .topic(let id, let name):
      return TiebaTopicViewController(topicId: id, name: name)
    // 关注 tab 根屏（原 src/app/(tabs)/index.tsx）：顶栏 + 最近访问 + 关注吧列表。
    case .index:
      return TiebaHomeViewController()
    // 消息 tab 根屏（原 src/app/(tabs)/notifications.tsx）：三段消息列表 + 未读计数。
    // 深链的 initialTab 不入构造：由导航壳转交已常驻的根屏（receiveInitialTab）。
    case .notifications:
      return TiebaNotificationsViewController()
    // 我的 tab 根屏（原 src/app/(tabs)/profile.tsx）：用户卡片 + 设置表单。
    case .profile:
      return TiebaMyViewController()
    // 发现 tab 根屏（原 src/app/(tabs)/explore.tsx）：分段 + 推荐/关注/热榜三段。
    case .explore:
      return TiebaExploreViewController()
    // 搜索（原 src/app/search/index.tsx）：系统搜索栏 + 贴吧人三桶 + 历史。
    case .search(let keyword):
      return TiebaSearchViewController(initialKeyword: keyword)
    // 吧内搜索（原 src/app/forum/[name]/search.tsx）：排序/筛选 + 吧维度历史。
    case .forumSearch(let name, let forumId):
      return TiebaForumSearchViewController(name: name, forumId: forumId)
    // 用户主页（原 src/app/user/[uid].tsx）：资料卡滚动头 + 贴子/回复/关注的吧
    // 三段 + 粉丝关注 sheet。
    case .user(let uid, let tab):
      return TiebaUserProfileViewController(uid: uid, tab: tab ?? "")
    // 浏览记录（原 src/app/history.tsx）：visit_history 表 + 日期分组信息流卡片。
    case .history(let tab):
      return TiebaHistoryViewController(tab: tab ?? "")
    // 我的收藏（原 src/app/threadstore.tsx）：store_list + 本地图片快照 + 取消收藏。
    case .threadstore:
      return TiebaThreadStoreViewController()
    }
  }
}
