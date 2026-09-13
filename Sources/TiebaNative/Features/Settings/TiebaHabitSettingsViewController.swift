// ============================================================
// TiebaHabitSettingsViewController —— 使用习惯（原 src/app/settings/habit.tsx）
//
// 全部行直接经 TiebaPreferences 读写；每个开关/选择器先 fire('toggle') 再落库
//（与旧页一致）。枚举选择器的当前值必须过白名单（脏值不得直通消费侧）；布尔行
// id 与偏好键逐字同名。
// ============================================================
import UIKit

final class TiebaHabitSettingsViewController: TiebaFormPageController {
  private static let startTabs: [(value: String, label: String)] = [
    ("index", "关注"), ("explore", "动态"), ("notifications", "消息"), ("profile", "我的"),
  ]
  private static let sortTypes: [(value: String, label: String)] = [
    ("0", "按回复时间"), ("1", "按发贴时间"),
  ]
  private static let fabFunctions: [(value: String, label: String)] = [
    ("refresh", "刷新"), ("back_to_top", "回到顶部"), ("hide", "不显示"),
  ]
  private static let timestampStyles: [(value: String, label: String)] = [
    ("relative", "相对时间（刚刚、x分钟前）"), ("absolute", "绝对时间（年-月-日 时:分）"),
  ]

  /// 默认值必须与 constants/preferences.ts 的 DEFAULT_PREFERENCES 一致：
  /// 键缺失（用户从未改过）时界面显示的就是默认档。
  private func toggle(
    _ id: String, _ title: String, _ icon: String, default fallback: Bool,
    subtitle: String? = nil
  ) -> [String: Any] {
    var row: [String: Any] = [
      "id": id, "kind": "toggle", "title": title, "icon": icon,
      "value": TiebaPreferences.bool(id, default: fallback) ? "1" : "0",
    ]
    row["subtitle"] = subtitle
    return row
  }

  override func makeSections(dark: Bool) -> [[String: Any]] {
    let startTab = TiebaPreferences.string(
      "startTab", allowed: Self.startTabs.map(\.value), default: "index")
    let timestamp = TiebaPreferences.string(
      "timestampStyle", allowed: Self.timestampStyles.map(\.value), default: "relative")
    // 这两个枚举也走白名单（TiebaForumViewController 直接消费，脏值不能直通）。
    let sortType = TiebaPreferences.string(
      "defaultSortType", allowed: Self.sortTypes.map(\.value), default: "0")
    let fabFunction = TiebaPreferences.string(
      "forumFabFunction", allowed: Self.fabFunctions.map(\.value), default: "refresh")

    return [
      [
        "title": "首页",
        "rows": [
          toggle("homePageShowHistoryForum", "显示历史吧", "clock.fill", default: true),
          toggle("forumListSingle", "关注吧列表单列", "list.bullet", default: true),
          [
            "id": "startTab", "kind": "picker", "title": "启动默认页",
            "value": startTab, "options": options(Self.startTabs),
          ],
        ],
      ],
      [
        "title": "浏览",
        "rows": [
          toggle("incognitoMode", "无痕模式", "theatermasks.fill", default: false),
          toggle("useBuiltInBrowser", "使用内置浏览器", "safari.fill", default: true),
          toggle("exploreAutoRefresh", "自动刷新动态", "arrow.clockwise", default: true),
          toggle("clipboardLinkDetection", "剪贴板链接识别", "doc.on.clipboard", default: true),
          toggle("navBarDoubleTapToTop", "双击顶栏回顶", "arrow.up.circle", default: true),
          toggle(
            "tabBarMinimizeEnabled", "底栏滚动收纳", "menubar.rectangle", default: true,
            subtitle: "下滑收起底部栏、上滑恢复；关闭后底栏常驻"),
          [
            "id": "defaultSortType", "kind": "picker", "title": "吧默认排序方式",
            "value": sortType, "options": options(Self.sortTypes),
          ],
          toggle("hideMedia", "隐藏媒体内容", "photo.on.rectangle.angled", default: false),
        ],
      ],
      [
        "title": "贴子",
        "rows": [
          toggle("showBothUsername", "显示两个用户名", "person.2.fill", default: false),
          toggle("showShortcutInThread", "贴内显示快捷按钮", "bolt.fill", default: true),
          [
            "id": "forumFabFunction", "kind": "picker", "title": "悬浮按钮功能",
            "value": fabFunction, "options": options(Self.fabFunctions),
          ],
          [
            "id": "timestampStyle", "kind": "picker", "title": "时间显示格式",
            "value": timestamp, "options": options(Self.timestampStyles),
          ],
          toggle("showIpLocation", "显示 IP 属地", "location.fill", default: true),
          toggle("showLevelBadge", "显示等级徽标", "shield.fill", default: true),
        ],
      ],
      [
        "title": "内容",
        "rows": [
          toggle("hideBlockedContent", "隐藏屏蔽内容", "nosign", default: false),
          toggle("blockVideo", "不显示视频贴", "video.slash.fill", default: false),
          toggle(
            "filterAdThreads", "过滤广告与直播贴", "cup.and.saucer.fill", default: true,
            subtitle: "关闭后信息流与吧内的广告、直播卡片原样展示"),
        ],
      ],
      [
        "title": "收藏",
        "rows": [
          toggle("collectSeeLz", "收藏贴子只看楼主", "person.fill", default: true),
          toggle("collectDescSort", "收藏贴子倒序查看", "arrow.up.arrow.down", default: false),
        ],
      ],
    ]
  }

  override func handle(_ event: TiebaFormEvent) {
    switch event {
    case .toggle(let id, let value):
      TiebaSceneHaptics.fire("toggle")
      guard write(id, bool: value) else { return }
      // 底栏收纳立即生效（原生壳的唯一开关入口；JS 侧内存副本见报告）。
      if id == "tabBarMinimizeEnabled" {
        TiebaNavigator.shared.setTabBarMinimizeEnabled(value)
      }
    case .pick:
      TiebaSceneHaptics.fire("toggle")
      // 行 id 与偏好键逐字同名（见 makeSections）：落库 + 回推走基类默认实现。
      super.handle(event)
    default:
      super.handle(event)
    }
  }
}
