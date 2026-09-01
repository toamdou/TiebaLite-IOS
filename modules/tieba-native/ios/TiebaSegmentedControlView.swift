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
    // 液态玻璃修复（2026-08-30 定案；8-31 被 7e83217 无说明回退，9-01 恢复）：
    // UIView 默认 isOpaque == true，合成器认为本层不透明、跳过其身后内容合成，
    // iOS 26+ 分段控件的玻璃药丸拿不到采样素材、退化为平淡纯色胶囊。
    // 宿主与控件显式透明链（expo-ui SwiftUI 宿主同根因 expo#44739/#45365）。
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

  // 9-01 第二轮：真机复现「消息页（固定位置）有玻璃、吧页/搜索页（LegendList
  // 列表头内）没有」——透明链只清自身+control 两层不够，列表头/滚动容器链上
  // 的祖先 UIView 仍默认 isOpaque=true、挡住身后内容合成。这里在挂窗与布局时
  // 沿 superview 链向上清整条透明链（RN 容器/ScrollView 包装层一并处理）。
  // 只清 isOpaque 不动 backgroundColor：isOpaque=false 仅告知合成器"本层可能
  // 透明、请继续合成身后内容"，视觉零影响；改背景色则会破坏 RN 容器样式。
  public override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil else { return }
    makeChainTransparent()
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    makeChainTransparent()
  }

  private func makeChainTransparent() {
    var ancestor = superview
    while let view = ancestor {
      view.isOpaque = false
      ancestor = view.superview
    }
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