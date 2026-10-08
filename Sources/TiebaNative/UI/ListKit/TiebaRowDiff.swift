// TiebaLite — 行差量（TiebaRowDiff）
//
// 一行的身份 = **内容指纹**（fingerprint(of:)，与位置无关），不再是它在页里的下标。
// 有了身份，两次发布之间的差异就能用 早期 vendored 的 Support 模块 的
// tiebaMergeListsStableWithUpdates(leftList:rightList:isLess:isEqual:getId:)
// 算成三元组：
//   (删除下标 [], [(插入下标, 行, 旧下标?)], [(更新下标, 行, 旧下标)])
// TiebaRowPageDriver.publish 每次发布算一份（存 lastRowDiff），**只算不接**：列表的
// 唯一入口仍是 setPage(pageKey:)，差量还没有消费方（接法见 Driver.lastRowDiff 的注释）。
//
// ── 为什么指纹是**整行**，而不是 TiebaRowFingerprint 的渲染字段白名单 ──
//   TiebaRowPageDriver 是通用列表页共用的（feed / simple / post 三族，见
//   TiebaKindRowPage），而 TiebaRowFingerprint 的白名单只覆盖 **feed** 行的渲染输入。
//   message / userProfile / 搜索历史这类 simple 行的键名（id / text / value / …）基本不在
//   白名单里 —— 那一页的每一行都会算出**同一个**指纹，"有一行变了"于是会被误判成
//   "只是追加"：页键不换 ⇒ 列表不重建 ⇒ 画面停在旧内容上。可见行为被改坏，而且不报错。
//   所以这里对整行做**规范序列化**求哈希（判据与旧的"整页 NSDictionary 深比较"等价：
//   同样的"逐字段相同"），代价从"每行一次 ObjC 桥接递归比较"降到"每行一次纯算术混合"，
//   且旧行指纹可随 lastRows 缓存，不必每次重算（这是相对旧 isAppend 的真正便宜处）。
//   将来 TiebaRowFingerprint 的白名单覆盖到 simple 行后，可以换成它 —— 但要连同
//   "指纹只覆盖渲染输入 ⇒ 时间文案等键不算变化"这个语义变化一起评估（那会改变页键决策）。
//
// ── 混合器复用 ──
//   直接复用 TiebaRowFingerprint.Mixer（已审计的跨进程稳定混合：FNV-1a + splitmix64 收尾，
//   字符串走 vendored persistentHashValue），本文件只加自己的值域分隔 + 版本号，不重抄一遍
//   哈希算法。
//
// ── 并发 ──
//   纯函数、无共享状态（只有 let 常量）⇒ nonisolated，主线程（发布路径）直接调用。
//
// ── 元素级增删动画的基座思路（只记录，本文件不落地）──
//   借鉴自上游（Vendor/ComponentFlow/Sources/Base/Transition.swift，上游
//   submodules/ComponentFlow：插入/删除/移动**由框架驱动**——appear / disappear / update
//   三个钩子 + guide 位移锚点，:383-386；动画"断点续传"从 presentation layer 的当前值出发，
//   :245-261）：过渡不是"整块重排 + 补动画"，而是**元素级**的——新元素知道从哪来、走的元素
//   知道到哪去、被挪动的元素按 guide 补一段。前提是元素各自有一份稳定身份与差量。
//   接收方现状：差量停在**行级**（本文件的三元组），而且只算不接
//（TiebaRowPageDriver.publish 算完存 lastRowDiff，列表唯一入口仍是 setPage）；行内元素
//（某段文案 / 某张图 / 某个 chip）增删只会整行重配，没有身份、也没有自己的过渡。
//   将来真要做元素级过渡，入口就在这里：把行内元素也做指纹 + 差量（判据复用本文件），
//   再由行视图按 (插入 / 删除 / 更新) 给元素补过渡，而不是引入 ComponentFlow。

import Foundation
// [收敛] 原 import 上游 Support 模块 —— 见 TiebaRowFingerprint.swift 同处说明。

/// 行内容指纹 + 行差量（删除 / 插入 / 更新三元组）。
public nonisolated enum TiebaRowDiff {

  // MARK: - 版本与值域

  /// 指纹算法版本：改键序规则 / 类型分档 / 混合方式都必须 +1。
  public static let version: UInt64 = 1

  /// 值域分隔：本文件的指纹与别的指纹（共用同一套 Mixer）切开，两家算法各自演进也不会撞。
  private static let domain: UInt64 = 0x5449_4542_4152_4F57  // "TIEBAROW"

  // MARK: - 行指纹

  /// 行字典 → 内容指纹（64 位、跨进程稳定、**与位置无关**）。
  ///
  /// 规范序列化：字典键按 UTF-8 字节序排序后逐项混（键名先混 = 域分隔），值按类型分档，
  /// 数组保序、字典递归。字符串一律走 vendored `Mixer.mix(String)` → `persistentHashValue`，
  /// **不用** `String.hashValue` / Hasher（每进程随机种子，两次启动两个数）。
  ///
  /// 与旧判据（`(row as NSDictionary).isEqual(to:)`）的对应：
  ///   - true ≡ 1、3 ≡ 3.0：NSNumber 只比值不比类型 ⇒ 同指纹（不凭空多出"变了"）；
  ///   - 缺键 ≠ NSNull、1 ≠ "1"、数组顺序敏感、字典键序不敏感 ⇒ 与旧判据一致。
  /// 唯一的方向性差异是哈希碰撞（不同内容同指纹 → 判成"没变"）：64 位下可忽略。
  public static func fingerprint(of row: [String: Any]) -> UInt64 {
    var mixer = TiebaRowFingerprint.Mixer()
    mixer.mix(domain)
    mixer.mix(version)
    // 字号世代（TiebaTypography.generation）：字号一变，**每一行**的指纹都变 ⇒
    // 全仓按「内容身份」键控的度量缓存（TiebaRowStore / TiebaSimpleRowMetrics /
    // 页索引）自动整体失配并重测。这是"字号改了但行族还停在旧档"那个坑的结构性
    // 解法：不逐个缓存去清（清漏一处就是静默旧档），而是让"字体变了"直接等于
    // "这一行是另一行内容"。世代只在字号真的变化时 +1，稳态下是常量，不影响
    // 跨页/跨屏复用命中率。
    mixer.mix(TiebaTypography.generation)
    // 外观档世代（TiebaListAppearance.generation）：卡片 ↔ 扁平切换会改**每一行**的
    // 边距/圆角/底色 ⇒ 行几何全变，旧测量必须整体失配重测。与字号世代同一个槽位、
    // 同一条理由（见 TiebaListAppearance 文件头）：让"换档"直接等于"这是另一行内容"。
    mixer.mix(TiebaListAppearance.generation)
    mixValue(row, into: &mixer)
    return mixer.value
  }

  /// 值的类型档：同一次混入里当类型标签用（"1" 与 1 不能撞）。
  private enum Tag {
    static let absent: UInt64 = 1       // 键缺席（NSNull 另有一档）
    static let null: UInt64 = 2         // NSNull
    static let text: UInt64 = 3
    static let int: UInt64 = 4
    static let double: UInt64 = 5
    static let array: UInt64 = 6
    static let dictionary: UInt64 = 7
    static let other: UInt64 = 8
  }

  /// 字典：键**排序**后逐项混。Swift 字典的迭代序取决于插入历史与每进程哈希种子，
  /// 不排序 = 同一份内容可能算出两个指纹（"没变"被判成"变了" → 无谓整页重载）。
  private static func mixDictionary(_ dict: [String: Any], into mixer: inout TiebaRowFingerprint.Mixer) {
    mixer.mix(Tag.dictionary)
    mixer.mix(UInt64(dict.count))
    var keys = Array(dict.keys)
    keys.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    for key in keys {
      mixer.mix(key)                       // 键名先混：两个字段互换值不会撞
      mixValue(dict[key], into: &mixer)    // 缺席（absent）与 NSNull 不同档
    }
  }

  private static func mixValue(_ value: Any?, into mixer: inout TiebaRowFingerprint.Mixer) {
    guard let value else {
      mixer.mix(Tag.absent)
      return
    }
    if value is NSNull {
      mixer.mix(Tag.null)
      return
    }
    if let text = value as? String {
      mixer.mix(Tag.text)
      mixer.mix(text)
      return
    }
    if let number = value as? NSNumber {
      // CFBoolean 也是 NSNumber：先按布尔判，落到 0/1 整数档（与旧 NSNumber 判据同语义）。
      if CFGetTypeID(number) == CFBooleanGetTypeID() {
        mixer.mix(Tag.int)
        mixer.mix(UInt64(number.boolValue ? 1 : 0))
        return
      }
      if !CFNumberIsFloatType(number) {
        mixer.mix(Tag.int)
        mixer.mix(number.int64Value)
        return
      }
      let double = number.doubleValue
      if double.isFinite, double == double.rounded(), abs(double) < 9.0e18 {
        mixer.mix(Tag.int)                 // 3.0 与 3 同档（同一个数在桥上整/浮表示不稳定）
        mixer.mix(Int64(double))
        return
      }
      mixer.mix(Tag.double)
      mixer.mix(double)
      return
    }
    if let array = value as? [Any] {
      mixer.mix(Tag.array)
      mixer.mix(UInt64(array.count))
      for element in array {
        mixValue(element, into: &mixer)
      }
      return
    }
    if let dict = value as? [String: Any] {
      mixDictionary(dict, into: &mixer)
      return
    }
    // JS 桥只送 String / NSNumber / NSNull / NSArray / NSDictionary，到不了这里。
    // 真出现也**不混 description**（可能含地址 / 时区，跨进程不稳定），只混类型名。
    mixer.mix(Tag.other)
    mixer.mix(String(describing: type(of: value)))
  }

  // MARK: - 行条目（带指纹的身份）

  /// 参与 merge 的一行：行字典 + 预计算指纹 + 同指纹出现序号 + 它在本列表里的位置。
  ///
  /// 指纹只在 `entries(for:)` 里算一次（O(行数)），merge 全程复用，不重复求哈希。
  public struct Entry {
    /// 行字典（与推给列表的是同一份）。
    public let row: [String: Any]
    /// 内容指纹，见 `fingerprint(of:)`。
    public let fingerprint: UInt64
    /// **同一列表内**指纹相同的行按出现顺序编号（0, 1, 2 …），只为让身份唯一：
    /// merge 的 DEBUG 分支对"同一列表里 id 重复"直接 `assertionFailure()`（会崩），
    /// 而完全相同的行是真实存在的（重复广告行 / 占位行 / 空行）。
    /// 它是"第几个同内容行"，不是下标——整页平移或前插时同一行的序号不变。
    public let duplicateOrdinal: Int
    /// 本行在**它所属那次发布**里的位置。只给 merge 的排序判据 `isLess` 用（见 `make`），
    /// **不参与身份**（身份只看指纹 + 序号）。
    public let index: Int

    /// merge 的身份：内容指纹 + 同指纹序号（与位置无关）。
    // [采用] 显式 Sendable：它成为 TiebaKindItem 的身份字段后要跨 diffable 传递；
    // public struct 没有隐式 Sendable 一致性（成员全是 UInt64/Int，本就可安全跨域）。
    public struct Identity: Hashable, Sendable {
      public let fingerprint: UInt64
      public let ordinal: Int
    }

    public var identity: Identity { Identity(fingerprint: fingerprint, ordinal: duplicateOrdinal) }
  }

  /// 给一页行字典算指纹（一次 O(行数)，含同指纹序号）。
  public static func entries(for rows: [[String: Any]]) -> [Entry] {
    var ordinals: [UInt64: Int] = [:]
    ordinals.reserveCapacity(rows.count)
    var result: [Entry] = []
    result.reserveCapacity(rows.count)
    for (index, row) in rows.enumerated() {
      let fingerprint = fingerprint(of: row)
      let ordinal = ordinals[fingerprint, default: 0]
      ordinals[fingerprint] = ordinal + 1
      result.append(Entry(row: row, fingerprint: fingerprint, duplicateOrdinal: ordinal, index: index))
    }
    return result
  }

  // MARK: - 差量

  /// 一次插入：(当前页下标, 行, 旧页下标?)。
  public struct Insertion {
    /// 删完 + 应用了前面若干插入**之后**的当前页下标。
    public let index: Int
    /// 新行（带指纹，可直接拼进下一页的 `Entry` 数组）。
    public let entry: Entry
    /// 这行内容原来在旧页的位置；nil = 全新行（旧页没有同内容行）。
    public let previousIndex: Int?
    public var row: [String: Any] { entry.row }
  }

  /// 一次更新：(当前页下标, 行, 旧页下标)。
  public struct Update {
    public let index: Int
    public let entry: Entry
    public let previousIndex: Int
    public var row: [String: Any] { entry.row }
  }

  /// 一次发布的差量。
  public struct Change {
    /// 删除：**旧页**下标（升序）。消费方按**倒序**逐个删（与 merge 内部写法一致）。
    public let removals: [Int]
    public let insertions: [Insertion]
    /// 更新。**当前判据下恒空**：身份 = 内容指纹 ⇒ getId 相同必然 isEqual 相同，走不到
    /// update 分支（除非 allUpdated = true）。字段保留是为了接法完整：将来若身份换成
    /// "帖 id"之类（内容变了身份不变），那类变化就落这里。
    public let updates: [Update]

    public var isEmpty: Bool { removals.isEmpty && insertions.isEmpty && updates.isEmpty }
    public static var empty: Change { Change(removals: [], insertions: [], updates: []) }
  }

  /// 旧页是否逐行原样出现在新页开头（新页 = 旧页 + 尾部）= 驱动判"纯追加"的快速路径。
  ///
  /// 只比 `(指纹, 同指纹序号)`：一次 UInt64 比较，不做任何字典递归，第一处不同立即退
  /// （换数据 / 换排序在第 0 行就退，与旧实现同样的早期退出）。与"跑 merge 再看
  /// 删除/更新是否为空"**不等价**——头部插入也是"删 0 更新 0"，但那不是追加，
  /// 页键必须换（旧实现同样按前缀判，见 Driver.isAppend）。
  public static func isPrefix(left: [Entry], right: [Entry]) -> Bool {
    guard left.count <= right.count else { return false }
    for index in left.indices where left[index].identity != right[index].identity {
      return false
    }
    return true
  }

  /// 纯追加（新页 = 旧页 + 尾部）的差量，直接构造、**不跑 merge**：删 0、更新 0、
  /// 尾部逐行插入（previousIndex = nil）。
  /// 分页追加是"每次滚到底"都发生的那条路，必须只付 O(新增行数)（前缀已由 isPrefix 判定
  /// 逐行同身份）；merge 对这个输入类返回的正是同一三元组，selfCheck ④ 逐例验证。
  public static func tailAppend(of entries: [Entry], after count: Int) -> Change {
    guard count < entries.count else { return .empty }
    return Change(
      removals: [],
      insertions: (count ..< entries.count).map { index in
        Insertion(index: index, entry: entries[index], previousIndex: nil)
      },
      updates: []
    )
  }

  /// 用 MergeLists 的 `isLess:isEqual:getId:` 重载算差量（行是字典，判据全自定义）。
  ///
  /// - `getId`   = (内容指纹, 同指纹序号)：**身份 = 内容**，与下标无关；
  /// - `isEqual` = 指纹相等：指纹相同 = 这一行没变 ⇒ 不重测、不重建（本步的全部目的）；
  /// - `isLess`  = 行在各自列表里的位置：merge 是"有序表归并"，两边都按位置升序 ⇒ 位置序
  ///   天然自洽（上游 自己的用法就是位置序 + 内容 id：ChatListIndex + stableId）。
  ///   它只决定归并顺序，不参与身份。
  ///
  /// 纯函数、O(行数)，不新求指纹（指纹在 `entries(for:)` 里已算好）。
  ///
  /// 先剥掉**公共前缀 / 公共后缀**（逐行同身份），中段才交给 MergeLists。不剥的话，
  /// "整页位置前移"（删掉第一行 / 中间删一行）会退化成"全删 + 把后面全部重插"：merge 的
  /// 排序判据是位置序，位置整体位移时它偏好对齐相同位置。剥完这两段后，差量只在真正变了
  /// 的中段产生（内容正确性与最小性都在 selfCheck 里逐例验证）。
  /// 同内容行（完全相同的字典）之间的序号可能在差量里重排 —— 消费方按**内容 / 指纹**比对，
  /// 别把 duplicateOrdinal 当稳定身份。
  public static func make(left: [Entry], right: [Entry]) -> Change {
    var prefix = 0
    while prefix < left.count, prefix < right.count, left[prefix].identity == right[prefix].identity {
      prefix += 1
    }
    var suffix = 0
    while suffix < left.count - prefix, suffix < right.count - prefix,
          left[left.count - 1 - suffix].identity == right[right.count - 1 - suffix].identity {
      suffix += 1
    }
    // 中段：下标是"中段内"的，返回后统一平移 prefix（Entry.index 仍是页内原下标，
    // 保证 isLess 的坐标系在左右两边一致）。
    let result = tiebaMergeListsStableWithUpdates(
      leftList: Array(left[prefix ..< left.count - suffix]),
      rightList: Array(right[prefix ..< right.count - suffix]),
      isLess: { $0.index < $1.index },
      isEqual: { $0.fingerprint == $1.fingerprint },
      getId: { $0.identity }
    )
    return Change(
      removals: result.0.map { $0 + prefix },
      insertions: result.1.map {
        Insertion(index: $0.0 + prefix, entry: $0.1, previousIndex: $0.2.map { $0 + prefix })
      },
      updates: result.2.map { Update(index: $0.0 + prefix, entry: $0.1, previousIndex: $0.2 + prefix) }
    )
  }

  // MARK: - 自检（与 TiebaRowFingerprint 同纪律：**不挂在启动路径上**）

  /// 自检：返回 nil = 全过；否则是失败描述（多条以 " | " 连接）。
  /// 调用点：测试目标，或调试期手动 `_ = TiebaRowDiff.selfCheck()`。
  public static func selfCheck() -> String? {
    var failures: [String] = []
    func expect(_ condition: Bool, _ message: String) {
      if !condition { failures.append(message) }
    }

    // ① 指纹：确定性 + 不依赖字典插入序 + 与位置无关
    let row: [String: Any] = ["kind": "simple", "id": "a", "title": "标题", "value": "1", "count": 3]
    var reordered: [String: Any] = [:]
    for key in Array(row.keys).reversed() { reordered[key] = row[key] }
    expect(fingerprint(of: row) == fingerprint(of: row), "同一行两次求指纹不等")
    expect(fingerprint(of: row) == fingerprint(of: reordered), "字典插入顺序影响了指纹")
    expect(fingerprint(of: row) == entries(for: [[:], row])[1].fingerprint, "同内容在不同位置指纹不同")

    // ② 敏感性：simple 行的键（不在 TiebaRowFingerprint 白名单里）改一个必须变
    for key in ["kind", "id", "title", "value", "count"] {
      var mutated = row
      mutated[key] = "改过了"
      expect(fingerprint(of: mutated) != fingerprint(of: row), "simple 行改 \(key) 指纹没变")
    }

    // ③ 类型档：与旧 NSDictionary 深比较同语义的等价 / 区分
    expect(fingerprint(of: ["v": 3]) == fingerprint(of: ["v": 3.0]), "3 与 3.0 不同指纹（旧判据等价）")
    expect(fingerprint(of: ["v": true]) == fingerprint(of: ["v": 1]), "true 与 1 不同指纹（旧判据等价）")
    expect(fingerprint(of: ["v": 1]) != fingerprint(of: ["v": "1"]), "1 与 \"1\" 撞了")
    expect(fingerprint(of: [:]) != fingerprint(of: ["v": NSNull()]), "缺键与 NSNull 撞了")
    expect(fingerprint(of: ["a": 1, "b": 2]) == fingerprint(of: ["b": 2, "a": 1]), "字典键序敏感")
    expect(fingerprint(of: ["a": [1, 2]]) != fingerprint(of: ["a": [2, 1]]), "数组顺序不敏感")
    expect(fingerprint(of: ["a": ["x": 1]]) != fingerprint(of: ["a": ["x": 2]]), "嵌套字典不敏感")

    // ④ 差量：应用回旧页必须逐行还原新页（本步的验收）+ 纯追加时 tailAppend 与 merge 一致
    func apply(_ change: Change, to left: [Entry]) -> [Entry] {
      var list = left
      for index in change.removals.sorted(by: >) { list.remove(at: index) }
      for insertion in change.insertions { list.insert(insertion.entry, at: insertion.index) }
      for update in change.updates { list[update.index] = update.entry }
      return list
    }
    // 判据是**内容**（指纹）而不是 identity：完全相同的行之间，duplicateOrdinal 只是消歧
    // 标签，差量对它们重排编号语义无害（页内容与顺序一致，已在 3000 例随机模糊里确认）。
    func sameContent(_ a: [Entry], _ b: [Entry]) -> Bool {
      guard a.count == b.count else { return false }
      for index in a.indices where a[index].fingerprint != b[index].fingerprint { return false }
      return true
    }
    func sameRemovalsAndInsertions(_ a: Change, _ b: Change) -> Bool {
      guard a.removals == b.removals, a.insertions.count == b.insertions.count, a.updates.count == b.updates.count else { return false }
      for index in a.insertions.indices {
        let x = a.insertions[index], y = b.insertions[index]
        guard x.index == y.index, x.previousIndex == y.previousIndex, x.entry.fingerprint == y.entry.fingerprint else { return false }
      }
      return true
    }
    func check(_ label: String, _ leftRows: [[String: Any]], _ rightRows: [[String: Any]]) {
      let left = entries(for: leftRows)
      let right = entries(for: rightRows)
      let change = make(left: left, right: right)
      expect(sameContent(apply(change, to: left), right),
             "\(label)：差量还原不出新页（\(change.removals.count) 删 / \(change.insertions.count) 插 / \(change.updates.count) 更新）")
      if isPrefix(left: left, right: right) {
        expect(sameRemovalsAndInsertions(change, tailAppend(of: right, after: left.count)),
               "\(label)：tailAppend 与 merge 结果不一致")
      }
    }
    let a: [String: Any] = ["kind": "feed", "threadId": "1", "title": "A"]
    let b: [String: Any] = ["kind": "feed", "threadId": "2", "title": "B"]
    let c: [String: Any] = ["kind": "feed", "threadId": "3", "title": "C"]
    let a2: [String: Any] = ["kind": "feed", "threadId": "1", "title": "A", "isLiked": true]
    check("首屏（空 → n）", [], [a, b, c])
    check("纯追加", [a, b], [a, b, c])
    check("纯追加（多行）", [a], [a, b, c])
    check("完全没变", [a, b, c], [a, b, c])
    check("尾部行改了", [a, b, c], [a, b, a2])
    check("中间行改了", [a, b, c], [a, a2, c])
    check("首行改了", [a, b, c], [a2, b, c])
    check("首行删除", [a, b, c], [b, c])
    check("中间行删除", [a, b, c], [a, c])
    // 剥前后缀的收益：不剥的话这两例会退化成"全删 + 把后面全部重插"
    expect(make(left: entries(for: [a, b, c]), right: entries(for: [b, c])).removals == [0],
           "首行删除的差量不是只删 0")
    expect(make(left: entries(for: [a, b, c]), right: entries(for: [a, c])).removals == [1],
           "中间行删除的差量不是只删 1")
    check("头部插入", [a, b], [c, a, b])
    check("整页换数据", [a, b, c], [c, b, a])
    check("清空", [a, b, c], [])
    check("重复行", [a, a, b], [a, a, a, b])
    check("重复行减少", [a, a, a], [a, a])

    // ⑤ 同一页里完全相同的行：id 必须唯一，不能踩 merge 的 DEBUG 重复 id 断言
    do {
      let entries = TiebaRowDiff.entries(for: [row, row, row])
      expect(Set(entries.map { $0.identity }).count == entries.count, "同内容行的身份不唯一")
      _ = make(left: [], right: entries)
    }

    return failures.isEmpty ? nil : failures.joined(separator: " | ")
  }
}
