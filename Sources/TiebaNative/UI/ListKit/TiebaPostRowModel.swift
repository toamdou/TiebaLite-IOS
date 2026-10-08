// 从 TiebaPostRowMetrics.swift 拆出（H10 千行文件拆分）：行模型 + 显示偏好 + 屏蔽过滤 + 工具条模型。
// 纯搬运：整类型逐字搬走（不改访问级、不改一行逻辑）。

// MARK: - 显示偏好（每次整页 prepare 现读，过渡期只读共享偏好）

import UIKit
import Nuke

struct TiebaPostPreferences: Sendable {
  var showIpLocation = true
  var showLevelBadge = true
  /// 等级徽标后面接头衔名（如「Lv.5 F2.8」；头衔随作者字段下发）。
  var showLevelTitle = false
  var showBothUsername = false
  var fontScale: CGFloat = 1
  var hideMedia = false
  var blockVideo = false
  var imageDarkenWhenNight = false
  var imageLoadType = "smart_origin"
  var dataSaverMode = "high"
  var isNight = false
  var timestampStyle = "relative"
  var videoAutoplay = false
  /// 1px hairline：trait 的 displayScale 只在 UIKit 上下文非 0（测量在后台队列），
  /// 所以由主线程的 load() 取好、随偏好一起传入（UIScreen.main 自 iOS 26 废弃）。
  var hairline: CGFloat = 1.0 / 3.0

  @MainActor
  static func load() -> TiebaPostPreferences {
    var prefs = TiebaPostPreferences()
    prefs.showIpLocation = TiebaPreferenceSnapshot.bool("showIpLocation", default: true)
    prefs.showLevelBadge = TiebaPreferenceSnapshot.bool("showLevelBadge", default: true)
    prefs.showLevelTitle = TiebaPreferenceSnapshot.bool("showLevelTitle", default: false)
    prefs.showBothUsername = TiebaPreferenceSnapshot.bool("showBothUsername", default: false)
    // 正文级字号倍率（设置→个性化→阅读字号→正文字号；旧键 fontScale 由 TiebaTypography 迁移）
    prefs.fontScale = TiebaTypography.bodyScale()
    prefs.hideMedia = TiebaPreferenceSnapshot.bool("hideMedia", default: false)
    prefs.blockVideo = TiebaPreferenceSnapshot.bool("blockVideo", default: false)
    prefs.imageDarkenWhenNight = TiebaPreferenceSnapshot.bool("imageDarkenWhenNight", default: false)
    prefs.imageLoadType = TiebaPreferenceSnapshot.string("imageLoadType") ?? "smart_origin"
    prefs.dataSaverMode = TiebaPreferenceSnapshot.string("dataSaverMode") ?? "high"
    prefs.timestampStyle = TiebaPreferenceSnapshot.string("timestampStyle") ?? "relative"
    prefs.videoAutoplay = TiebaPreferenceSnapshot.bool("videoAutoplay", default: false)
    prefs.hairline = 1 / max(UITraitCollection.current.displayScale, 1)
    prefs.isNight = TiebaChromeTheme.current.dark
    return prefs
  }

  /// 钳制域必须**覆盖整个偏好范围**（12…24pt ⇒ 0.706…1.412）：原来写死 0.8…2.0
  /// 会把 12～13.6pt 一档全部压成 0.8（用户在小字号端拖滑杆"没反应"）。
  var fontScaleClamped: CGFloat { min(max(fontScale, 0.7), 1.45) }
}

// MARK: - 屏蔽过滤（BlockManager.shouldBlockContent / shouldBlockUser 的原生等价）

struct TiebaPostMediaPlaceholder: Sendable {
  var icon: String
  var text: String
}

// MARK: - 行模型

final class TiebaPostRowModel: @unchecked Sendable {
  let pageKey: String
  let index: Int
  /// 进帖转场的配对来源（只有主贴卡有值；由帖子页按 threadId 传入）。
  /// 存 threadId 而不是拼好的 id：卡片与图片两条配对线都从它派生。
  let heroThreadId: String?
  let post: TiebaThreadPost
  let isMain: Bool
  let isLz: Bool
  let canDelete: Bool
  let threadAuthorId: String
  private(set) var toolbar: TiebaPostToolbarModel?

  /// 翻页只改工具栏页码时用它就地换工具栏：行高与 plan 都不变，不必整行重建 + 重测
  /// （配合 TiebaThreadViewController.rebuild 里把 pageLabel 移出 toolbarFingerprint）。
  func updateToolbar(_ next: TiebaPostToolbarModel?) {
    toolbar = next
  }
  let preferences: TiebaPostPreferences
  let blockFilter: TiebaPostBlockFilter
  let palette: TiebaFeedRowPalette
  let containerWidth: CGFloat
  let measuredHeight: CGFloat
  let plan: TiebaPostRowPlan
  /// 主贴卡标题原文（回复行为空）。**必须留**：同步补测要按新宽度用同一份输入重建模型，
  /// 少了它就重建不出同一张卡（原来它只是 init 的形参、用完即弃）。
  let sourceTitle: String

  let avatarURL: URL?
  let nameText: String
  let metaText: String
  let levelText: String?
  /// 放不下时的退档（「Lv.5」），见 TiebaPostRowPlan 的徽标测量。
  let levelShortText: String?
  let levelColor: UIColor?
  let images: [TiebaThreadImage]
  let imagesHidden: Bool
  let video: TiebaThreadVideo?
  let videoPlaceholder: TiebaPostMediaPlaceholder?
  let audio: (src: String, duration: Double)?
  let forumName: String
  let showsBlockedTip: Bool
  /// 主贴卡标题（回复行为 nil）。不带前景色：颜色走 titleLabel.textColor 现取色板，
  /// 与已知主贴占位卡同一套（主题切换时两者同时变色）。
  let titleText: NSAttributedString?

  private let textBuild: TiebaPostTextBuild
  private let subPostBuilds: [TiebaPostTextBuild]
  private let cachedText: NSAttributedString?
  private let cachedSubTexts: [NSAttributedString?]

  /// 表情图到达后的"占位图 → 真图"版本（见 upgradeTexts()）。
  /// nonisolated(unsafe)+锁：写发生在主线程的表情回调，读可能来自行视图的贴模型。
  private let upgradeLock = NSLock()
  nonisolated(unsafe) private var upgraded: (text: NSAttributedString?, subs: [NSAttributedString?])?
  /// 已经嵌进富文本的表情 src 集合。用来判断"这次回调有没有真的带来新表情"。
  nonisolated(unsafe) private var embeddedEmoticons: Set<String> = []

  var contentText: NSAttributedString? { upgraded?.text ?? cachedText }
  var subPostTexts: [NSAttributedString?] { upgraded?.subs ?? cachedSubTexts }

  /// 本行引用、但当前还没进富文本的表情。
  ///
  /// ⚠️ 这里不能写成"升级过就返回空"。TiebaEmoticonCache.load 对**每个 URL 各回调一次**
  /// （见它的文档注释：命中内存缓存、被别的楼层在途的 URL 也会回调），所以一行有 N 个表情
  /// 就有 N 次回调。首个回调后若把 missing 报空、同时把富文本固化，后到的表情既不会触发重建、
  /// 也不会再被请求 —— 一行 3 个表情最终只会显示第 1 个。
  /// 返回"仍未嵌入"的差集才是真话，也让重复调用 load 变成幂等（Nuke 按 URL 合并 + 内存缓存）。
  var missingEmoticons: [String] {
    let all = self.allEmoticonSources
    upgradeLock.lock()
    defer { upgradeLock.unlock() }
    return all.filter { !embeddedEmoticons.contains($0) }
  }

  /// 本行引用的全部表情 src（不可变，锁外也能算）。
  private var allEmoticonSources: [String] {
    textBuild.missingEmoticons + subPostBuilds.flatMap(\.missingEmoticons)
  }

  /// 表情图到达后重建正文 + 楼中楼（尺寸不变，行高不变）。**结果缓存回模型**。
  ///
  /// 重建条件：这次回调**确实带来了新表情**。两个极端都要避开 ——
  ///   · "首个回调即固化"：后到的表情永远进不来（原来的写法）；
  ///   · "每次回调都重建"：一行 N 个表情白重建 N−1 次正文（正文排版是列表里最贵的一笔）。
  /// 所以按"已到达集合是否变化"来判：变了才重建，没变直接复用上次结果。
  func upgradeTexts() -> (text: NSAttributedString?, subs: [NSAttributedString?]) {
    // 纯缓存读，放锁外算，避免在持锁期间做 ImageCache 查询。
    let arrived = Set(self.allEmoticonSources.filter { TiebaEmoticonCache.shared.image(src: $0) != nil })

    upgradeLock.lock()
    defer { upgradeLock.unlock() }
    if arrived == embeddedEmoticons, let upgraded { return upgraded }
    embeddedEmoticons = arrived
    let built = (text: rebuiltText() ?? cachedText, subs: rebuiltSubTexts())
    upgraded = built
    return built
  }

  /// 表情图到达后重建（尺寸不变，行高不变）。
  func rebuiltText() -> NSAttributedString? {
    TiebaPostRowText.build(
      post,
      preferences: preferences,
      blockFilter: blockFilter,
      palette: palette
    ).attributed
  }

  /// 表情图到达后重建楼中楼预览（subPostTexts 是建模型时固化的占位图版本）；
  /// 尺寸不变、行高不变。
  func rebuiltSubTexts() -> [NSAttributedString?] {
    let subScale = Double(preferences.fontScaleClamped)
    return post.subPosts.map {
      let content = TiebaPostRowText.buildContent(
        $0.content,
        preferences: preferences,
        blockFilter: blockFilter,
        palette: palette,
        isSubPost: true
      ).build.attributed
      return TiebaPostRowText.subPostLine(
        name: $0.displayName, content: content, palette: palette, scale: subScale)
    }
  }

  /// 同一份输入换宽度重测（同步补测用）。刻意**重跑 init** 而不是按比例缩放高度：
  /// 换行/裁切/退档徽标都随宽度变化，缩放出来的高度与真实排版对不上，等于换了个假高度。
  func remeasured(containerWidth: CGFloat) -> TiebaPostRowModel {
    TiebaPostRowModel(
      pageKey: pageKey,
      index: index,
      post: post,
      isMain: isMain,
      canDelete: canDelete,
      threadAuthorId: threadAuthorId,
      toolbar: toolbar,
      preferences: preferences,
      blockFilter: blockFilter,
      palette: palette,
      forumName: forumName,
      containerWidth: containerWidth,
      title: sourceTitle,
      heroThreadId: heroThreadId
    )
  }

  init(
    pageKey: String,
    index: Int,
    post: TiebaThreadPost,
    isMain: Bool,
    canDelete: Bool,
    threadAuthorId: String,
    toolbar: TiebaPostToolbarModel?,
    preferences: TiebaPostPreferences,
    blockFilter: TiebaPostBlockFilter,
    palette: TiebaFeedRowPalette,
    forumName: String,
    containerWidth: CGFloat,
    title: String = "",
    heroThreadId: String? = nil
  ) {
    self.pageKey = pageKey
    self.index = index
    self.post = post
    self.isMain = isMain
    self.sourceTitle = title
    self.isLz = !post.authorId.isEmpty && post.authorId == threadAuthorId
    self.canDelete = canDelete
    self.threadAuthorId = threadAuthorId
    self.toolbar = toolbar
    self.preferences = preferences
    self.blockFilter = blockFilter
    self.palette = palette
    self.containerWidth = TiebaLayout.quantize(containerWidth)
    self.forumName = forumName
    self.heroThreadId = heroThreadId
    self.images = post.images
    self.imagesHidden = preferences.hideMedia
    self.video = preferences.hideMedia || preferences.blockVideo ? nil : TiebaPostRowText.video(post)
    self.videoPlaceholder = TiebaPostRowLayout.mediaPlaceholder(
      hasVideo: TiebaPostRowText.video(post) != nil,
      preferences: preferences
    )
    self.audio = TiebaPostRowText.audio(post)

    let build = TiebaPostRowText.build(
      post,
      preferences: preferences,
      blockFilter: blockFilter,
      palette: palette
    )
    self.textBuild = build
    self.showsBlockedTip = build.hasBlockedTip
    self.subPostBuilds = post.subPosts.map {
      TiebaPostRowText.buildContent(
        $0.content,
        preferences: preferences,
        blockFilter: blockFilter,
        palette: palette,
        isSubPost: true
      ).build
    }
    self.cachedText = build.attributed
    // 楼中楼预览每行 = 名字 + 冒号 + 正文合成一条富文本（见 TiebaPostRowText.subPostLine：
    // 两个排版引擎分行画名字/正文时首行基线对不齐、冒号还会重复）。
    let subScale = Double(preferences.fontScaleClamped)
    self.cachedSubTexts = zip(post.subPosts, subPostBuilds).map { sub, build in
      TiebaPostRowText.subPostLine(
        name: sub.displayName, content: build.attributed, palette: palette, scale: subScale)
    }
    self.avatarURL = TiebaSimpleRowParser.avatarURL(post.authorPortrait)
    self.nameText = post.displayName.isEmpty ? "吧友" : post.displayName
    self.levelShortText =
      preferences.showLevelBadge && post.authorLevel > 0 ? "Lv.\(post.authorLevel)" : nil
    // 头衔（User.level_name，随作者下发）：只在开关打开且徽标在时接在 Lv 后面。
    // ⚠️ 变量名不许叫 title —— 本 init 有个 title 参数（主贴卡的帖名），
    // 撞名会把卡片标题顶成头衔（2026-09-18 用户复报的"主贴卡标题变成等级标记"）。
    let levelTitle = post.authorLevelName.trimmingCharacters(in: .whitespacesAndNewlines)
    self.levelText =
      preferences.showLevelTitle && !levelTitle.isEmpty && self.levelShortText != nil
      ? "\(self.levelShortText ?? "") \(levelTitle)"
      : self.levelShortText
    self.levelColor = TiebaPostRowLayout.levelColor(post.authorLevel)
    self.metaText = TiebaPostRowLayout.metaText(
      post: post,
      isMain: isMain,
      preferences: preferences
    )
    self.likeText = post.agreeNum > 0 ? TiebaForumFormat.count(post.agreeNum) : ""
    self.titleText =
      isMain && !title.isEmpty
      ? TiebaSimpleText.makeAttributed(
        text: title,
        font: TiebaPostRowLayout.titleFont,
        lineHeight: TiebaPostRowLayout.titleLineHeight,
        truncating: TiebaPostRowLayout.titleLineLimit > 0
      )
      : nil
    // plan 只依赖上面这些已就位的值（自身尚未初始化完，不能把 self 传出去）。
    let plan = TiebaPostRowPlan(TiebaPostRowPlanInputs(
      containerWidth: self.containerWidth,
      isMain: isMain,
      post: post,
      titleText: self.titleText,
      nameText: self.nameText,
      levelText: self.levelText,
      levelShortText: self.levelShortText,
      isLz: self.isLz,
      metaText: self.metaText,
      likeText: self.likeText,
      contentText: build.attributed,
      subPostTexts: self.cachedSubTexts,
      showsBlockedTip: build.hasBlockedTip,
      hairline: preferences.hairline,
      fontScale: Double(preferences.fontScaleClamped),
      images: self.images,
      imagesHidden: self.imagesHidden,
      video: self.video,
      videoPlaceholder: self.videoPlaceholder,
      audio: self.audio,
      toolbar: toolbar
    ))
    self.plan = plan
    self.measuredHeight = plan.rowHeight
  }

  /// 单行替换（点赞/取消只改本行状态）：页/行/配色/偏好等全部沿用旧模型，只换
  /// post。整页 publish 会把每层楼的富文本装配与 TextKit 测量全部重跑一遍。
  convenience init(replacing model: TiebaPostRowModel, post: TiebaThreadPost) {
    self.init(
      pageKey: model.pageKey,
      index: model.index,
      post: post,
      isMain: model.isMain,
      canDelete: model.canDelete,
      threadAuthorId: model.threadAuthorId,
      toolbar: model.toolbar,
      preferences: model.preferences,
      blockFilter: model.blockFilter,
      palette: model.palette,
      forumName: model.forumName,
      containerWidth: model.containerWidth,
      title: model.titleText?.string ?? ""
    )
  }

  let likeText: String
}

/// 主贴行底部的回复工具栏（原 ThreadHeader 的 Reply Toolbar）。
struct TiebaPostToolbarModel: Sendable {
  var replyNum = 0
  var pageLabel: String?
  var seeLz = false
  var sort: TiebaThreadSort = .hot
}
