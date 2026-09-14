import UIKit

// 原生页面登记表（路由名 → UIViewController），唯一的一份路由 → 页面映射。
//
// 未登记的路由由 TiebaNavigator.makeHost 落 +not-found，绝无空白页。
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
}

public extension TiebaNativeScreen {
  var screenTitle: String? { nil }
  var preferredScreenStatusBarStyle: UIStatusBarStyle? { nil }
  var screenRightBarItems: [UIBarButtonItem]? { nil }
  var screenLeftBarItems: [UIBarButtonItem]? { nil }
}

/// 路由名 → 原生页面。**唯一**一处「哪些路由已经是原生的」的定义。
///
/// @MainActor：VC 构造必须在主线程；调用点在 TiebaNavigator.makeHost 的
/// MainActor.assumeIsolated 块内（导航壳的全部入口本来就在主线程，见其注释）。
///
/// ⚠️ 返回 nil = 路由未登记，调用方落 +not-found。
@MainActor
public enum TiebaNativeRouteTable {
  public static func make(_ route: TiebaRoute) -> UIViewController? {
    switch route.name {
    // 找不到页面（原 src/app/+not-found.tsx）：纯静态屏，无 store、无网络、不渲染参数。
    case "+not-found":
      return TiebaNotFoundViewController()
    // 关于（原 src/app/settings/about.tsx）：表单 + 原生更新检查 + 结果弹窗
    //（页面局部状态，不读共享 store；仅从原生 KV 现读 lightTheme/darkTheme）。
    case "settings/about":
      return TiebaAboutViewController()
    // 内置浏览器（原 src/app/webview.tsx）：工具栏 + WKWebView；参数 url/title
    // 走 TiebaRoute.params（原生解析，JS 侧不参与）。
    case "webview":
      return TiebaWebViewController(route: route)
    // 吧页（原 src/app/forum/[name].tsx）：frsPage proto + 关注/签到，滚动头 =
    // 吧名片/分段/排序/分类行，参数 name/forumId 由路由表解析。
    case "forum/[name]":
      return TiebaForumViewController(
        name: route.params["name"] ?? "",
        forumId: route.params["forumId"] ?? ""
      )
    // 吧三页（原 src/app/forum/[name]/{detail,rules,bawu}.tsx）：数据走 TiebaForumAPI，
    // 参数 name/forumId 由路由表解析。
    case "forum/[name]/detail":
      return TiebaForumDetailViewController(
        name: route.params["name"] ?? "",
        forumId: route.params["forumId"] ?? ""
      )
    case "forum/[name]/rules":
      return TiebaForumRulesViewController(
        name: route.params["name"] ?? "",
        forumId: route.params["forumId"] ?? ""
      )
    case "forum/[name]/bawu":
      return TiebaBawuTeamViewController(
        name: route.params["name"] ?? "",
        forumId: route.params["forumId"] ?? ""
      )
    // 吧成员（原 src/app/forum/[name]/members.tsx）：proto 会员信息 + web 兜底/排行，
    // 参数 name/forumId 由路由表解析。
    case "forum/[name]/members":
      return TiebaForumMembersViewController(
        name: route.params["name"] ?? "",
        forumId: route.params["forumId"] ?? ""
      )
    // 帖子详情（原 src/app/thread/[id].tsx）：pbPage 数据 + post 行列表（主贴卡 +
    // 回复工具栏 = 第 0 行）；浮动胶囊/更多 sheet/跳页/点赞收藏删除全原生。
    case "thread/[id]":
      return TiebaThreadViewController(route: route)
    // 楼中楼（原 src/app/thread/[id]/subposts.tsx）：pbFloor 数据 + post 行列表
    //（父楼 = 第 0 行）；点赞/删除/查看器/分页全在原生。
    case "thread/[id]/subposts":
      return TiebaSubpostsViewController(route: route)
    // 帖子「更多」sheet（原 src/app/thread/[id]/more.tsx）：行来自路由参数；
    // 动作经 TiebaThreadMoreSignal 交给帖子页（见该文件）。
    case "thread/[id]/more":
      return TiebaThreadMoreViewController(route: route)
    // 登录（原 src/app/login.tsx）：通行证 WKWebView + Cookie 提取 + 原生会话激活。
    case "login":
      return TiebaLoginViewController()
    // 账号管理（原 src/app/settings/account.tsx）：账号列表/切换/移除 + 退出登录。
    case "settings/account":
      return TiebaAccountViewController()
    // 编辑资料（原 src/app/settings/edit-profile.tsx）：头像上传 + 昵称/性别/简介。
    case "settings/edit-profile":
      return TiebaEditProfileViewController()
    // 屏蔽设置（原 src/app/settings/block.tsx）：本地屏蔽项读写原生 KV。
    case "settings/block":
      return TiebaBlockSettingsViewController()
    // 设置群（原 src/app/settings/{index,theme,habit,haptics,image,oksign,more}.tsx）：
    // 分组列表 = TiebaFormListView，偏好读写全原生（TiebaPreferences）。
    case "settings/index":
      return TiebaSettingsViewController()
    case "settings/theme":
      return TiebaThemeSettingsViewController()
    case "settings/habit":
      return TiebaHabitSettingsViewController()
    case "settings/haptics":
      return TiebaHapticsSettingsViewController()
    case "settings/image":
      return TiebaImageSettingsViewController()
    case "settings/oksign":
      return TiebaOKSignViewController()
    case "settings/more":
      return TiebaMoreSettingsViewController()
    // 话题详情（原 src/app/topic/[id].tsx）：feed 行 + 滚动页头，数据走 TiebaTopicAPI。
    case "topic/[id]":
      return TiebaTopicViewController(
        topicId: route.params["id"] ?? "",
        name: route.params["name"] ?? ""
      )
    // 关注 tab 根屏（原 src/app/(tabs)/index.tsx）：顶栏 + 最近访问 + 关注吧列表。
    case "index":
      return TiebaHomeViewController()
    // 消息 tab 根屏（原 src/app/(tabs)/notifications.tsx）：三段消息列表 + 未读计数。
    case "notifications":
      return TiebaNotificationsViewController()
    // 我的 tab 根屏（原 src/app/(tabs)/profile.tsx）：用户卡片 + 设置表单。
    case "profile":
      return TiebaMyViewController()
    // 发现 tab 根屏（原 src/app/(tabs)/explore.tsx）：分段 + 推荐/关注/热榜三段。
    case "explore":
      return TiebaExploreViewController()
    // 搜索（原 src/app/search/index.tsx）：系统搜索栏 + 贴吧人三桶 + 历史。
    case "search/index":
      return TiebaSearchViewController(initialKeyword: route.params["q"] ?? "")
    // 吧内搜索（原 src/app/forum/[name]/search.tsx）：排序/筛选 + 吧维度历史。
    case "forum/[name]/search":
      return TiebaForumSearchViewController(
        name: route.params["name"] ?? "",
        forumId: route.params["forumId"] ?? ""
      )
    // 用户主页（原 src/app/user/[uid].tsx）：资料卡滚动头 + 贴子/回复/关注的吧
    // 三段 + 粉丝关注 sheet；tab 参数由路由表解析。
    case "user/[uid]":
      return TiebaUserProfileViewController(
        uid: route.params["uid"] ?? "",
        tab: route.params["tab"] ?? ""
      )
    // 浏览记录（原 src/app/history.tsx）：visit_history 表 + 日期分组信息流卡片。
    case "history":
      return TiebaHistoryViewController(tab: route.params["tab"] ?? "")
    // 我的收藏（原 src/app/threadstore.tsx）：store_list + 本地图片快照 + 取消收藏。
    case "threadstore":
      return TiebaThreadStoreViewController()
    default:
      return nil
    }
  }
}
