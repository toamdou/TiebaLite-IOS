// 移植自上游 submodules/Display/Source/ContainerViewLayout.swift（上游 210 行）
//
// 【权衡（判据三问）】① 性能：值类型一次装配、逐层传值，页面不再各自读 view.bounds/safeAreaInsets
//   （多份副本必然漂移）；装配成本就是一次结构体构造；
//   ② 简洁：一处收口 vs 散落 —— 页面拿一个值就能回答「我有多宽 / 被谁让位 / 键盘多高 / 是不是分屏」，
//   不必自己拼 traitCollection + safeAreaInsets + keyboardLayoutGuide；
//   ③ 能力：系统给的是**原始输入**（各类 inset / 尺寸类），不给「页面级入参」这个打包值，
//   也不给按机型算标准键盘/输入高度。
//   ⇒ 保留（不按"系统更优"删）。装配入口见文件尾 make(for:)。
//
// 改动（逐条编号，均相对上游）：
//   1. 公开类型全部加 Tieba 前缀，避免与本仓/系统重名。
//   2. deviceMetrics 的类型用同目录 TiebaDeviceMetrics（见该文件头的保留理由）。
//   3. Swift 6：全部结构都是纯值类型，一律补 Sendable；这里不碰 UIView，全是纯计算，保持 nonisolated。
//   4. 除以上外逐行照搬：withUpdated* / addedInsets / insets(options:) 的语义、分屏比例容差（0.04）、
//      Slide Over 的 10pt 容差、朝向比较等数值一个字没改。
//   5. [接线新增] 文件尾加装配入口 make(for: view)：UIKit 现场 → 页面级布局入参
//      （上游散在 WindowContent.swift:87-119/:235；本仓多个页面壳都要装配，故收口）。
//      它是本文件唯一 @MainActor 的成员。

import Foundation
import UIKit

public struct TiebaContainerViewLayoutInsetOptions: OptionSet, Sendable {
    public let rawValue: Int
    
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
    
    public init() {
        self.rawValue = 0
    }
    
    public static let statusBar = TiebaContainerViewLayoutInsetOptions(rawValue: 1 << 0)
    public static let input = TiebaContainerViewLayoutInsetOptions(rawValue: 1 << 1)
}

public enum TiebaContainerViewLayoutSizeClass: Sendable {
    case compact
    case regular
}

public struct TiebaLayoutMetrics: Equatable, Sendable {
    public let widthClass: TiebaContainerViewLayoutSizeClass
    public let heightClass: TiebaContainerViewLayoutSizeClass
    public let orientation: UIInterfaceOrientation?
    
    public init(widthClass: TiebaContainerViewLayoutSizeClass, heightClass: TiebaContainerViewLayoutSizeClass, orientation: UIInterfaceOrientation?) {
        self.widthClass = widthClass
        self.heightClass = heightClass
        self.orientation = orientation
    }
    
    public init() {
        self.widthClass = .compact
        self.heightClass = .compact
        self.orientation = nil
    }
}

public extension TiebaLayoutMetrics {
}

public enum TiebaLayoutOrientation: Sendable {
    case portrait
    case landscape
}

public struct TiebaContainerViewLayout: Equatable, Sendable {
    public var size: CGSize
    public var metrics: TiebaLayoutMetrics
    public var deviceMetrics: TiebaDeviceMetrics
    public var intrinsicInsets: UIEdgeInsets
    public var safeInsets: UIEdgeInsets
    public var additionalInsets: UIEdgeInsets
    public var statusBarHeight: CGFloat?
    public var inputHeight: CGFloat?
    public var inputHeightIsInteractivelyChanging: Bool
    public var inVoiceOver: Bool
    
    public init(size: CGSize, metrics: TiebaLayoutMetrics, deviceMetrics: TiebaDeviceMetrics, intrinsicInsets: UIEdgeInsets, safeInsets: UIEdgeInsets, additionalInsets: UIEdgeInsets, statusBarHeight: CGFloat?, inputHeight: CGFloat?, inputHeightIsInteractivelyChanging: Bool, inVoiceOver: Bool) {
        self.size = size
        self.metrics = metrics
        self.deviceMetrics = deviceMetrics
        self.intrinsicInsets = intrinsicInsets
        self.safeInsets = safeInsets
        self.additionalInsets = additionalInsets
        self.statusBarHeight = statusBarHeight
        self.inputHeight = inputHeight
        self.inputHeightIsInteractivelyChanging = inputHeightIsInteractivelyChanging
        self.inVoiceOver = inVoiceOver
    }
}

public extension TiebaContainerViewLayout {
    func insets(options: TiebaContainerViewLayoutInsetOptions) -> UIEdgeInsets {
        var insets = self.intrinsicInsets
        if let statusBarHeight = self.statusBarHeight, options.contains(.statusBar) {
            insets.top = max(statusBarHeight, insets.top)
        }
        if let inputHeight = self.inputHeight, options.contains(.input) {
            insets.bottom = max(inputHeight, insets.bottom)
        }
        return insets
    }
    
    var deviceOrientationSize: CGSize {
        let screenSize = self.deviceMetrics.screenSize
        return self.actualOrientation == .landscape ? CGSize(width: screenSize.height, height: screenSize.width) : screenSize
    }
    
    var actualOrientation: TiebaLayoutOrientation {
        let screenPortraitHeight = max(self.deviceMetrics.screenSize.width, self.deviceMetrics.screenSize.height)
        let screenPortraitWidth = min(self.deviceMetrics.screenSize.width, self.deviceMetrics.screenSize.height)
        
        let deltaPortrait = abs(self.size.height - screenPortraitHeight)
        let deltaLandscape = abs(self.size.height - screenPortraitWidth)
        
        return deltaLandscape < deltaPortrait ? .landscape : .portrait
    }
    
    var orientation: TiebaLayoutOrientation {
        return self.size.width > self.size.height ? .landscape : .portrait
    }
    
    var standardInputHeight: CGFloat {
        return self.deviceMetrics.standardInputHeight(inLandscape: self.orientation == .landscape)
    }
}


// MARK: - UIKit 现场 → 页面级布局入参（见文件头改动 5）

public extension TiebaContainerViewLayout {
    /// 用「承载页面的那个视图」装配一份布局入参。
    ///
    /// 各字段来源：
    ///   size / safeInsets / intrinsicInsets ← 视图自己的 bounds 与 safeAreaInsets（intrinsic 目前同值）
    ///   statusBarHeight ← 所在窗口场景的 statusBarManager（拿不到就是 nil，不是 0）
    ///   inputHeight ← 恒 nil：本仓不跟踪键盘高度（要跟踪的页面自己拿 keyboardLayoutGuide）
    ///   deviceMetrics ← 屏幕尺寸 + scale + 状态栏高（用于分屏/Slide Over/键盘高度判定）
    @MainActor
    static func make(for view: UIView) -> TiebaContainerViewLayout {
        let bounds = view.bounds
        let safeInsets = view.safeAreaInsets
        let trait = view.traitCollection
        let scene = view.window?.windowScene
        let screen = scene?.screen
        // 屏幕尺寸取本视图所在场景的屏幕（UIScreen.main 在 iOS 26 已弃用且是主 actor 隔离）；
        // 场景还没挂上时退化成自身尺寸，至少保证 size/safeInsets 自洽。
        let screenSize = screen?.bounds.size ?? bounds.size
        let scale = screen?.scale ?? trait.displayScale
        let statusBarHeight = scene?.statusBarManager?.statusBarFrame.height
        let widthClass: TiebaContainerViewLayoutSizeClass =
            trait.horizontalSizeClass == .regular ? .regular : .compact
        let heightClass: TiebaContainerViewLayoutSizeClass =
            trait.verticalSizeClass == .regular ? .regular : .compact
        return TiebaContainerViewLayout(
            size: bounds.size,
            metrics: TiebaLayoutMetrics(
                widthClass: widthClass,
                heightClass: heightClass,
                // iOS 26 起 UIWindowScene.interfaceOrientation 废弃，改读 effectiveGeometry。
                orientation: scene?.effectiveGeometry.interfaceOrientation
            ),
            deviceMetrics: TiebaDeviceMetrics(
                screenSize: screenSize,
                scale: max(scale, 1.0),
                statusBarHeight: statusBarHeight ?? 0.0,
                onScreenNavigationHeight: nil
            ),
            intrinsicInsets: safeInsets,
            safeInsets: safeInsets,
            additionalInsets: .zero,
            statusBarHeight: statusBarHeight,
            inputHeight: nil,
            inputHeightIsInteractivelyChanging: false,
            inVoiceOver: UIAccessibility.isVoiceOverRunning
        )
    }
}
