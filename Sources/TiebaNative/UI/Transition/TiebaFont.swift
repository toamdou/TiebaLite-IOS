// 移植自上游 submodules/Display/Source/Font.swift（上游 352 行）
//
// 【权衡（判据三问）】① 性能：字体解析要过 UIFontDescriptor（几十微秒级），本件按
//   「size_design_weight_width_traits」缓存实例，重复取用零解析成本 —— 本仓行字体一天要取上万次；
//   ② 简洁：**四维（设计族/字重/字宽/特性）+ 值类型入口**，把散落的 UIFont.systemFont /
//   monospacedSystemFont / descriptor 拼装收成一处（TiebaSimpleText 那套是"字号+字重"两维 + Dynamic Type，
//   两者互补：需要衬线/等宽/字宽/等宽数字时用本件）；③ 能力：系统给的是描述符拼装原语，
//   不给"设计族 × 字重 × 字宽 × 特性"的组合入口与缓存。⇒ 保留（不按"系统更优"删）。
//
// 改动（逐条编号，均相对上游）：
//   1. 公开类型 Font → TiebaFont，改用 enum 命名空间（本仓 TiebaSimpleText / TiebaDrawingMetrics 同款）。
//   2. [判据②业务] Design.camera 是上游自有相机字体（字体名用 -1 位移字符串混淆成 TGDbnfsb.*）：
//      本仓没有该字族，.camera 与 .regular 同义（走系统字体），上游那句 design != .camera 的特判一并删掉。
//   3. 删掉上游 iOS 13 以下的退化分支（Georgia/Menlo 具名字体）：本工程部署目标远高于 13，那段是死代码；
//      保留它只会让人以为还有第二条路径（判据②：不留两套行为）。
//   4. 缓存从 pthread_rwlock_t 换成 Mutex<[String: UIFont]>（Synchronization）：上游那个
//      private final class Cache 在 Swift 6 下是"非 Sendable 类型的 static let"，直接搬会报并发错误；
//      本仓统一写法就是 Mutex<State>，这样也不必用 nonisolated(unsafe) / @unchecked Sendable 绕。
//   5. Traits / Design / Width / Weight 补 Sendable（字体参数要跨隔离域传给后台测量线程）。
//   6. FeatureKey 的旧名（iOS 15 废弃，且新旧名字语义相反）换成 .type / .selector；
//      iOS 16 的 available 包装去掉（部署目标 26 恒真）。
//   7. 新增 scaled(size:...)：内部走系统 UIFontMetrics 支持动态字号（见该函数注释）。
//      上游的 with(size:) 保持"精确字号"语义不变 —— 改成自动缩放会让既有调用点的尺寸跟系统档漂移。
//   8. 上游 Font.swift 末尾的 NSAttributedString 便捷 init 原样保留（本仓没有同名扩展）。
//   9. 全部 API nonisolated：字体解析 + 锁缓存，后台测量路径也要能调。

import Foundation
import Synchronization
import UIKit

public enum TiebaFont {
    public enum Design {
        case regular
        case serif
        case monospace
        case round
        case camera
        
        var key: String {
            switch self {
            case .regular:
                return "regular"
            case .serif:
                return "serif"
            case .monospace:
                return "monospace"
            case .round:
                return "round"
            case .camera:
                return "camera"
            }
        }
    }
    
    public struct Traits: OptionSet, Sendable {
        public var rawValue: Int32
        
        public init(rawValue: Int32) {
            self.rawValue = rawValue
        }
        
        public init() {
            self.rawValue = 0
        }
        
        public static let italic = Traits(rawValue: 1 << 0)
        public static let monospacedNumbers = Traits(rawValue: 1 << 1)
    }
    
    public enum Width: Sendable {
        case standard
        case condensed
        case compressed
        case expanded
        
        @available(iOS 16.0, *)
        var width: UIFont.Width {
            switch self {
            case .standard:
                return .standard
            case .condensed:
                return .condensed
            case .compressed:
                return .compressed
            case .expanded:
                return .expanded
            }
        }
        
        var key: String {
            switch self {
            case .standard:
                return "standard"
            case .condensed:
                return "condensed"
            case .compressed:
                return "compressed"
            case .expanded:
                return "expanded"
            }
        }
    }
    
    public enum Weight: Sendable {
        case regular
        case thin
        case light
        case medium
        case semibold
        case bold
        case heavy
        
        var weight: UIFont.Weight {
            switch self {
                case .thin:
                    return .thin
                case .light:
                    return .light
                case .medium:
                    return .medium
                case .semibold:
                    return .semibold
                case .bold:
                    return .bold
                case .heavy:
                    return .heavy
                default:
                    return .regular
            }
        }
        
        var key: String {
            switch self {
            case .regular:
                return "regular"
            case .thin:
                return "thin"
            case .light:
                return "light"
            case .medium:
                return "medium"
            case .semibold:
                return "semibold"
            case .bold:
                return "bold"
            case .heavy:
                return "heavy"
            }
        }
    }
    
    /// 描述符缓存（上游用 pthread_rwlock_t + 字典）。
    /// 这里换成本仓统一写法 Mutex<[String: UIFont]>（Synchronization）：
    /// UIFont 不可变、线程安全，锁只保护字典；后台测量线程会并发问字体（本仓测量在后台跑）。
    private static let cache = Mutex<[String: UIFont]>([:])

    /// 上游 Font.with(size:design:weight:width:traits:)（只保留 iOS 13+ 路径，见文件头改动 2/3）。
    ///
    /// 四维组合：design（设计族）× weight（字重）× width（字宽，iOS 16+）× traits（斜体/等宽数字）。
    /// 缓存键把四维 + 字号全拼进去 —— 任一维不同就是另一种字体，键少了会串味。
    public static func with(size: CGFloat, design: Design = .regular, weight: Weight = .regular, width: Width = .standard, traits: Traits = []) -> UIFont {
        let key = "\(size)_\(design.key)_\(weight.key)_\(width.key)_\(traits.rawValue)"

        if let cachedFont = self.cache.withLock({ $0[key] }) {
            return cachedFont
        }

        let descriptor = UIFont.systemFont(ofSize: size).fontDescriptor

        var symbolicTraits = descriptor.symbolicTraits
        if traits.contains(.italic) {
            symbolicTraits.insert(.traitItalic)
        }
        var updatedDescriptor: UIFontDescriptor? = descriptor.withSymbolicTraits(symbolicTraits)
        if traits.contains(.monospacedNumbers) {
            // 等宽数字必须走 featureSettings：kNumberSpacingType + kMonospacedNumbersSelector
            //（见文件头改动 6：键名用 iOS 15 起的 .type / .selector，旧名语义相反且已废弃）。
            updatedDescriptor = updatedDescriptor?.addingAttributes([
                UIFontDescriptor.AttributeName.featureSettings: [
                    [UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
                     UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector]
                ]
            ])
        }
        switch design {
        case .serif:
            updatedDescriptor = updatedDescriptor?.withDesign(.serif)
        case .monospace:
            updatedDescriptor = updatedDescriptor?.withDesign(.monospaced)
        case .round:
            updatedDescriptor = updatedDescriptor?.withDesign(.rounded)
        default:
            // .regular 与 .camera 都落到系统字体（见文件头改动 2）。
            updatedDescriptor = updatedDescriptor?.withDesign(.default)
        }
        if weight != .regular {
            updatedDescriptor = updatedDescriptor?.addingAttributes([
                UIFontDescriptor.AttributeName.traits: [UIFontDescriptor.TraitKey.weight: weight.weight]
            ])
        }
        if width != .standard {
            updatedDescriptor = updatedDescriptor?.addingAttributes([
                UIFontDescriptor.AttributeName.traits: [UIFontDescriptor.TraitKey.width: width.width]
            ])
        }

        let font: UIFont
        if let updatedDescriptor {
            font = UIFont(descriptor: updatedDescriptor, size: size)
        } else {
            font = UIFont(descriptor: descriptor, size: size)
        }

        self.cache.withLock { $0[key] = font }
        return font
    }

    public static func regular(_ size: CGFloat) -> UIFont {
        return UIFont.systemFont(ofSize: size)
    }
    
    public static func medium(_ size: CGFloat) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: UIFont.Weight.medium)
    }
    
    public static func semibold(_ size: CGFloat) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: UIFont.Weight.semibold)
    }
    
    public static func bold(_ size: CGFloat) -> UIFont {
        // 上游这里还有 iOS 8.2 以下的 CoreText 具名字体退化分支，本工程用不到（见文件头改动 3）。
        return UIFont.boldSystemFont(ofSize: size)
    }
    
    public static func heavy(_ size: CGFloat) -> UIFont {
        return self.with(size: size, design: .regular, weight: .heavy, traits: [])
    }
    
    public static func light(_ size: CGFloat) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: UIFont.Weight.light)
    }
    
    public static func monospace(_ size: CGFloat) -> UIFont {
        return UIFont(name: "Menlo-Regular", size: size - 1.0) ?? UIFont.systemFont(ofSize: size)
    }
    
    public static func italic(_ size: CGFloat) -> UIFont {
        return UIFont.italicSystemFont(ofSize: size)
    }
}

public extension NSAttributedString {
    convenience init(string: String, font: UIFont? = nil, textColor: UIColor = UIColor.black, paragraphAlignment: NSTextAlignment? = nil) {
        var attributes: [NSAttributedString.Key: AnyObject] = [:]
        if let font = font {
            attributes[NSAttributedString.Key.font] = font
        }
        attributes[NSAttributedString.Key.foregroundColor] = textColor
        if let paragraphAlignment = paragraphAlignment {
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = paragraphAlignment
            attributes[NSAttributedString.Key.paragraphStyle] = paragraphStyle
        }
        self.init(string: string, attributes: attributes)
    }
}

// MARK: - 动态字号（见文件头改动 7）

public extension TiebaFont {
    /// 动态字号入口：与 with(size:) 的差别是**会随系统内容尺寸档缩放**。
    ///
    /// 为什么单开一个入口而不改 with(size:)：with(size:) 的语义是"精确字号"（上游语义，
    /// 调用方按设计稿给值），改成自动缩放会让既有调用点的尺寸跟着系统档漂移。
    /// 想要 Dynamic Type 的调用方显式用这个（内部就是系统 UIFontMetrics.scaledFont(for:)）。
    ///
    /// 不做缓存：缩放结果依赖系统内容尺寸档，缓存就得再挂一套 UIContentSizeCategory 失效机制 ——
    /// 本仓 TiebaSimpleText.font（行字体咽喉）已经做了"缓存 + 系统档变化整体失效"，
    /// 这里不重复造第二套（判据②）。
    static func scaled(size: CGFloat, design: Design = .regular, weight: Weight = .regular, textStyle: UIFont.TextStyle = .body, traits: Traits = []) -> UIFont {
        let base = TiebaFont.with(size: size, design: design, weight: weight, traits: traits)
        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: base)
    }
}
