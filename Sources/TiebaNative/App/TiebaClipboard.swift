// 系统剪贴板（UIPasteboard.general）——替代 expo-clipboard。
//
// 为什么只做"字符串"三件事：全仓调用只有写字符串（复制链接/标题）与读字符串
// （剪贴板链接识别）两类，url / image / html 三种格式零调用。旧包 iOS 侧的
// getStringAsync 读的也是 general.string、setStringAsync 写的也是
// general.string——换实现不能换剪贴板：写进 UIPasteboard(name:) 或某个
// WKWebView 的选择剪贴板，用户在系统其它 App 里就复制/粘贴不到。
//
// iOS 16+ 的粘贴提示（2026-09-12 核对）：programmatic 读 general.string 会弹
// 系统"允许粘贴"提示，旧包同样弹——expo-clipboard 没有 detectPatterns 预检，
// 也没有 UIPasteControl 之类的抑制手段，本文件不引入任何抑制（用户侧的闸门是
// 设置→使用习惯→剪贴板链接识别：关闭时 useClipboardDetector 连读都不发生）。
// 系统限制下"剪贴板为空"与"用户拒绝粘贴"都只能看到 nil，旧包同样返回空串，
// 这里保持同一语义——不编造第二个错误通道。
//
// 线程：UIPasteboard 是 UIKit 对象，只在主线程碰。@JS 同步成员跑在 JS 线程
//（DispatchQueue.main.sync 在"主线程等 JS"时会死锁，见 navGoBack 注释），
// 所以整个类型 @MainActor 隔离、原生入口一律 async（与 TiebaCookieStore 同款）。
import UniformTypeIdentifiers
import UIKit

@MainActor
enum TiebaClipboard {
  static func setString(_ text: String) {
    UIPasteboard.general.string = text
  }

  /// 空剪贴板 / 粘贴被拒 → 空串（旧包 getStringAsync 同语义）。
  static func getString() -> String {
    UIPasteboard.general.string ?? ""
  }

  /// 旧包语义 = hasStrings || hasHTML，其中 hasHTML 是 expo 自己的扩展：
  /// contains([public.html, public.rtf])——从 Safari 等复制的富文本只带 HTML/RTF
  /// 表示时 hasStrings 为 false，这里按同款类型查询补齐。两个查询都只查类型、
  /// 不读内容，不触发粘贴提示。
  static func hasString() -> Bool {
    UIPasteboard.general.hasStrings
      || UIPasteboard.general.contains(
        pasteboardTypes: [UTType.html.identifier, UTType.rtf.identifier]
      )
  }
}
