// tab 索引常量（**顺序 = 路由表声明顺序**，与屏幕上的排列无关；侧边栏编辑会改
// 视觉顺序，所以索引不能从 UI 上数）。
//
// 依赖倒置：Core 里的后台通知器要给"消息"tab 挂角标，原来直接读 App 层的
// `TiebaAppBootstrap.notificationsTabIndex` —— 下层反向依赖上层。常量本身是路由
// 事实（和 TiebaRoutePath 同层），所以搬到 Core/Routing，bootstrap 改为引用这里。

enum TiebaTabIndex {
  /// 消息 tab。
  static let notifications = 2
}
