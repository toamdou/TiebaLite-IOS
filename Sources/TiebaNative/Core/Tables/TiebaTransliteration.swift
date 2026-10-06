// 西里尔/希腊字母 → 拉丁转写（外加一遍去组合音标）。
//
// 移植自上游 `submodules/StringTransliteration/Sources/StringTransliteration.m`
// 与公开头 `submodules/StringTransliteration/PublicHeaders/StringTransliteration/StringTransliteration.h`。
// 上游是 postbox 时代留下的一个 C 函数：`postboxTransformedString(CFStringRef, bool, bool)`。
//
// 用途：Tieba 侧是**搜索归一化**——俄语/希腊语的吧名（如 "Москва" 吧）用拉丁转写
// 建索引，用户敲 "moskva" 也能命中。顺带：ICU 的 toLatin 对汉字出拼音，
// 所以 `searchFolded("中文") == "zhong wen"`，中文吧名也能用拼音搜。
//
// 相对上游的改动（逐条）：
//   1. 全局 C 函数 + CFStringRef + 两个裸 bool → Swift enum 下的具名函数：
//      `transformed(_:replaceWithTransliterated:appendTransliterated:)` 保留原语义，
//      另拆出 `stripped(_:)` / `latin(_:)` 两个单步入口（上游只能整调用，
//      想单独去音标得自己重写一遍 CFStringTransform）。
//   2. CFStringTransform(CFMutableStringRef, …) 原地改可变字符串 →
//      `String.applyingTransform(_:reverse:)`。它返回 Optional：上游遇到
//      transform 失败会把**部分转换**的结果返回给调用方（可变串被就地改了），
//      这里改成"失败即返回入参"，语义更可预期。
//   3. 保留上游的**转换顺序**：先 stripCombiningMarks 再 toLatin。
//      顺序有可观察差异：先 strip 的话汉字会带拼音声调（"zhōng"），
//      先 toLatin 再 strip 才是 "zhong"；`transformed` 逐字照抄上游顺序，
//      只有新增的 `searchFolded` 才做两遍 strip（见其注释）。
//   4. 上游三个参数是 (string, replace, append)：replace 与 append 同时为 true 时
//      replace 优先（append 分支根本走不到）。这里保留同样的优先级并写进文档。
//   5. 新增 `searchFolded(_:)`（搜索归一化入口，本任务点名要的零件）与
//      `#if DEBUG` 自检 debugSelfCheck()。
//   6. 无状态：CFStringTransform 是线程安全的纯函数，整个 enum nonisolated，不需要 @MainActor。
import Foundation

/// 字符串转写与搜索归一化。
enum TiebaTransliteration {
  /// 只去掉组合音标（café → cafe）。对应上游第一遍 CFStringTransform。
  static func stripped(_ string: String) -> String {
    string.applyingTransform(.stripCombiningMarks, reverse: false) ?? string
  }

  /// 拉丁转写（Москва → Moskva）。上游只在 replace/append 打开时才做这一步。
  static func latin(_ string: String) -> String {
    string.applyingTransform(.toLatin, reverse: false) ?? string
  }

  /// 上游 `postboxTransformedString` 的直译。
  ///
  /// - Parameters:
  ///   - replaceWithTransliterated: 用转写结果**替换**原串。
  ///   - appendTransliterated: 原串 + 空格 + 转写结果。
  ///     两个都开时按上游语义以 replace 为准。
  static func transformed(
    _ string: String,
    replaceWithTransliterated: Bool,
    appendTransliterated: Bool
  ) -> String {
    let withoutMarks = stripped(string)
    guard replaceWithTransliterated || appendTransliterated else {
      return withoutMarks
    }
    let transliterated = latin(withoutMarks)
    if replaceWithTransliterated {
      return transliterated
    }
    return withoutMarks + " " + transliterated
  }

  /// 搜索键归一化（本仓新增，上游没有这个入口）。
  ///
  /// 小写 → 去组合音标 → 拉丁转写 → 再去一遍音标（第二遍是为了清掉 toLatin 生成的
  /// 拼音声调符号，"中" 因此得 "zhong" 而不是 "zhōng"）。
  ///
  /// 只做归一化，不做标点剔除/分词：那属于搜索层策略（要不要保留空格、要不要切词），
  /// 放在这里会把两件事粘死。调用方拿到的保证是"同一串永远归一成同一串"。
  static func searchFolded(_ string: String) -> String {
    let lowered = string.lowercased()
    let latinized = latin(stripped(lowered))
    return stripped(latinized)
  }

  #if DEBUG
    /// 已知值自检。**当前无人调用**（本任务不接线）。
    /// 期望值取自 ICU 的 toLatin（即 ISO 9 / ISO 843 那套转写），
    /// 不是"看着像就对"，改 Foundation 版本后若变了会在这里炸。
    static func debugSelfCheck() {
      // 去音标
      assert(stripped("café") == "cafe", stripped("café"))
      assert(stripped("naïve") == "naive", stripped("naïve"))
      assert(stripped("plain") == "plain")

      // 西里尔
      assert(latin("Москва") == "Moskva", latin("Москва"))
      assert(latin("Привет") == "Privet", latin("Привет"))
      assert(latin("Санкт-Петербург") == "Sankt-Peterburg", latin("Санкт-Петербург"))
      // 希腊
      assert(latin("Ελλάδα") == "Elláda", latin("Ελλάδα"))
      assert(stripped(latin("Ελλάδα")) == "Ellada", stripped(latin("Ελλάδα")))
      // ICU 对 η 用 ē（古希腊式），不是现代希腊语的 i —— 这是 ICU 的选择，上游同此；
      // 想要现代式转写必须自己维护字母表，不在本次移植范围。
      assert(latin("Αθήνα") == "Athḗna", latin("Αθήνα"))

      // 上游语义：replace / append / 都不开
      assert(transformed("Москва", replaceWithTransliterated: true, appendTransliterated: false) == "Moskva")
      assert(
        transformed("Москва", replaceWithTransliterated: false, appendTransliterated: true)
          == "Москва Moskva")
      assert(
        transformed("Москва", replaceWithTransliterated: false, appendTransliterated: false) == "Москва")
      // 两个都开 → replace 优先（上游分支顺序如此）
      assert(transformed("Москва", replaceWithTransliterated: true, appendTransliterated: true) == "Moskva")
      // 去音标发生在转写之前，所以 append 的结果里原串也是去过音标的
      assert(
        transformed("café", replaceWithTransliterated: false, appendTransliterated: true) == "cafe cafe")

      // 搜索归一化：大小写/重音/字母表三个维度一起折叠
      assert(searchFolded("Москва") == "moskva", searchFolded("Москва"))
      assert(searchFolded("МОСКВА") == "moskva", searchFolded("МОСКВА"))
      assert(searchFolded("München") == "munchen", searchFolded("München"))
      assert(searchFolded("Ελλάδα") == "ellada", searchFolded("Ελλάδα"))
      // 汉字走 ICU 的 Han-Latin（拼音），声调符号在第二遍 strip 里被清掉
      assert(searchFolded("中文") == "zhong wen", searchFolded("中文"))
      assert(searchFolded("") == "")
    }
  #endif
}
