import ExpoModulesCore
import UIKit

/// 系统原生 UISearchBar 封装（搜索页「系统原生样式」直出，不手绘胶囊）。
///
/// 为什么存在：搜索页此前两轮都是自绘搜索行，用户两次反馈「搜索栏不是系统
/// 原生样式」（2026-08-27）——自绘胶囊与系统搜索框仍有观感落差；直接托管
/// UISearchBar，外观/键盘/取消钮全部由系统承担。
///
/// 放在 FlashList 列表头内随滚动退出（用户拍板的「随滚退出」契约）：
/// UIKit 控件在 RN 视图树内由 UIKit hit-test 直接命中，任意深度可点
/// （TiebaSegmentedControl/GlassSurface 同原理）。
///
/// 受控 text：JS 下发值经 didSet 下行；事件上行（textDidChange）时置
/// applyingText 防回声。showsCancelButton 由 JS 按「有文字」切换
/// （iOS 规范：无输入不出现取消钮）。
public final class TiebaSearchBarView: ExpoView, UISearchBarDelegate {
  // MARK: - Props

  /// 占位文案
  var placeholder: String = "" {
    didSet { searchBar.placeholder = placeholder }
  }

  /// 受控文本（JS 状态下行；事件上行期间不回写）
  var text: String = "" {
    didSet {
      guard !applyingText, searchBar.text != text else { return }
      searchBar.text = text
    }
  }

  /// 是否显示系统取消钮
  var showCancel: Bool = false {
    didSet {
      guard showCancel != oldValue else { return }
      // animated:false —— 2026-08-27 真机：取消钮滑入动画 + 搜索框宽度
      // 收缩表现为"从右往左移动极小距离"（用户两次反馈）；瞬时切换无位移。
      searchBar.setShowsCancelButton(showCancel, animated: false)
    }
  }

  /// 进入页面自动聚焦弹键盘（搜索页规范；置空/已出结果后不再打扰）
  var autoFocus: Bool = false {
    didSet {
      if autoFocus, !oldValue { scheduleFocusIfNeeded() }
    }
  }

  let onTextChange = EventDispatcher()
  let onSubmit = EventDispatcher()
  let onCancel = EventDispatcher()

  // MARK: - Private

  private let searchBar = UISearchBar()
  /// 事件上行期间的文本回声闸：textDidChange → onTextChange → JS setState →
  /// didSet 下行 → 与当前值相同即跳过（guard searchBar.text != text）
  private var applyingText = false
  private var focusScheduled = false

  public required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    searchBar.delegate = self
    searchBar.searchBarStyle = .minimal
    searchBar.returnKeyType = .search
    searchBar.enablesReturnKeyAutomatically = false
    searchBar.autocorrectionType = .no
    searchBar.autocapitalizationType = .none
    searchBar.setShowsCancelButton(false, animated: false)
    addSubview(searchBar)
    scheduleFocusIfNeeded()
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    // 容器高度由 JS 给（36pt 输入行）；搜索框撑满容器，放大镜/输入/取消
    // 由系统按 iOS 26 液态视觉排布。
    searchBar.frame = bounds
    scheduleFocusIfNeeded()
  }

  /// 自动弹键盘：进入页面时一次；已聚焦过/已有文字则不再弹。
  private func scheduleFocusIfNeeded() {
    guard autoFocus, text.isEmpty, !focusScheduled else { return }
    focusScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
      guard let self, self.autoFocus, self.text.isEmpty, !self.searchBar.isFirstResponder else { return }
      self.searchBar.becomeFirstResponder()
    }
  }

  // MARK: - UISearchBarDelegate

  public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
    applyingText = true
    onTextChange(["text": searchText])
    applyingText = false
  }

  public func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
    onSubmit(["text": searchBar.text ?? ""])
  }

  public func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
    searchBar.resignFirstResponder()
    onCancel([:])
  }
}