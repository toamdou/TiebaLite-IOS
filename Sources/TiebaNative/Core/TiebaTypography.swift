// TiebaTypography —— 应用内**两级字号体系**（正文级 / 界面级）
//
// 【用户口径 2026-10-06】设置→个性化→阅读字号：
//   · 正文级：动态页/吧页/搜索结果页的**帖子卡片**全部文字 + 帖子详情页的
//     正文 / 回复 / 楼中楼。偏好键 bodyFontSize（pt，12…24，默认 17）。
//   · 界面级：其余全部（导航栏、按钮、设置页、列表标题、meta 行、时间、徽章…）。
//     偏好键 uiFontSize（pt，12…24，默认 17）。
//   · 开关「界面字号跟随正文字号」uiFontFollowsBody（默认开）：开 ⇒ 界面级
//     隐藏且恒等于正文级；关 ⇒ 界面级独立生效。
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
//   任何一次字号变化都会 +1。它被混进 TiebaRowDiff 的行指纹 ⇒ 全仓所有
//   按「内容身份」键控的度量缓存（TiebaRowStore / TiebaSimpleRowMetrics /
//   TiebaPageStore 的页索引）一次性全部失配、自动重测。这是本仓
//   「字号改了但行族还是旧档」那个坑的**结构性**解法：不逐个缓存去清，
//   而是让"字体变了"直接体现为"这一行是另一行内容"。
import Foundation

nonisolated enum TiebaTypography {

  // MARK: - 偏好键

  static let bodySizeKey = "bodyFontSize"
  static let uiSizeKey = "uiFontSize"
  static let followsBodyKey = "uiFontFollowsBody"
  /// 旧键（倍率 0.8…2.0）：只用于一次性迁移，不再写入。
  static let legacyScaleKey = "fontScale"

  // MARK: - 基准与范围

  /// 基准字号：换算倍率的分母。17pt ⇒ 倍率 1.0 ⇒ 与改造前**逐像素相同**。
  static let referenceSize: Double = 17
  /// 滑杆可调范围（pt）。无级（连续），步进由滑杆的 0.1pt 量化给出。
  static let sizeRange: ClosedRange<Double> = 12...24
  /// 滑杆量化步长（0.1pt）：无级调节，但落盘值不会变成 17.030000000000001。
  static let sizeStep: Double = 0.1

  static let defaultBodySize: Double = referenceSize
  static let defaultUISize: Double = referenceSize
  static let defaultFollowsBody = true

  /// 旧倍率的合法域（与 TiebaFeedRowModel / TiebaPostRowModel 的钳制一致）。
  private static let legacyScaleRange: ClosedRange<Double> = 0.8...2.0

  /// 本体系的偏好键（TiebaPreferenceSnapshot 写盘后据此决定要不要刷快照）。
  static func isTypographyKey(_ key: String) -> Bool {
    // 含旧键：本仓在改造过渡期仍会把正文倍率镜像写回 fontScale（兼容未改造的
    // 读取方），那也算一次字号变化，快照必须跟着重解析。
    key == bodySizeKey || key == uiSizeKey || key == followsBodyKey || key == legacyScaleKey
  }

  // MARK: - 快照

  struct Snapshot: Sendable, Equatable {
    /// 正文字号（pt，已钳制到 sizeRange）。
    let bodySize: Double
    /// 界面字号（pt，已钳制；followsBody 时它不参与生效值，但仍保留用户上次的选择）。
    let uiSize: Double
    let followsBody: Bool

    /// 正文级倍率（喂给 TiebaFeedRowLayout / TiebaPostRowPlan 的 fontScale）。
    var bodyScale: Double { bodySize / referenceSize }
    /// 界面级的**生效**字号（跟随打开时 = 正文字号）。
    var effectiveUISize: Double { followsBody ? bodySize : uiSize }
    /// 界面级倍率。
    var uiScale: Double { effectiveUISize / referenceSize }
  }

  private struct State {
    var snapshot: Snapshot?
    var generation: UInt64 = 0
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

  /// 字号世代：任何一次生效字号变化 +1。混进行指纹用（见文件头）。
  static var generation: UInt64 { _ = snapshot(); return state.withLock { $0.generation } }

  /// 界面字号当前是否跟随正文（设置页据此显隐滑杆）。
  static var followsBody: Bool { snapshot().followsBody }

  /// 重新解析偏好并刷新缓存。偏好广播与设置页写盘后调用。
  @discardableResult
  static func reload() -> Snapshot {
    let next = Snapshot(
      bodySize: clampSize(readBodySize()),
      uiSize: clampSize(TiebaPreferences.number(uiSizeKey, default: defaultUISize)),
      followsBody: TiebaPreferences.bool(followsBodyKey, default: defaultFollowsBody)
    )
    state.withLock { state in
      guard state.snapshot != next else { return }
      state.snapshot = next
      state.generation &+= 1
    }
    return next
  }

  /// 设置页写盘时用：把一个 pt 值量化成落盘形态（0.1pt 网格、钳制到范围）。
  static func quantize(_ size: Double) -> Double {
    let stepped = (size / sizeStep).rounded() * sizeStep
    return clampSize((stepped * 10).rounded() / 10)
  }

  static func clampSize(_ size: Double) -> Double {
    guard size.isFinite else { return referenceSize }
    return min(max(size, sizeRange.lowerBound), sizeRange.upperBound)
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
  /// 见 TiebaRowFingerprint.selfCheck / TiebaRowDiff.selfCheck）。返回 nil = 全过。
  ///
  /// 覆盖两件事（第三件在 UI 层，见下）：
  ///   ① 倍率换算：17pt ⇒ 1.0；12pt ⇒ 12/17；24pt ⇒ 24/17；越界钳回范围；
  ///      量化到 0.1pt（不产生 17.030000000000001 这种脏值）；
  ///   ② 旧键迁移：fontScale 1.0 ⇒ 17pt、1.3 ⇒ 22.1pt、0.5/3.0 ⇒ 钳到 12/24。
  ///
  /// ③「字号变了必须同时改字与行盒」拿的是**真实测量链**（TiebaFeedRowLayout /
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
    expect(abs(Snapshot(bodySize: 17, uiSize: 17, followsBody: true).bodyScale - 1) < 1e-9, "17pt 倍率不是 1")
    expect(
      abs(Snapshot(bodySize: 12, uiSize: 12, followsBody: false).bodyScale - 12.0 / 17) < 1e-9,
      "12pt 倍率不对")
    expect(
      abs(Snapshot(bodySize: 24, uiSize: 24, followsBody: false).uiScale - 24.0 / 17) < 1e-9,
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

    return failures.isEmpty ? nil : failures.joined(separator: " / ")
  }
}
