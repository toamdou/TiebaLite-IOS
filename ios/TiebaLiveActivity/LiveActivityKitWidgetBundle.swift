import SwiftUI
import WidgetKit

@main
struct LiveActivityKitWidgetBundle: WidgetBundle {
  var body: some Widget {
    if #available(iOS 16.1, *) {
      LiveActivityKitLiveActivity()
    }
  }
}
