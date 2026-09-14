import SwiftUI
import WidgetKit

@main
struct LiveActivityKitWidgetBundle: WidgetBundle {
  var body: some Widget {
    // 扩展部署底线 iOS 26（BUILD.bazel minimum_os_version），Live Activity 恒可用。
    LiveActivityKitLiveActivity()
  }
}
