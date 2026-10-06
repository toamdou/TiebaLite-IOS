// ============================================================
// TiebaLite — 行内容指纹（TiebaRowFingerprint）
//
// 现状：行的身份 = **位置**（TiebaKindItem 的 pageKey + index）。内容变了身份不变 →
// diff 无从下手 → 只能整页 reload → 由此长出 8 类补偿机制（TiebaRowPagePins 10 处 /
// notifyPageDataMissing 10 处 / TiebaAdaptiveThrottle 4 处 / 兜底高 5 处 /
// republishCurrentPage 6 处 / subIndex 7 处 / frameHeightCache 5 处 / isAppend 深比较）。
// 见 docs/uikit-migration/00-总览与结论.md §4.2「设计 1」。
//
// 本文件是那块地基：把一行的**内容**压成一个 64 位整数，作为与位置无关的"值身份"。
// 本步只**加字段**（TiebaFeedRowModel.fingerprint），不改任何现有渲染/缓存行为。
//
// ── 三条硬约束（动任何一条都要 version += 1）──
//   1. **跨进程稳定**：冷启动后再算必须逐位相同（跨启动命中缓存的前提）。所以字符串
//      一律走 早期 vendored 的 Support 模块 的 `persistentHashValue`；**绝不能**用
//      `String.hashValue` / `Swift.Hasher` / Set 迭代序 —— 它们带每进程随机种子，
//      同一串两次启动是两个数（这是本文件唯一真正的坑）。
//   2. **位置无关**：pageKey / index / 容器宽度一律不进指纹。同一内容在第 3 行还是
//      第 30 行、手机单列还是 iPad 双列，指纹必须相同，否则"身份"又变回位置。
//   3. **方向性保守**：白名单取渲染输入的**超集**，且不依赖字典迭代顺序。多算一个键
//      = 最坏多判一次"变了"（多测一行）；漏算一个渲染依赖的键 = "变了"被判成"没变"
//      （画错且不自愈）。宁左勿右。
//
// ── 为什么输入是**行字典**而不是模型 ──
//   - 测量**之前**就能算：预取判重 / 行复用 / 分页交错不必先付 TextKit 的代价；
//   - 模型字段是 raw 的纯函数 ⇒ "字典指纹"与"模型指纹"不可能漂移。模型侧只存一份：
//     `TiebaFeedRowModel.fingerprint = TiebaRowFingerprint.hash(raw: raw)`。
//
// ── 并发 ──
//   纯函数、无共享状态（只有 let 常量表），故 nonisolated 且可从后台测量队列调用。
// ============================================================

import Foundation
// [收敛] 原 import 上游 Support 模块 —— MergeLists/PersistentStringHash 已移入本模块，
// 现直接放在 Sources/TiebaNative/Core/ 下（早期的 早期 vendor 目录 目录已解散），不再需要跨模块 import。

/// 行字典 → 内容指纹（64 位、跨进程稳定、与位置无关）。字段清单与理由见文件头与本文件内注释。
public nonisolated enum TiebaRowFingerprint {

  // MARK: - 版本

  /// 指纹算法版本。**改字段集 / 规范化规则 / 混合函数都必须 +1**。
  /// version 本身是输入的第一个字，故换版本 = 换一族指纹：将来落盘的旧指纹自然失效，
  /// 不会出现"新旧算法碰巧算出同一个数"的静默错配。
  public static let version: UInt64 = 1

  // MARK: - 字段白名单（顶层）

  /// 参与指纹的顶层键。每个键先混**键名**（域分隔：两个字段互换值不会撞），再混值。
  ///
  /// 逐条 = TiebaFeedRowModel 的一个**渲染输入**，注释写它喂给谁 / 为什么影响渲染。
  /// 未列出的键一律不参与 —— 白名单，不是黑名单（JS 侧的任何瞬时/调试字段都不会
  /// 让指纹抖动）。**明确排除**的键见文件末尾「不进指纹的键」。
  private static let scalarKeys: [String] = [
    // ── 身份与字号 ──
    "threadId",             // ThreadInfo.id：行复用的"同一帖"判据（计数跳动只认同帖）
    "fontScale",            // 应用内阅读字号倍率 → 字号/行高，直接改像素

    // ── 头部（TweetCard headerRow）──
    "displayName",          // 昵称主文案
    "authorNameShow",       // 昵称兜底链（displayName 缺省时取它）
    "authorName",           // 用户名（兜底昵称 / 合成 @handle 都用它）
    "handle",               // 显式 @昵称
    "showBothUsername",     // 是否把 authorName 也当 @handle 画（决定 metaAttributed 存在与否）
    "authorPortrait",       // 头像输入（himg 前缀拼接）
    "authorIP",             // IP 属地原文（ipText 的兜底来源）
    "ipText",               // 显式 IP 文案（JS 预解析时优先）
    "showIpLocation",       // 设置项：关掉后 IP 行不画（**影响行高**）

    // ── 正文 ──
    "title",                // 标题文案（同时是置顶横幅的文案来源）
    "abstract",             // 摘要文案
    "isGood",               // 精品前缀「精品 」是否出现（titleAttributed 首段）
    "isTop",                // 置顶行 → 整行走横幅（几何与普通行完全不同）
    "expanded",             // 展开态（用户交互态，直接决定 title/abstractLineLimit）
    "collapsible",          // JS 显式折叠判据（缺省按 weightedTextLength 推）

    // ── 媒体 ──
    "hideMedia",            // 关掉后整块媒体不画（**影响行高**）

    // ── 转发引用帖 ──
    "isShareThread",        // 是否渲染引用卡（决定 quote 块存在与否 → 影响行高）

    // ── 吧名徽章（ForumChip）──
    "showForumPill",        // 徽章开关（还要 && 吧名非空，见 TiebaFeedRowFallback）
    "forumName", "forum_name", "fname",              // 吧名三变体（逐键兜底）
    "forumAvatar", "forum_avatar",                   // 吧头像两变体
    "forumId", "forum_id", "fid",                    // 吧 id（KV 回填的优先键）

    // ── 操作栏 ──
    "hideActions",          // 整条操作栏开关（**影响行高**）
    "replyNum", "shareNum", "zanNum",                 // 计数（likeCount 还是计数跳动判据）
    "replyText", "shareText", "likeText",             // 显式文案（缺省按计数格式化）
    "isLiked", "hasAgree",                            // 点赞态（icon 与配色）

    // ── 交互开关（JS 下发，决定菜单项而不决定几何）──
    "closeMenuOptions",     // 右上角「更多」菜单项集合
    "imageContextMenu",     // 图片长按菜单开关
    "cardContextMenu",      // 卡片长按菜单开关（分享/复制内容/不感兴趣/屏蔽作者）
  ]

  /// 媒体项的**子键**白名单（TiebaFeedRowParser.parseMedia / parseVideoPoster 真正读的键）。
  /// 顺序在这里不重要（逐键缺席也有记录），但**项与项之间的顺序是绘制顺序，必须参与**。
  private static let mediaItemKeys: [String] = [
    "type",             // image / video（非 image 不进图片数组，但 poster 进）
    "src",              // 显示档（服务端 big_pic）
    "smallSrc",         // 动图档（服务端 src_pic）
    "originSrc",        // 原图档（查看器/长按保存）
    "poster",           // 视频 poster
    "width", "height",  // 宽高比 → 单图高 / 图片带行高（**影响行高**）
    "showOriginalBtn",  // 「查看原图」按钮是否出现
  ]

  /// 引用帖的子键白名单（模型读 origin["forumName"/"title"/"content"/"threadId"]）。
  private static let quoteKeys: [String] = ["forumName", "forum_name", "title", "content", "threadId", "tid"]

  /// 吧对象的三个容器变体（TiebaFeedRowFallback 逐键兜底的落点）。
  private static let forumContainers: [String] = ["forumInfo", "forum_info", "forum"]

  /// 吧对象容器内的子键白名单（名字 + 头像，即徽章真正读的两个值）。
  private static let forumContainerKeys: [String] = ["forum_name", "forumName", "name", "avatar"]

  // MARK: - 混合器

  /// 64 位滚动混合器。纯算术（&^ / &*），**无 Hashable / Hasher / 随机种子**，
  /// 故跨进程、跨设备、跨架构（arm64 / x86_64）逐位一致。
  public struct Mixer: Sendable {
    /// FNV-1a 64 的 offset basis。
    private var state: UInt64

    public init(seed: UInt64 = 0xCBF2_9CE4_8422_2325) {
      state = seed
    }

    /// 混入一个字（键名域分隔与值都走这里）。
    @inline(__always)
    public mutating func mix(_ value: UInt64) {
      state = (state ^ value) &* 0x0000_0100_0000_01B3 // FNV-1a 64 素数
    }

    /// 字符串：**必须**走 vendored `persistentHashValue`（跨进程稳定）。
    /// 它只保 56 位（127·h+b 且高 8 位被掩掉），比理想的 64 位哈希更易撞 —— 对"行身份"
    /// 够用：外面还叠了 FNV 一层 + 逐字段键名域分隔。
    @inline(__always)
    public mutating func mix(_ text: String) {
      mix(text.persistentHashValue)
    }

    @inline(__always)
    public mutating func mix(_ number: Int64) {
      mix(UInt64(bitPattern: number))
    }

    /// 浮点：按 IEEE-754 位型混（**不用 description** —— 那受 locale / 精度格式影响）。
    @inline(__always)
    public mutating func mix(_ number: Double) {
      mix(number.bitPattern)
    }

    /// 收尾雪崩（splitmix64 的 finalizer 常量）。多项式乘法是线性的，不雪崩的话
    /// 高位差异传不到低位，截断/取模使用时会系统性撞。
    public var value: UInt64 {
      var z = state
      z ^= z >> 33
      z = z &* 0xFF51_AFD7_ED55_8CCD
      z ^= z >> 33
      z = z &* 0xC4CE_B9FE_1A85_EC53
      z ^= z >> 33
      return z
    }
  }

  /// 值的类型档：同一次 `mix` 调用里当"类型标签"用，避免 "1"（串）与 1（数）撞。
  private enum Tag {
    static let absent: UInt64 = 1 // 缺省 / null / 空串 / 空容器
    static let text: UInt64 = 2
    static let int: UInt64 = 3
    static let double: UInt64 = 4
    static let array: UInt64 = 5
    static let dict: UInt64 = 6
    static let other: UInt64 = 7
  }

  // MARK: - 公共入口

  /// 行内容指纹。同一字典 → 同一数（跨进程 / 跨启动 / 跨设备）；
  /// 任何**渲染输入**变化 → 不同的数。
  ///
  /// - Parameter raw: JS 下发的行字典（与 `TiebaFeedRowModel.init(raw:)` 同一份）。
  public static func hash(raw: [String: Any]) -> UInt64 {
    var mixer = Mixer()
    mixer.mix(version)

    // 1) 顶层：键名先混做域分隔，再混值（缺席也是一个可区分的档）
    for key in scalarKeys {
      mixer.mix(key)
      mixValue(raw[key], into: &mixer)
    }
    // 2) 媒体列表：项内按子键白名单，项间顺序参与（= 绘制顺序）
    mixer.mix("mediaList")
    mixMediaList(raw["mediaList"], into: &mixer)
    // 3) 引用帖：只取模型真正读的四个子键
    mixer.mix("originThreadInfo")
    mixFiltered(raw["originThreadInfo"], keys: quoteKeys, into: &mixer)
    // 4) 吧名/吧头像的三个容器变体
    for key in forumContainers {
      mixer.mix(key)
      mixFiltered(raw[key], keys: forumContainerKeys, into: &mixer)
    }
    return mixer.value
  }

  // MARK: - 值规范化

  /// 一个原始值的规范混入。JS 桥只送 String / NSNumber / NSNull / NSArray / NSDictionary。
  ///
  /// 规范化规则（都在"少一次无意义的变了"这一侧，不改变**保守**方向）：
  ///   - null / 空串 / 空数组 / 空字典 → 同一个 absent 档（模型侧 `nonEmpty` / `?? []`
  ///     本就同语义，区分它们只会让指纹随 JS 的键存在性抖动）；
  ///   - CFBoolean 与整数同一档（`true` ≡ `1`，与 TiebaRowDict.bool 同语义）；
  ///   - 3 与 3.0 折叠成整数档（同一个数在桥上的整/浮表示不稳定）；
  ///   - 其余浮点按 IEEE-754 位型。
  private static func mixValue(_ value: Any?, into mixer: inout Mixer) {
    guard let value, !(value is NSNull) else {
      mixer.mix(Tag.absent)
      return
    }
    if let text = value as? String {
      guard !text.isEmpty else {
        mixer.mix(Tag.absent)
        return
      }
      mixer.mix(Tag.text)
      mixer.mix(text)
      return
    }
    if let number = value as? NSNumber {
      // CFBoolean 也是 NSNumber：先按布尔判，落到 0/1 整数档。
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
        mixer.mix(Tag.int)
        mixer.mix(Int64(double))
        return
      }
      mixer.mix(Tag.double)
      mixer.mix(double)
      return
    }
    if let array = value as? [Any] {
      mixArray(array, into: &mixer)
      return
    }
    if let dict = value as? [String: Any] {
      mixDictionary(dict, into: &mixer)
      return
    }
    if let url = value as? URL {
      mixer.mix(Tag.text)
      mixer.mix(url.absoluteString)
      return
    }
    if let date = value as? Date {
      mixer.mix(Tag.double)
      mixer.mix(date.timeIntervalSince1970)
      return
    }
    // 到不了这里（JS 桥只送上面几种）。真出现也**不混 description**：它可能含时区 /
    // 内存地址等不稳定成分，跨进程就废了；只混类型名，稳定性优先。
    mixer.mix(Tag.other)
    mixer.mix(String(describing: type(of: value)))
  }

  /// 数组：顺序有意义（文本 runs / 媒体列表都是顺序敏感的），逐元素递归。
  /// 空元素与空容器一样折成"没有这一项"（模型侧同样会跳过它们）。
  private static func mixArray(_ array: [Any], into mixer: inout Mixer) {
    var items: [Any] = []
    items.reserveCapacity(array.count)
    for element in array where !isEmptyValue(element) {
      items.append(element)
    }
    guard !items.isEmpty else {
      mixer.mix(Tag.absent)
      return
    }
    mixer.mix(Tag.array)
    mixer.mix(UInt64(items.count))
    for item in items {
      mixValue(item, into: &mixer)
    }
  }

  /// 字典：**按 UTF-8 字节序排序**后逐项混。
  /// 直接用 Dictionary 的迭代顺序 = 指纹每次进程都变（Swift 字典的哈希种子是每进程
  /// 随机的）—— 这正是 `String.hashValue` 那类坑的变体，必须显式排序。
  private static func mixDictionary(_ dict: [String: Any], into mixer: inout Mixer) {
    var entries: [(bytes: [UInt8], key: String, value: Any)] = []
    entries.reserveCapacity(dict.count)
    for (key, value) in dict where !isEmptyValue(value) {
      entries.append((Array(key.utf8), key, value))
    }
    guard !entries.isEmpty else {
      mixer.mix(Tag.absent)
      return
    }
    entries.sort { $0.bytes.lexicographicallyPrecedes($1.bytes) }
    mixer.mix(Tag.dict)
    mixer.mix(UInt64(entries.count))
    for entry in entries {
      mixer.mix(entry.key)
      mixValue(entry.value, into: &mixer)
    }
  }

  // MARK: - 嵌套结构（子键白名单）

  /// 媒体列表：项内只混白名单子键，项间保序。
  private static func mixMediaList(_ value: Any?, into mixer: inout Mixer) {
    guard let list = value as? [Any] else {
      // 形态不对（不是数组）→ 按通用值混，别静默丢内容。
      mixValue(value, into: &mixer)
      return
    }
    var items: [[String: Any]] = []
    items.reserveCapacity(list.count)
    for element in list {
      guard let item = element as? [String: Any] else { continue }
      if !hasListedValue(item, keys: mediaItemKeys) { continue }
      items.append(item)
    }
    guard !items.isEmpty else {
      mixer.mix(Tag.absent)
      return
    }
    mixer.mix(Tag.array)
    mixer.mix(UInt64(items.count))
    for item in items {
      mixFilteredDict(item, keys: mediaItemKeys, into: &mixer)
    }
  }

  /// 可选值的子键白名单入口：非字典形态按通用值混。
  private static func mixFiltered(_ value: Any?, keys: [String], into mixer: inout Mixer) {
    guard let dict = value as? [String: Any] else {
      mixValue(value, into: &mixer)
      return
    }
    mixFilteredDict(dict, keys: keys, into: &mixer)
  }

  /// 子字典：只混白名单里**有值**的键（键名先混做域分隔）。
  /// keys 是写死的常量表 ⇒ 遍历顺序天然稳定，不必再排序。
  private static func mixFilteredDict(_ dict: [String: Any], keys: [String], into mixer: inout Mixer) {
    var present = 0
    for key in keys where !isEmptyValue(dict[key]) {
      present += 1
    }
    guard present > 0 else {
      // 各子键都缺 = 模型侧那一块整块不渲染 → 与"没有这个容器"同档。
      mixer.mix(Tag.absent)
      return
    }
    mixer.mix(Tag.dict)
    mixer.mix(UInt64(present))
    for key in keys {
      guard !isEmptyValue(dict[key]) else { continue }
      mixer.mix(key)
      mixValue(dict[key], into: &mixer)
    }
  }

  private static func hasListedValue(_ dict: [String: Any], keys: [String]) -> Bool {
    for key in keys where !isEmptyValue(dict[key]) {
      return true
    }
    return false
  }

  /// 缺省档判据（与上面「空串/空容器 ≡ 缺省」一致）。
  private static func isEmptyValue(_ value: Any?) -> Bool {
    guard let value, !(value is NSNull) else { return true }
    if let text = value as? String { return text.isEmpty }
    if let array = value as? [Any] { return array.isEmpty }
    if let dict = value as? [String: Any] { return dict.isEmpty }
    return false
  }

  // ── 不进指纹的键（白名单之外，逐条记理由；改这里前先读文件头的三条硬约束）──
  //   pageKey / index            ：位置，不是内容 —— 指纹存在的全部理由就是甩掉它们
  //   containerWidth             ：不在行字典里；宽度是 TiebaPageStore 的独立缓存键，
  //                                混进来 = 换个宽度同一内容变两个身份
  //   timeText / timeType / timeValue / createTime / lastTime / timestampStyle
  //                              ：时间文案 = f(墙上时钟)（relativeTime 用 Date()）。
  //                                混进去 → 每天 / 每次启动全表指纹都变 → 跨启动永不命中，
  //                                与硬约束 1 直接冲突。时间也不是**身份**：同一帖的时间
  //                                只会越走越久，不会因此变成另一帖。
  //                                已知取舍：时间文案的**宽度**参与名字行排版
  //                                （plan 的 metaFrame），故"只是时间走过了一天"不会让行
  //                                复用失效（这是对的）；将来若把指纹当**测量缓存键**用，
  //                                需另把时间文案宽度纳入键。
  //   其余所有键                  ：JS 侧调试 / 瞬时字段一律不参与

  // MARK: - 自检（可选；**不挂在启动路径上**，本步只加字段、不改行为）

  /// 自检样本：覆盖上面**每一个**字段 + 三种嵌套结构 + 数值/布尔/数组类型。
  /// internal（非 private）：供测试目标与跨进程回归脚本取同一份输入。
  static func selfCheckSample() -> [String: Any] {
    var row: [String: Any] = [:]
    for (index, key) in scalarKeys.enumerated() {
      row[key] = "v\(index)"
    }
    // 类型覆盖：模型侧的真实类型（数值 / 布尔 / 数组）
    row["fontScale"] = 1.0
    row["replyNum"] = 12
    row["shareNum"] = 3
    row["zanNum"] = 1024
    row["isLiked"] = true
    row["expanded"] = false
    row["showIpLocation"] = true
    row["hideMedia"] = false
    row["closeMenuOptions"] = ["dislike", "block"]
    // 嵌套结构：媒体（图 + 视频 poster）/ 引用帖 / 吧对象
    row["mediaList"] = [
      [
        "type": "image",
        "src": "https://tiebapic.baidu.com/forum/w%3D580/a.jpg",
        "smallSrc": "https://tiebapic.baidu.com/forum/w%3D580/a_s.jpg",
        "originSrc": "https://tiebapic.baidu.com/forum/w%3D580/a_o.jpg",
        "width": 800,
        "height": 600,
        "showOriginalBtn": true,
      ],
      [
        "type": "video",
        "poster": "https://tiebapic.baidu.com/p.jpg",
        "src": "https://tiebapic.baidu.com/v.mp4",
      ],
    ]
    row["originThreadInfo"] = [
      "forumName": "引用吧",
      "title": "引用标题",
      "content": [["type": "text", "text": "引用正文"]],
      "threadId": "999",
    ]
    row["forumInfo"] = ["forum_name": "吧名", "avatar": "https://himg.bdimg.com/sys/portrait/item/x"]
    return row
  }

  /// 自检：返回 nil = 全过；否则是失败描述（多条以 " | " 连接）。
  ///
  /// 覆盖 6 件事：
  ///   ① 确定性（同输入同输出）；
  ///   ② 不依赖字典迭代顺序（Swift 字典的迭代序每进程都不同）；
  ///   ③ **位置 / 时间族 / 非白名单键不影响指纹** —— 这是设计意图，写成断言免得
  ///      后人"顺手"把它们加进白名单（加进去 = 跨启动永不命中）；
  ///   ④ 逐字段敏感度：白名单里**每个**键换一个值都必须变（自动覆盖将来新增的键）；
  ///   ⑤ 嵌套结构敏感度（媒体/引用帖/吧对象）与"空值 ≡ 缺省"等价性；
  ///   ⑥ 跨进程锚点（见 goldenSampleFingerprint）。
  ///
  /// 调用点：测试目标，或调试期手动 `_ = TiebaRowFingerprint.selfCheck()`。
  public static func selfCheck() -> String? {
    var failures: [String] = []
    let sample = selfCheckSample()
    let baseline = hash(raw: sample)

    // ① 确定性
    if hash(raw: sample) != baseline {
      failures.append("同一行字典两次求指纹不相等")
    }

    // ② 字典迭代顺序无关（Swift 字典的迭代序每进程都不同）
    var reordered: [String: Any] = [:]
    for (key, value) in Array(sample).reversed() {
      reordered[key] = value
    }
    if hash(raw: reordered) != baseline {
      failures.append("字典插入顺序影响了指纹")
    }

    // ③ 位置 / 时间族 / 非白名单键必须**不**影响指纹
    var ignored = sample
    ignored["pageKey"] = "feed:home"
    ignored["index"] = 3
    ignored["containerWidth"] = 393.0
    ignored["createTime"] = 1_700_000_000_000.0
    ignored["timeValue"] = 1_700_000_000_000.0
    ignored["timeType"] = "create"
    ignored["timestampStyle"] = "relative"
    ignored["timeText"] = "发帖于 3小时前"
    ignored["lastTime"] = 1_700_000_000_000.0
    ignored["__debugSeq"] = 42
    if hash(raw: ignored) != baseline {
      failures.append("位置/时间族/非白名单键影响了指纹")
    }

    // ④ 逐字段敏感度：白名单里每个键换一个值，指纹都必须变
    for key in scalarKeys {
      guard let value = sample[key], !isEmptyValue(value) else {
        failures.append("自检样本缺字段 \(key)")
        continue
      }
      var mutated = sample
      mutated[key] = selfCheckMutated(value)
      if hash(raw: mutated) == baseline {
        failures.append("改 \(key) 指纹没变")
      }
    }

    // ⑤ 嵌套敏感度 + 空值等价
    func fingerprint(_ mutate: (inout [String: Any]) -> Void) -> UInt64 {
      var mutated = sample
      mutate(&mutated)
      return hash(raw: mutated)
    }
    func expectChanged(_ label: String, _ mutate: (inout [String: Any]) -> Void) {
      if fingerprint(mutate) == baseline {
        failures.append("改 \(label) 指纹没变")
      }
    }
    func mediaList(_ row: [String: Any]) -> [[String: Any]] {
      row["mediaList"] as? [[String: Any]] ?? []
    }
    expectChanged("mediaList[0].src") { row in
      var list = mediaList(row)
      list[0]["src"] = "https://tiebapic.baidu.com/forum/w%3D580/b.jpg"
      row["mediaList"] = list
    }
    expectChanged("mediaList[0].smallSrc") { row in
      var list = mediaList(row)
      list[0].removeValue(forKey: "smallSrc")
      row["mediaList"] = list
    }
    expectChanged("mediaList[0].originSrc") { row in
      var list = mediaList(row)
      list[0]["originSrc"] = "https://tiebapic.baidu.com/forum/w%3D580/b_o.jpg"
      row["mediaList"] = list
    }
    expectChanged("mediaList[0].width") { row in
      var list = mediaList(row)
      list[0]["width"] = 801
      row["mediaList"] = list
    }
    expectChanged("mediaList[0].height") { row in
      var list = mediaList(row)
      list[0]["height"] = 601
      row["mediaList"] = list
    }
    expectChanged("mediaList[0].showOriginalBtn") { row in
      var list = mediaList(row)
      list[0]["showOriginalBtn"] = false
      row["mediaList"] = list
    }
    expectChanged("mediaList[1].poster") { row in
      var list = mediaList(row)
      list[1]["poster"] = "https://tiebapic.baidu.com/q.jpg"
      row["mediaList"] = list
    }
    expectChanged("mediaList 项顺序") { row in
      var list = mediaList(row)
      list.reverse()
      row["mediaList"] = list
    }
    expectChanged("mediaList 增项") { row in
      var list = mediaList(row)
      list.append(["type": "image", "src": "https://tiebapic.baidu.com/c.jpg"])
      row["mediaList"] = list
    }
    expectChanged("originThreadInfo.title") { row in
      var quote = row["originThreadInfo"] as? [String: Any] ?? [:]
      quote["title"] = "引用标题 2"
      row["originThreadInfo"] = quote
    }
    expectChanged("originThreadInfo.content") { row in
      var quote = row["originThreadInfo"] as? [String: Any] ?? [:]
      quote["content"] = [["type": "text", "text": "引用正文 2"]]
      row["originThreadInfo"] = quote
    }
    expectChanged("originThreadInfo.threadId") { row in
      var quote = row["originThreadInfo"] as? [String: Any] ?? [:]
      quote["threadId"] = "1000"
      row["originThreadInfo"] = quote
    }
    expectChanged("forumInfo.forum_name") { row in
      var forum = row["forumInfo"] as? [String: Any] ?? [:]
      forum["forum_name"] = "另一个吧"
      row["forumInfo"] = forum
    }
    expectChanged("forumInfo.avatar") { row in
      var forum = row["forumInfo"] as? [String: Any] ?? [:]
      forum["avatar"] = "https://himg.bdimg.com/sys/portrait/item/y"
      row["forumInfo"] = forum
    }
    expectChanged("吧名容器变体（forum.name）") { row in
      row["forum"] = ["name": "吧名", "avatar": "https://himg.bdimg.com/sys/portrait/item/x"]
      row.removeValue(forKey: "forumInfo")
    }
    // 空值 ≡ 缺省（模型侧同语义 → 指纹也必须同数，否则凭空多出"变了"）
    if fingerprint({ $0["title"] = "" }) != fingerprint({ $0.removeValue(forKey: "title") }) {
      failures.append("空串与缺省不等价（title）")
    }
    if fingerprint({ $0["closeMenuOptions"] = [] }) != fingerprint({ $0.removeValue(forKey: "closeMenuOptions") }) {
      failures.append("空数组与缺省不等价（closeMenuOptions）")
    }
    if fingerprint({ $0["originThreadInfo"] = [:] }) != fingerprint({ $0.removeValue(forKey: "originThreadInfo") }) {
      failures.append("空字典与缺省不等价（originThreadInfo）")
    }
    if fingerprint({ $0["isLiked"] = 1 }) != fingerprint({ $0["isLiked"] = true }) {
      failures.append("1 与 true 不等价（isLiked）")
    }
    if fingerprint({ $0["replyNum"] = 12.0 }) != fingerprint({ $0["replyNum"] = 12 }) {
      failures.append("12.0 与 12 不等价（replyNum）")
    }

    // ⑥ 跨进程锚点：同一份输入在**任何一次启动**都必须算出同一个数。
    //    常量由 selfCheckSample() 算出后钉死；改了字段集/规范化 → 这里会红 →
    //    必须同时把 version 与这个常量一起改。
    if hash(raw: sample) != goldenSampleFingerprint {
      failures.append(String(format: "跨进程锚点失配：现值 %016llx ≠ 锚点 %016llx", hash(raw: sample), goldenSampleFingerprint))
    }

    return failures.isEmpty ? nil : failures.joined(separator: " | ")
  }

  /// 「跨进程锚点」= `selfCheckSample()` 的指纹常量（首次算出后钉死，见 selfCheck ⑥）。
  /// 它锁住的是硬约束 1：**同一份输入在任何一次启动都算出同一个数** —— 只靠"同进程跑两次
  /// 相等"是测不出来的（那只能测出没有随机数，测不出没有每进程种子）。改动算法/字段集
  /// 后必须重算这个常量（把 version 一起 +1）。
  static let goldenSampleFingerprint: UInt64 = 0x2a25_293a_4f36_4e8a // 3036878854145068682

  /// 自检用的"换一个值"：按类型内变异，保证一定与原值不同。
  private static func selfCheckMutated(_ value: Any) -> Any {
    if let text = value as? String { return text + "x" }
    if let number = value as? NSNumber {
      if CFGetTypeID(number) == CFBooleanGetTypeID() { return !number.boolValue }
      if !CFNumberIsFloatType(number) { return number.int64Value + 1 }
      return number.doubleValue + 1
    }
    if let array = value as? [Any] { return array + ["x"] }
    if let dict = value as? [String: Any] {
      var copy = dict
      copy["__selfCheck"] = "x"
      return copy
    }
    return "x"
  }
}
