// TiebaTypography —— 应用内字号体系（正文级 / 界面级 / 帖子标题独立档）
//
// 【用户口径 2026-10-06】设置→个性化→阅读字号：
//   · 正文级：动态页/吧页/搜索结果页的**帖子卡片**全部文字 + 帖子详情页的
//     正文 / 回复 / 楼中楼。偏好键 bodyFontSize（pt，12…24，默认 17）。
//   · 界面级：其余全部（导航栏、按钮、设置页、列表标题、meta 行、时间、徽章…）。
//     偏好键 uiFontSize（pt，12…24，默认 17）。
//   · 开关「界面字号跟随正文字号」uiFontFollowsBody（默认开）：开 ⇒ 界面级
//     隐藏且恒等于正文级；关 ⇒ 界面级独立生效。
//   · 帖子标题级：**只**管进入帖子后主贴卡片顶端的标题。偏好键
//     threadTitleFontSize（pt，14…34，默认 22）。它与正文级完全独立：调标题
//     不改正文/回复/楼中楼，调正文也不改标题；界面跟随开关同样不影响它。
//
// ── 为什么内部仍以**倍率**（scale）表达 ──
//   本仓在本次改造前已有「fontScale 倍率」这条成熟管线（TiebaFeedRowLayout /
//   TiebaPostRowPlan / TiebaPostRowText 全都按倍率缩放字号与行高，且行指纹里
//   已经含 fontScale）。把新体系的**绝对值 pt 换算成倍率**（size / 17）交给
//   那条管线，等于一次改造把「测量—绘制—缓存—指纹」四条链全部复用，不再
//   各写一套 pt 分支（判据②：不留两套行为）。
//
// ── 旧键迁移 ──
//   旧键 fontScale（0.8…2.0，默认 1）是**倍率**。首次读取时若 bodyFontSize
//   缺失而 fontScale 存在 ⇒ bodyFontSize = clamp(17 × fontScale, 12, 24)，
//   老用户的"大/特大"平滑落到新刻度上，不丢设置。迁移只读不写（写盘由用户
//   真正拖动滑杆时发生），因此不会在启动路径上产生副作用。
//
// ── 并发 ──
//   字号的读取遍布后台测量队列（行模型构造时每行都要问一次），所以快照走
//   Mutex 缓存：**读零 SQLite**。失效由 TiebaPreferenceChange 广播驱动
//   （主队列），失效后下一次读取重新解析一次偏好。
//
// ── 世代（generation）──
//   字号变化不能都混进同一个世代：界面字号只影响 chrome / 设置页，不应让帖子
//   行或信息流按新的内容身份重测；标题字号只影响主贴标题，不应把正文行一并
//   作废。这里保留 `generation` 作为既有 UI/chrome 失效信号（body/ui/follows
//   变化），另给出两个可精确比较的字段：
//     · textGeneration：正文字号变化（TiebaRowDiff 的正文测量链据此失效）；
//     · titleGeneration：帖子标题字号变化（帖子页返回时据此丢弃复用并重测）。
//   两者分开后，改标题不会碰 bodyScale，也不会让正文行以为内容变了。
import Foundation

nonisolated enum TiebaTypography {

  // MARK: - 偏好键

  static let bodySizeKey = "bodyFontSize"
  static let uiSizeKey = "uiFontSize"
  static let followsBodyKey = "uiFontFollowsBody"
  /// 帖子主贴标题独立字号（pt）。行 id 与偏好键同名（设置页直接复用）。
  static let titleSizeKey = "threadTitleFontSize"
  /// 旧键（倍率 0.8…2.0）：只用于一次性迁移，不再写入。
  static let legacyScaleKey = "fontScale"

  // MARK: - 基准与范围

  /// 正文/界面基准字号：换算倍率的分母。17pt ⇒ 倍率 1.0。
  static let referenceSize: Double = 17
  /// 正文/界面滑杆可调范围（pt）。无级（连续），步进由 0.1pt 量化给出。
  static let sizeRange: ClosedRange<Double> = 12...24
  /// 标题滑杆可调范围（pt）。比正文上限更高，给多行主贴标题留足高级档空间。
  static let titleSizeRange: ClosedRange<Double> = 14...34
  /// 标题倍率基准：默认标题 22pt ⇒ titleScale = 1.0。
  /// 行布局以 22pt 为字体基准、28pt 为行高基准，再乘 titleScale。
  static let titleReferenceSize: Double = 22
  /// 滑杆量化步长（0.1pt）：无级调节，但落盘值不会变脏。
  static let sizeStep: Double = 0.1

  static let defaultBodySize: Double = referenceSize
  static let defaultUISize: Double = referenceSize
  static let defaultTitleSize: Double = titleReferenceSize
  static let defaultFollowsBody = true

  /// 旧倍率的合法域（与 TiebaFeedRowModel / TiebaPostRowModel 的钳制一致）。
  private static let legacyScaleRange: ClosedRange<Double> = 0.8...2.0

  /// 本体系的偏好键（TiebaPreferenceSnapshot 写盘后据此决定要不要刷快照）。
  static func isTypographyKey(_ key: String) -> Bool {
    // 含旧键：本仓在改造过渡期仍会把正文倍率镜像写回 fontScale（兼容未改造的
    // 读取方），那也算一次字号变化，快照必须跟着重解析。
    key == bodySizeKey || key == uiSizeKey || key == followsBodyKey
      || key == titleSizeKey || key == legacyScaleKey
  }

  // MARK: - 快照

  struct Snapshot: Sendable, Equatable {
    /// 正文字号（pt，已钳制到 sizeRange）。
    let bodySize: Double
    /// 界面字号（pt，已钳制；followsBody 时它不参与生效值，但仍保留用户上次的选择）。
    let uiSize: Double
    /// 帖子主贴标题字号（pt，已钳制到 titleSizeRange）。与 bodySize 独立。
    let titleSize: Double
    let followsBody: Bool

    /// 正文级倍率（喂给 TiebaFeedRowLayout / TiebaPostRowPlan 的 fontScale）。
    var bodyScale: Double { bodySize / referenceSize }
    /// 界面级的**生效**字号（跟随打开时 = 正文字号）。
    var effectiveUISize: Double { followsBody ? bodySize : uiSize }
    /// 界面级倍率。
    var uiScale: Double { effectiveUISize / referenceSize }
    /// 帖子标题倍率（22pt ⇒ 1.0）。独立于 bodyScale。
    var titleScale: Double { titleSize / titleReferenceSize }
  }

  private struct State {
    var snapshot: Snapshot?
    /// 既有 UI/chrome 世代：body/ui/follows 变化都会 +1（标题变化不需要 chrome 重刷）。
    var generation: UInt64 = 0
    /// 正文字号世代：只有 bodySize 真变化才 +1，供正文行测量链使用。
    var textGeneration: UInt64 = 0
    /// 帖子标题字号世代：只有 titleSize 真变化才 +1，供帖子页标题重测使用。
    var titleGeneration: UInt64 = 0
  }

  private static let state = TiebaMutex<State>(State())

  // MARK: - 读

  /// 当前字号快照（进程内缓存；偏好变更广播时失效）。
  static func snapshot() -> Snapshot {
    if let cached = state.withLock({ $0.snapshot }) { return cached }
    return reload()
  }

  /// 正文级倍率（正文文本/行高的**唯一**缩放入口）。
  static func bodyScale() -> CGFloat { CGFloat(snapshot().bodyScale) }

  /// 界面级倍率（界面文本/行高的**唯一**缩放入口）。
  static func uiScale() -> CGFloat { CGFloat(snapshot().uiScale) }

  /// 帖子标题倍率（22pt 基准；只供主贴标题字体/行高使用）。
  static func titleScale() -> CGFloat { CGFloat(snapshot().titleScale) }

  /// 既有 UI/chrome 世代：body/ui/follows 变化 +1。标题变化不碰它，避免把
  /// 信息流行指纹一起改掉。
  static var generation: UInt64 { _ = snapshot(); return state.withLock { $0.generation } }

  /// 正文字号世代。消费方：TiebaRowDiff 的正文行指纹。
  static var textGeneration: UInt64 {
    _ = snapshot()
    return state.withLock { $0.textGeneration }
  }

  /// 帖子标题字号世代。消费方：TiebaPostListPageController.viewWillAppear。
  /// 它只代表标题字号变化，不携带正文倍率，也不改 bodyScale。
  static var titleGeneration: UInt64 {
    _ = snapshot()
    return state.withLock { $0.titleGeneration }
  }

  /// 系统 Dynamic Type 档位变化：内容字号不是偏好滑块，但同样会改变每一行的
  /// 测量结果。前进世代，让 TiebaRowDiff 的内容身份整体失配并触发重测。
  static func invalidateForSystemContentSizeCategoryChange() {
    state.withLock { state in
      state.generation &+= 1
      state.textGeneration &+= 1
    }
  }

  /// 界面字号当前是否跟随正文（设置页据此显隐滑杆）。
  static var followsBody: Bool { snapshot().followsBody }

  /// 重新解析偏好并刷新缓存。偏好广播与设置页写盘后调用。
  @discardableResult
  static func reload() -> Snapshot {
    let next = Snapshot(
      bodySize: clampSize(readBodySize()),
      uiSize: clampSize(TiebaPreferences.number(uiSizeKey, default: defaultUISize)),
      titleSize: clampTitleSize(
        TiebaPreferences.number(titleSizeKey, default: defaultTitleSize)),
      followsBody: TiebaPreferences.bool(followsBodyKey, default: defaultFollowsBody)
    )
    state.withLock { state in
      let previous = state.snapshot
      guard previous != next else { return }
      state.snapshot = next
      // 首次加载/任意 UI 或正文字号变化：既有 chrome/font 失效信号前进一格。
      // 标题变化**不**动 generation：标题只播种帖子标题行，不能把信息流行指纹
      // 也一并作废；需要标题精确失效的消费方读 titleGeneration。
      if previous == nil
        || previous?.bodySize != next.bodySize
        || previous?.uiSize != next.uiSize
        || previous?.followsBody != next.followsBody
      {
        state.generation &+= 1
      }
      if previous == nil || previous?.bodySize != next.bodySize {
        state.textGeneration &+= 1
      }
      if previous == nil || previous?.titleSize != next.titleSize {
        state.titleGeneration &+= 1
      }
    }
    return next
  }

  /// 设置页写盘时用：把一个 pt 值量化成落盘形态（0.1pt 网格、钳制到范围）。
  /// 正文与界面字号共用 12…24 范围；标题走下面的 quantizeTitleSize。
  static func quantize(_ size: Double) -> Double {
    quantize(size, in: sizeRange, fallback: referenceSize)
  }

  /// 帖子标题字号量化（14…34pt，0.1pt 网格）。标题滑杆单独走这里，复用正文
  /// 范围的 quantize 会把它钳到 24 并静默丢掉大标题档。
  static func quantizeTitleSize(_ size: Double) -> Double {
    quantize(size, in: titleSizeRange, fallback: defaultTitleSize)
  }

  private static func quantize(
    _ size: Double,
    in range: ClosedRange<Double>,
    fallback: Double
  ) -> Double {
    guard size.isFinite else { return fallback }
    let stepped = ((size / sizeStep).rounded() * sizeStep * 10).rounded() / 10
    return min(max(stepped, range.lowerBound), range.upperBound)
  }

  static func clampSize(_ size: Double) -> Double {
    guard size.isFinite else { return referenceSize }
    return min(max(size, sizeRange.lowerBound), sizeRange.upperBound)
  }

  static func clampTitleSize(_ size: Double) -> Double {
    guard size.isFinite else { return defaultTitleSize }
    return min(max(size, titleSizeRange.lowerBound), titleSizeRange.upperBound)
  }

  /// 旧倍率 → 新 pt（迁移用；也是外部（如设置页显示）需要的换算）。
  static func size(forLegacyScale scale: Double) -> Double {
    clampSize(referenceSize * min(max(scale, legacyScaleRange.lowerBound), legacyScaleRange.upperBound))
  }

  // MARK: - 迁移

  /// 正文字号的读取：新键优先；缺新键时用旧倍率 fontScale 平滑换算。
  private static func readBodySize() -> Double {
    if let size = TiebaPreferenceSnapshot.number(bodySizeKey) { return size }
    if let legacy = TiebaPreferenceSnapshot.number(legacyScaleKey) { return size(forLegacyScale: legacy) }
    return defaultBodySize
  }

  // MARK: - 自检

  /// 调用点：测试目标，或调试期手动 _ = TiebaTypography.selfCheck()（本仓既有约定，
  /// 见 TiebaRowDiff.selfCheck）。返回 nil = 全过。
  ///
  /// 覆盖三件事（第三件在 UI 层，见下）：
  ///   ① 倍率换算：17pt ⇒ 1.0；12pt ⇒ 12/17；24pt ⇒ 24/17；越界钳回范围；
  ///      量化到 0.1pt（不产生 17.030000000000001 这种脏值）；
  ///   ② 旧键迁移：fontScale 1.0 ⇒ 17pt、1.3 ⇒ 22.1pt、0.5/3.0 ⇒ 钳到 12/24；
  ///   ③ 标题独立档：22pt ⇒ titleScale 1、14/34pt ⇒ 14/22、34/22；
  ///      改标题不改 bodyScale，标题量化/钳制不会落进正文范围。
  ///
  /// ④「字号变了必须同时改字与行盒」拿的是**真实测量链**（TiebaFeedRowLayout /
  ///   TiebaSimpleText / TiebaPostRowLayout），而那些是行布局、属 UI/ListKit ——
  ///   Core 不许反向引用它们（依赖倒置）。这一段因此挂在 UI 层：
  ///   TiebaTypography.selfCheckRowChain()（UI/ListKit/TiebaTypographyRowCheck.swift）。
  ///   两半一起跑：_ = TiebaTypography.selfCheck() ?? TiebaTypography.selfCheckRowChain()
  static func selfCheck() -> String? {
    var failures: [String] = []
    func expect(_ ok: Bool, _ label: String) {
      if !ok { failures.append(label) }
    }

    // ① 换算
    expect(
      abs(Snapshot(bodySize: 17, uiSize: 17, titleSize: 22, followsBody: true).bodyScale - 1)
        < 1e-9,
      "17pt 倍率不是 1")
    expect(
      abs(
        Snapshot(bodySize: 12, uiSize: 12, titleSize: 22, followsBody: false).bodyScale
          - 12.0 / 17) < 1e-9,
      "12pt 倍率不对")
    expect(
      abs(
        Snapshot(bodySize: 24, uiSize: 24, titleSize: 22, followsBody: false).uiScale
          - 24.0 / 17) < 1e-9,
      "24pt 界面倍率不对")
    expect(clampSize(3) == sizeRange.lowerBound, "小越界没钳到 12")
    expect(clampSize(99) == sizeRange.upperBound, "大越界没钳到 24")
    expect(quantize(17.030000000000001) == 17.0, "量化没收敛到 0.1pt")
    expect(quantize(17.06) == 17.1, "量化没四舍五入到 0.1pt")

    // ② 迁移
    expect(size(forLegacyScale: 1) == 17, "旧倍率 1 没迁到 17pt")
    expect(abs(size(forLegacyScale: 1.3) - 22.1) < 1e-9, "旧倍率 1.3 没迁到 22.1pt")
    expect(size(forLegacyScale: 0.5) == sizeRange.lowerBound, "旧倍率过小没钳")
    expect(size(forLegacyScale: 3) == sizeRange.upperBound, "旧倍率过大没钳")

    // ③ 标题独立档
    let defaultTitle = Snapshot(
      bodySize: 17, uiSize: 17, titleSize: defaultTitleSize, followsBody: true)
    let smallTitle = Snapshot(
      bodySize: 17, uiSize: 17, titleSize: titleSizeRange.lowerBound, followsBody: true)
    let largeTitle = Snapshot(
      bodySize: 17, uiSize: 17, titleSize: titleSizeRange.upperBound, followsBody: true)
    expect(abs(defaultTitle.titleScale - 1) < 1e-9, "默认标题 22pt 倍率不是 1")
    expect(
      abs(smallTitle.titleScale - titleSizeRange.lowerBound / titleReferenceSize) < 1e-9,
      "14pt 标题倍率不对")
    expect(
      abs(largeTitle.titleScale - titleSizeRange.upperBound / titleReferenceSize) < 1e-9,
      "34pt 标题倍率不对")
    expect(defaultTitle.bodyScale == largeTitle.bodyScale, "标题字号改动了正文字号")
    expect(clampTitleSize(3) == titleSizeRange.lowerBound, "标题小越界没钳到 14")
    expect(clampTitleSize(99) == titleSizeRange.upperBound, "标题大越界没钳到 34")
    expect(quantizeTitleSize(22.04) == 22.0, "标题量化没收敛到 0.1pt")
    expect(quantizeTitleSize(33.96) == 34.0, "标题量化没四舍五入到 0.1pt")
    expect(isTypographyKey(titleSizeKey), "标题偏好键没纳入字号快照刷新")

    return failures.isEmpty ? nil : failures.joined(separator: " / ")
  }
}
