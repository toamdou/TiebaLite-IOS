import UIKit

/// 「找不到页面」（原 `src/app/+not-found.tsx`）。
///
/// 第一个走 `TiebaNativeRouteTable` 的原生页面：纯 UIKit、零 Expo 依赖。
/// 页面本体就是这个类——过渡期由 TiebaRouteHostViewController 套一层壳，
/// 终局那层壳删掉时它一行都不用改。
///
/// 排版用系统的 `UIContentUnavailableConfiguration`（iOS 17+）而不是自绘竖排
/// 堆栈：旧页面是 SwiftUI 的 `ContentUnavailableView`，两者是同一套系统排版
/// （图标尺寸、字号、次级文字颜色、行距全由系统决定），自绘必然漂移。
public final class TiebaNotFoundViewController: UIViewController, TiebaNativeScreen {
  public override func viewDidLoad() {
    super.viewDidLoad()
    var config = UIContentUnavailableConfiguration.empty()
    config.image = UIImage(systemName: "questionmark.folder")
    config.text = "页面不存在"
    config.secondaryText = "你访问的链接可能已失效或不存在"

    // 旧页面是 SwiftUI `.glassProminent` + `.capsule`，UIKit 对应 iOS 26 的
    // Configuration.prominentGlass()（部署目标 26，无旧系统分支）。刻意不设 tintColor：
    // 资源目录无 AccentColor，旧页面 accent 就是系统默认蓝，设成应用主色反而会变。
    var button = UIButton.Configuration.prominentGlass()
    button.title = "返回首页"
    button.image = UIImage(systemName: "house")
    button.imagePadding = 6
    button.cornerStyle = .capsule
    config.button = button
    config.buttonProperties.primaryAction = UIAction { _ in
      // ⚠️ 不能 replace('/')：原生路由表按路径段解析，'/' 没有对应条目，会再次
      // 落回本页（无限套娃）。显式切 tab 0——selectTab 先把栈收敛回根屏，本页
      // 随即被 pop。（与旧页面 router.selectTab(0) 走的是同一条原生入口。）
      TiebaNavigator.shared.selectTab(0)
    }
    contentUnavailableConfiguration = config
  }
}
