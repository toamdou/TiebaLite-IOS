// 从 TiebaFeedRowMotionViews.swift 拆出（按类型分文件，纯搬运、整类型逐字搬走）。
// 位图管线的唯一消费者（TiebaFeedRowTextCanvas 原与 Motion 视图同文件，名字与文件不符，故单列）。

import UIKit

// MARK: - 静态文字画布

/// 卡片静态文字画布：把卡内多段静态文字画进**同一张** backing store，省掉每段文字
/// 一个可见 CALayer 的绘制/合成与一份独立 backing store；并按行身份缓存位图，使
/// **来回滚动同一行不必重光栅化**（cell 复用会把画布换给别的行，否则每次复用都要重画）。
///
/// 绘制走 NSAttributedString.draw(with:options:context:)——与 UILabel 底层同一套排版
/// （图形/字体/行高都在属性串里），但**不需要 UIView 参与**。相比上一版把 9 段文字交给
/// 9 个隐藏 label：每行少 9 个视图对象、少 9 次 trait 传播。
///
/// **位图烘制已搬出主线程**（见 BitmapPipeline/，报告 07 的阶段 1+2）：
///   - 命中缓存 → 直接写 layer.contents（与旧路径逐字一致）；
///   - 滚动中未命中 → TiebaFeedBitmapBaker 后台烘，结果回主校验代次后再 attach
///     （对应 ASDK 的 displayBlock + _displaySentinel，ASDisplayNode+AsyncDisplay.mm:341-382）；
///   - 静止 / 首屏未命中 → 同步兜底一帧（对应 _ASDisplayLayer.mm:150-158 的 displayImmediately）。
/// 画布自己是 layer.contents 的**唯一所有者**：后台结果与预取产物都不直接碰图层。
///
/// 行数限制由 frame 高度承担，不用 numberOfLines：折叠态 title/abstract 的 frame 高度
/// 正是按 maxLines 量出来的，配 .truncatesLastVisibleLine 即在末行加省略号
///（NSStringDrawingContext.maximumNumberOfLines 是私有属性，SDK 头文件里没有，不采用）。
///
/// 坐标系（**容易写错，务必按这条来**）：plan 里所有 frame 都是**行坐标**——它的
/// cardX = cardMarginH、cardY = cardMarginV，即行内容的左上角加了卡片外边距。
/// 而画布是 cardView 的子视图，原点是卡片左上角 ⇒ 画布坐标 = 行坐标 − (cardMarginH,
/// cardMarginV)。所以喂给画布的每一段 frame 都要过 cardRect()（子视图走 place() 是同
/// 一条转换）。
/// ⚠️ 这里曾写成"画布与 plan 的 frame 同属 cardView 局部坐标、零换算"，照它做就漏掉转换，
/// 整组文字右下各偏 (16, 4)：名字压到头像下沿、标题右端顶出画布被提前截断（而截断是绘制
/// 期才知道的，测量期判不出截断 ⇒「显示更多」不出现）。
/// [可见性] 由 private 放开为模块内可见：内存告警入口在 App/TiebaAppBootstrap 要调
/// `invalidateCache()`（复检 P2-4），只放开这一个类型、不改任何行为。
final class TiebaFeedRowTextCanvas: UIView {
  /// 03-12 全仓清扫：宿主图层换成 `TiebaSimpleLayer`，隐式动画从类定义上关掉。
  ///
  /// 原来靠 `setContents` 里手包 `CATransaction.setDisableActions(true)`（见该方法）。
  /// 手包的三个老问题在这里都成立：新加一条写 `layer.contents` 的路径很容易忘；
  /// 事务是线程级的，包大一点会顺带压掉无关层；而且**快照/离屏渲染路径**
  /// 不经过 `setContents` 时没有保护。换 layerClass 之后，任何路径写属性都不会再
  /// 生成 0.25s 淡入 —— 这层本来就只有"整块换图"一种语义，本来也不该有过渡。
  override class var layerClass: AnyClass { TiebaSimpleLayer.self }

  /// 一段要画的文字：**已完全解析**的属性串（字体/颜色/行高都烘进属性里）+ 绘制矩形。
  ///
  /// 不持有 UILabel：绘制走 NSAttributedString.draw(with:options:context:)——与 UILabel
  /// 底层同一套排版，但不需要 UIView 参与。这带来两件事：每行少 9 个视图对象，
  /// 且该原语不绑主线程（它就是异步位图管线的输入）。
  /// **直接复用管线载荷**（原先这里是另立的一个同形 struct）：画布输入 = Job 输入，
  /// 同一份 runs 既喂本帧同步绘制、也喂后台烘制 / 预取。两份定义一旦漂移，预取烘出来的
  /// 位图就会与画布要画的不是同一张 —— 缓存键里**不含 runs**，只认
  /// (model, size, scale, styleRaw, paletteFingerprint)。
  /// naturalHeight 的语义见 BitmapPipeline/TiebaFeedBitmapJob.swift 的 Run：
  /// **阶段 0**：测量期预算的自然高（绘制期垂直居中用，省掉第二遍 CoreText 排版）。
  /// nil = 该段还没接上测量值，绘制期回落「有界量高」（= 旧行为，多一趟排版）。
  /// 画布这侧能直接给出的按行高给（名字/元信息/IP/显示更多/引用帖两段）；title /
  /// abstract / quoteContent 三段取 TiebaRowMetrics 测出的**未取整 usedRect 高**
  ///（exactHeight → blocks → plan.natural*Height）。9 段全接上后回落分支不再走到。
  typealias Run = TiebaFeedBitmapJob.Run

  /// 取消代次（并发三条铁律第 ③ 条）：主线程单调递增，后台烘制线程只读它。
  /// 换行/复用（clear）与换内容（update）都会自增 ⇒ 在途结果全部作废 ——
  /// 这就是四级取消里的第 1、2 级（换行/复用、换主题/换色板都经这两处）。
  private let epochBox = TiebaFeedBitmapEpoch()

  private var runs: [Run] = []
  private var bakedModel: AnyObject?
  private var bakedPalette: TiebaFeedRowPalette?

  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    // [长按卡片菜单] 画布原来是纯绘制层（关交互）：卡片长按菜单的宿主就挂在它上面。
    // 选它的原因是"命中链互不相交"——画布覆盖整卡、却压在图片/头像/徽章/操作栏等
    // 子视图**之下**：手指落在那张图上时画布根本不在命中链里，图片那套长按菜单原样
    // 生效；落在文字/卡面空白上才命中画布。同一行因此绝不会有两套长按抢手势。
    // 详见 TiebaFeedRowView.syncCardMenuInteraction()。
    isUserInteractionEnabled = true
    isAccessibilityElement = false
    accessibilityElementsHidden = true
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  /// 收集本轮要画的文字，并按 (模型, 色板, 尺寸, 缩放, 深浅档) 取或烘位图。
  /// frame 已在 plan 里算好（卡片坐标），画布与 labelHost 同在 (0,0) 同尺寸，零换算。
  func update(runs: [Run], model: AnyObject, palette: TiebaFeedRowPalette) {
    self.runs = runs
    bakedModel = model
    bakedPalette = palette
    // 先自增代次再取/烘：上一次的在途结果即使回来也不认（对应 _ASDisplayLayer.mm:188-193
    // 的 setNeedsDisplay → cancelAsyncDisplay）。
    applyBitmap(epoch: epochBox.next())
  }

  /// 清空（无模型 / 置顶横幅行：卡片整体隐藏，内容不该留着上一行的位图）。
  func clear() {
    runs = []
    bakedModel = nil
    bakedPalette = nil
    epochBox.next()   // 置空同样要作废在途结果，否则上一行的位图会贴到复用的行上
    setContents(nil)
  }

  /// 外观档或色板变化时由宿主调用：整表作废。
  /// **不在这里重烘**——applyPalette 是"先刷 layer 色、后 configure 文案色"，
  /// 此刻属性串可能还是旧色，重烘会把旧色位图存进新键。宿主清掉 placedToken 后
  /// 必然走一次完整布局，由 update 用配色完成的 runs 重烘。
  static func invalidateCache() {
    TiebaFeedBitmapStore.shared.invalidate()
  }

  // MARK: 位图

  private var scaleForDisplay: CGFloat { max(traitCollection.displayScale, 1) }

  /// 取缓存 / 烘位图 / attach。三个分支与旧实现一一对应，只是"未命中"这一支
  /// 拆成了滚动中（后台）与静止（同步兜底）—— 对应 ASDK 的 range controller 与
  /// displayImmediately 的分工。**不要无条件异步化**：那会让每张新卡空窗 1-2 帧。
  private func applyBitmap(epoch: UInt64) {
    guard let model = bakedModel, let palette = bakedPalette else {
      setContents(nil)
      return
    }
    let size = bounds.size
    guard !runs.isEmpty, size.width > 1, size.height > 1 else {
      setContents(nil)
      return
    }
    let scale = scaleForDisplay
    let traits = traitCollection
    // 缓存键 = 所有会影响像素的输入：模型身份 + 尺寸 + 缩放 + 深浅档 + 色板指纹。
    // ⚠️ 色板必须用 bitmapFingerprint（混 cgColor 分量），不能用 UIColor.hash ——
    // 动态色的 hash 只反映"这是动态色"这一身份，深浅两档会撞档（报告 07 §6 R1）。
    let key = TiebaFeedBitmapKey(
      model: ObjectIdentifier(model),
      size: size,
      scale: scale,
      styleRaw: traits.userInterfaceStyle.rawValue,
      paletteFingerprint: palette.bitmapFingerprint(in: traits)
    )
    if let image = TiebaFeedBitmapStore.shared.image(for: key) {
      setContents(image)
      return
    }
    // 未命中：**不要 setContents(nil)** —— 旧 contents 就是滚动期最合适的占位
    //（换行时 clear() 已经置空，那是另一回事）。
    let job = TiebaFeedBitmapJob(
      key: key,
      // Run 就是 TiebaFeedBitmapJob.Run（见画布的 typealias）：零转换、零拷贝。
      runs: runs,
      size: size,
      scale: scale,
      opaque: false,
      epoch: epoch
    )

    // 滚动中：后台烘，本帧不排版（提前量的正解是预取，见报告 07 §5.5）。
    // B1（移植自上游 submodules/RasterizedCompositionComponent/Sources/RasterizedCompositionComponent.swift:90-104
    // 的 hasAnimationsInTree、:379-387 的模式切换）：**本行在播动画时不做同步重烘** ——
    // 同步绘制会把动画那一帧顶掉。上游判据是"子树里有动画就用真图层、否则整棵栅格化"；
    // 本仓画布是叶子层、动画挂在行宿主层上，所以判据向上看（见 isRowAnimating）。
    // 只在已有 contents 时改走后台：首帧不兜底会白屏（见上方"不要无条件异步化"）。
    if TiebaFeedScrollGate.shared.isScrolling(in: self)
      || (self.isRowAnimating && self.layer.contents != nil) {
      // 只把 Atomic 的代次盒与模型身份箱带过线程边界：**不捕获 UIView**（哪怕是弱引用），
      // 后台从头到尾不碰任何共享可变状态。
      let box = epochBox
      let token = TiebaFeedBitmapModelToken(model)
      TiebaFeedBitmapBaker.shared.submit(
        job,
        traits: traits,
        epochProbe: { box.probe() }
      ) { [weak self] result in
        guard let result else { return }   // 被取消 / 绘制失败：保留旧 contents，不闪白
        Task { @MainActor in
          // 二次校验（对应 ASDisplayNode+AsyncDisplay.mm:365 的主线程再查一次）：
          // 代次仍是我这份、尺寸也没被换过，才允许写 layer.contents。
          guard let self, box.probe() == result.epoch, self.bounds.size == job.size else {
            return
          }
          TiebaFeedBitmapStore.shared.insert(result, model: token.model)
          self.setContents(result.image)
        }
      }
      return
    }

    // 静止 / 首屏：同步兜底一帧（用户看不到掉帧）。滚动中走到这里 = 本管线要消灭的开销。
    guard let image = TiebaFeedBitmapBaker.shared.renderSync(job, traits: traits) else {
      setContents(nil)   // 真失败（不是取消）：宁可空着，也不要留着上一行的位图
      return
    }
    TiebaFeedBitmapStore.shared.insert(
      image: image,
      key: key,
      bytes: job.byteCount,
      model: model
    )
    setContents(image)
  }

  /// 本行（自己 + 全部祖先层）是否有在跑的动画 —— 上游 hasAnimationsInTree 的对应物
  /// （RasterizedCompositionComponent.swift:90-104）。本仓的入场/点赞弹簧挂在行的宿主层上，
  /// 画布自己是叶子层，所以判据必须向上看。
  private var isRowAnimating: Bool {
    var current: CALayer? = self.layer
    while let layer = current {
      if let keys = layer.animationKeys(), !keys.isEmpty {
        return true
      }
      current = layer.superlayer
    }
    return false
  }

  /// 直接写 layer.contents（不走 draw(_:)）。
  ///
  /// 隐式动画已由宿主图层 `TiebaSimpleLayer.action(forKey:)` 统一关掉，这里不再手包
  /// `CATransaction`（03-12）。保留注释是因为**这条约定很容易被"顺手补回来"**：
  /// 若哪天有人把 `layerClass` 改回默认，就必须同时把事务包回来，否则 cell 复用
  /// 换位图会看到一次淡入过渡。
  private func setContents(_ image: CGImage?) {
    layer.contents = image
    layer.contentsScale = scaleForDisplay
  }
}
