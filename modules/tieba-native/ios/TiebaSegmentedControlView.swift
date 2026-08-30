import ExpoModulesCore
import UIKit

/// 原生 UISegmentedControl 封装（iOS 26 液态分段视觉，系统绘制，ExpoUI
/// segmented Picker 同源组件）。
///
/// 为什么存在：吧页 segment 必须在 FlashList 列表头内才能随列表跟手滚动；
/// 该位置的 SwiftUI 控件嵌在二级 _UIHostingView 里触摸断链（expo#48212 系，
/// 8-25 真机复现：minHeight/宽度修复后仍点不到）。UIKit 控件在 RN 视图树内
/// 由 UIKit hit-test 直接命中，任意深度可点（HdrPressable/GlassView 同原理）。
///
/// 容器高度由 JS 侧给（44pt 点击区），控件自身居中（intrinsic ~32pt）。
public final class TiebaSegmentedControlView: ExpoView {
  // MARK: - Props

  /// 分段标题
  var titles: [String] = [] {
    didSet {
      if titles != oldValue { rebuild() }
    }
  }

  /// 当前选中下标（受控：JS 侧点击 pager 翻页时也会回写）
  var selectedIndex: Int = 0 {
    didSet {
      guard control.selectedSegmentIndex != selectedIndex else { return }
      if selectedIndex >= 0 && selectedIndex < control.numberOfSegments {
        control.selectedSegmentIndex = selectedIndex
      }
    }
  }

  let onValueChange = EventDispatcher()

  // MARK: - Private

  private let control = UISegmentedControl()

  public required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    // 液态玻璃修复（2026-08-30，expo/expo#45365 同根因）：UIView 默认
    // isOpaque == true——合成器认为本层不透明，会跳过其身后内容的合成，
    // iOS 26+ 分段控件的玻璃药丸拿不到采样素材，退化为平淡纯色胶囊。
    // 宿主与控件显式透明链（expo-ui 的 SwiftUI 宿主正是缺这一步）。
    isOpaque = false
    backgroundColor = .clear
    addSubview(control)
    control.translatesAutoresizingMaskIntoConstraints = false
    control.isOpaque = false
    control.backgroundColor = .clear
    NSLayoutConstraint.activate([
      control.leadingAnchor.constraint(equalTo: leadingAnchor),
      control.trailingAnchor.constraint(equalTo: trailingAnchor),
      control.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    control.addTarget(self, action: #selector(handleValueChanged), for: .valueChanged)
  }

  @objc private func handleValueChanged() {
    onValueChange(["index": control.selectedSegmentIndex])
  }

  private func rebuild() {
    control.removeAllSegments()
    for (i, title) in titles.enumerated() {
      control.insertSegment(withTitle: title, at: i, animated: false)
    }
    if selectedIndex >= 0 && selectedIndex < titles.count {
      control.selectedSegmentIndex = selectedIndex
    }
  }
}