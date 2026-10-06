// ============================================================
// TiebaLite — 通用行列表（TiebaKindListView）
//
// 纯 UIView：UICollectionView + TiebaRowListLayout（拉取式，帧由测量缓存逐个给出）+
// DiffableDataSource（CellRegistration 分派 simple/feed/post）；事件经 onListEvent 外传。
// 行宽契约 = TiebaLayout.quantize(列表宽 - 2×horizontalInset)，行种类路由见 TiebaKindRowPages。
// ============================================================

import os
import UIKit
import Nuke

/// 通用行列表的实体：UICollectionView + TiebaRowListLayout（拉取式，
/// 帧由测量缓存逐个给出）+ DiffableDataSource。事件经 `onListEvent` 闭包外传。
public final class TiebaKindListContentView: UIView {
  /// 帧高无源等"本该不可能"的诊断出口。**刻意不用 assertionFailure**：默认构建是
  /// Debug（.bazelrc: build --compilation_mode=dbg），断言在这类包里 = 用户闪退；
  /// 触发条件（页记录/度量被整页 LRU 挤掉、宿主已离窗的那一拍）恰好落在"返回上一级"。
  private static let log = Logger(subsystem: "com.tiebalite.app", category: "listkit")

  // MARK: 接口（纯 Swift）

  /// 事件出口（TiebaKindListEvent；页面按 case 模式匹配）。
  /// internal：事件枚举只在模块内使用。
  var onListEvent: ((TiebaKindListEvent) -> Void)?

  /// post 行的语义动作出口（原生页面用；与 onListEvent 并存，互不影响）。
  /// internal：TiebaPostRowEvent 只在模块内使用。
  var onPostEvent: ((_ index: Int, _ event: TiebaPostRowEvent) -> Void)?

  /// 连续滚动回调（浮动栏自动隐藏用；不对每一次滚动做任何计算）。
  public var onScroll: ((UIScrollView) -> Void)?

  /// 减速开始**之前**改写落点（移植自上游 submodules/ScrollComponent/Sources/ScrollComponent.swift:100-105
  /// 的 contentOffsetWillCommit —— 上游把 scrollViewWillEndDragging 的 targetContentOffset 直接透出）。
  /// 落点在提交前就改掉，而不是"先滑过去再跳回来"；惯性滚动的目标因此可以被外部对齐。
  /// [移植] 上游只透出指针：调用方要判"落点是否已在顶部"必须知道 adjustedContentInset，
  /// 而它只有滚动视图自己知道，故这里把 scrollView 一并给出（唯一一处签名扩展）。
  public var contentOffsetWillCommit: ((_ scrollView: UIScrollView, _ target: inout CGPoint) -> Void)?

  /// 程序自己改 contentOffset / contentSize 期间掐掉 didScroll 回调
  /// （上游 :127-131 的 ignoreDidScroll 护栏）。不掐会自激：程序性滚动 → didScroll →
  /// 回调里改状态或再改内容 → 又触发滚动；本仓的 onScroll（浮动栏）/ reachEnd / 甩动闸门
  /// 都在 didScroll 里，程序性滚动不该惊动它们。
  private var ignoreDidScroll = false

  /// 在"不惊动 didScroll 回调"的前提下改滚动位置。
  private func withoutScrollCallbacks(_ body: () -> Void) {
    let previous = ignoreDidScroll
    ignoreDidScroll = true
    body()
    ignoreDidScroll = previous
  }

  public private(set) var pageKey: String = ""

  /// 缺页自愈出口（由 TiebaRowPageDriver 注册）：当前页在共享存储里已不存在
  ///（被别的屏的整页 LRU 挤掉）时回调一次，宿主用同一页键重推即可恢复。
  /// 没有它时这条路是**静默留白**——行内容查不到就不配置、cell 保持清空态，
  /// 用户看到的就是"列表突然一片空白"（机制见 TiebaRowPagePins）。
  var onPageDataMissing: (() -> Void)?
  /// 让位请求：行还没落地就挂起（列表保持隐藏），等 `setPage` 落地再执行。
  /// 页记录是后台测量的产物——**数据到手 ≠ 行能画**，提前让位就是页头/页脚先画出来、
  /// 正文空白（吧页吧名片、楼中楼"只显示没有更多了"都是它）。各页 showList 一律走这里。
  func revealWhenReady(_ reveal: @escaping () -> Void) {
    guard hasRows else {
      pendingReveal = reveal
      return
    }
    pendingReveal = nil
    reveal()
  }
  /// 当前页是否已有可画的行（页记录已落地且行数 > 0）。
  private var hasRows: Bool { itemCount > 0 }
  private var pendingReveal: (() -> Void)?

  /// 页记录落地 → 补上被推迟的让位。
  private func flushPendingReveal() {
    guard hasRows, let reveal = pendingReveal else { return }
    pendingReveal = nil
    reveal()
  }
  /// 自愈通知节流：一屏几十行同时发现缺页只通知一次；反复失败则退避（见
  /// TiebaAdaptiveThrottle），离屏时直接按最大间隔合并。
  private var pageMissingThrottle = TiebaAdaptiveThrottle()

  /// 曾上过屏：首屏加载早于挂窗（那时 window == nil），降档判据要靠它把"还没上屏"
  /// 和"已被盖住/离屏"分开——前者正是用户正等的那一屏，不能降。
  private var hasBeenOnScreen = false

  /// 真正离屏（曾上屏且现在不在窗上）：后台活可降档。
  var isOffScreen: Bool { hasBeenOnScreen && !tiebaIsOnScreen }

  /// 滚动头 spec（TiebaKindListHeaderFactory 的输入；nil = 无页头）。
  /// 内容等值时忽略（Fabric 每次 commit 都可能是新字典，不能按引用重建视图）。
  public var headerSpec: [String: Any]? {
    didSet {
      guard !TiebaKindListContentView.specEquals(headerSpec, oldValue) else { return }
      rebuildHeader()
    }
  }

  public var footerState: TiebaKindFooterState = .hidden {
    didSet {
      guard footerState != oldValue else { return }
      // 页脚高是在布局趟现取的（makeGeometry → footerHeight），失效晚到本次
      // runloop 末尾不影响这一帧；入队去重见 TiebaGeometryInvalidationQueue。
      geometryInvalidations.invalidate()
      updateVisibleFooter()
    }
  }

  /// 首屏入场动画开关（EntranceRow 的等价：首批页面里新建 cell 播级联动画，
  /// 批次边界 = 首个布局趟的 willDisplay 走完，见 endEntranceBatch）。
  public var entranceAnimationEnabled: Bool = true

  /// 行左右内缩（= RN contentContainerStyle.paddingHorizontal）。声明值只是**下限**：
  /// 容器宽超出 TiebaLayout.maxContentWidth 时多出的宽度平分到左右、整列居中；读回值即
  /// 生效值（行宽契约 = 列表宽 − 2×本值，host 在布局趟读到的必须是新列宽）。
  public var horizontalInset: CGFloat {
    get { TiebaLayout.columnInset(for: bounds.width, minimum: declaredHorizontalInset) }
    set {
      guard newValue != declaredHorizontalInset else { return }
      declaredHorizontalInset = newValue
      // 列宽由 getter 现算、布局趟（makeGeometry）现取；合并后的失效仍早于当帧的
      // CA commit，所以宿主在布局趟读到的必然是新列宽。
      geometryInvalidations.invalidate()
    }
  }

  /// 内缩下限（调用方声明值；生效值见 horizontalInset 的 getter）。
  private var declaredHorizontalInset: CGFloat = 0

  /// 行间距（ItemSeparatorComponent 的原生等价：加在非末行高度里）。
  public var separatorHeight: CGFloat = 0 {
    didSet {
      guard separatorHeight != oldValue else { return }
      // 帧高缓存必须**同步**作废（同一 runloop 内紧接着就可能有人读 frameHeights）；
      // 只有布局失效入队。
      frameHeightCache = nil
      geometryInvalidations.invalidate()
    }
  }

  /// 触底阈值（视口高的比例；距内容底 < 阈值×视口高即发 reachEnd）。
  public var reachEndThreshold: CGFloat = 0.3

  /// 顶部内容内白（对齐 contentContainerStyle.paddingTop）。
  /// ⚠️ 这是**内容内白**（加在内容顶端之上、可随滚动滑出），不是
  /// collectionView.contentInset.top：后者会把系统 UIRefreshControl 的静止位
  /// 一起推下去（要拉 74pt 才看得见 spinner），与 RN 的 paddingTop 语义不同。
  /// 有页头时它落在页头之上（原 RN 的 paddingTop 也在 ListHeaderComponent 之上）。
  public var contentInsetTop: CGFloat = 0 {
    didSet {
      guard contentInsetTop != oldValue else { return }
      // 两份缓存作废与 contentInset 写入都同步做（是后续读的输入，不依赖失效）；
      // 只有布局失效入队。
      headerHeightCache = nil
      applyContentInset()
      geometryInvalidations.invalidate()
      updateVisibleHeader()
    }
  }

  /// 底部内容内缩（对齐 contentContainerStyle.paddingBottom）：系统标准做法
  /// （contentInset.bottom 扩展可滚动区，与 RN paddingBottom 同效）。
  public var contentInsetBottom: CGFloat = 0 {
    didSet {
      guard contentInsetBottom != oldValue else { return }
      applyContentInset()
    }
  }

  /// 拖尾侧滑动作（**系统实现**：trailingSwipeActionsConfigurationForItemAt +
  /// UIContextualAction）。每项 [{ action, title, icon, destructive,
  /// backgroundColor }]；空 = 无侧滑。系统负责手势/物理/揭示动画，点击回调
  /// 经 onListEvent(.swipeAction) 外传，数据变更仍由调用方执行。
  public var swipeActions: [[String: Any]] = []

  public var palette: TiebaSimpleRowPalette = .default {
    didSet {
      guard palette != oldValue else { return }
      refreshControl.tintColor = palette.base.primary
      updateVisibleFooter()
      headerContentView?.applyPalette(palette)
      // 换色会重跑页头的 applySpec（文本/字重可能变），列表侧那份"按宽缓存"必须
      // 一起作废，否则旧高度会把差额分给页头里的某一行（2026-09-17 报的空白）。
      headerHeightCache = nil
      geometryInvalidations.invalidate()
      // 在屏 cell 换色同步做：它是重绘、不是几何，不进事务队。
      for cell in collectionView.visibleCells {
        (cell as? TiebaKindListViewCell)?.applyPalette(palette)
        // 信息流行用 TiebaFeedRowPalette = 本页色板的 base（同一份主题字典
        // 两条视图族各自消费；行视图只重绘、不重测）。
        (cell as? TiebaKindListFeedCell)?.applyPalette(palette.base)
        // 帖子行同样吃 TiebaSimpleRowPalette；运行期换主题必须一起刷，否则留旧色。
        (cell as? TiebaKindListPostCell)?.applyPalette(palette)
      }
    }
  }

  /// 页数据已在度量缓存中（调用方先走 TiebaRowPageDriver / prepareBlocking）。
  /// 换页键 = 整页更换：reload 快照（identifier 全变，diff 无意义）；同页仅行数
  /// 变化走 diff 保滚动位。
  /// - Parameter identities: 每行的**内容身份**（`TiebaRowDiff.Entry.Identity`，与 `pageKey` 同序）。
  ///   传空数组 = 该页没有内容身份（帖子页等"整页重发"的路径）→ 退化为位置身份，
  ///   行为与改动前完全一致。信息流行由 `TiebaRowPageDriver` 传入真实身份，
  ///   从而让 diffable 按内容增量更新，而不是全量重配可见行。
  /// 当前页的**页记录对象**（种类 + 族内下标 + 行数），由本列表自己持有。
  ///
  /// [精简] 新增：页记录原来只存在共享存储（TiebaKindRowPages，整页 LRU(8)）里，
  /// 别的屏（典型是帖子页每加载一页就 publish 一条）插几页就会把「用户正在看的这一页」
  /// 挤掉 —— 行种类退化成 .simple、行数查成 0，于是走缺页自愈重推。列表自持之后，
  /// 共享存储的时效不再决定本列表能不能画（这是 pin 之外零成本的第二道保险）：
  /// 页记录很小（每行 kinds + 三个族内下标），每屏一份。
  /// `setPage` 时取一次；发布晚到（记录还没落地）时为 nil，由 reapplyPageIfNeeded 补取。
  private var currentPage: TiebaKindRowPage?

  /// 当前页每行的内容身份（与 `setPage` 传入的一致）。
  /// 
  /// [采用] 必须缓存：`reapplyPageIfNeeded()`（几何变化后的补失效）也要重发同一份身份，
  /// 否则那条路径会悄悄退回位置身份 —— 内容更新就又会走"全量重配"，把本改动的好处吃掉一半。
  private var currentIdentities: [TiebaRowDiff.Entry.Identity] = []

  /// 上次让可见行按当前宽度重配时用的**行宽**（量化值）—— N2 的"宽度代次"。
  /// 行字典里没有容器宽度，换宽后整行指纹逐行不变，只能靠它把"宽度变了"和"内容没变"区分开。
  private var lastReconfiguredWidth: CGFloat = 0

  /// 只刷新某一行的工具栏（翻页时页码变了、行高没变）：走可见 cell，不重测也不重配整行；
  /// 不可见的行下次配置时会从已就地更新的模型里拿到新页码。
  public func refreshToolbar(index: Int) {
    for case let cell as TiebaKindListPostCell in collectionView.visibleCells where cell.rowIndex == index {
      cell.refreshToolbar()
    }
  }

  public func setPage(pageKey: String, identities: [TiebaRowDiff.Entry.Identity] = []) {
    self.currentIdentities = identities
    let previousKey = self.pageKey
    let isSamePage = (previousKey == pageKey)
    self.pageKey = pageKey
    // [精简] 自持当前页记录：种类/顺序/行数不再取决于共享存储有没有被别的屏挤掉。
    // 共享存储里没有（发布晚到 / 已被整页 LRU 挤掉）时**同页保留已自持的那份** —— 否则
    // 一次同页重推（setPage 的常见调用形态）就会把自持的页记录又抹掉，等于没自持。
    if let record = TiebaKindRowPages.shared.page(pageKey: pageKey) {
      currentPage = record
    } else if previousKey != pageKey {
      currentPage = nil
    }
    if !isSamePage {
      // 在显页保活：换页即换绑，旧页立刻交还给 LRU。
      TiebaRowPagePins.shared.unpin(previousKey)
      syncPagePin()
      // 记住的行高是"上一页的行"的：换页必须清，否则新页的第 i 行会顶着旧页第 i 行的高度。
      rememberedHeights.removeAll(keepingCapacity: true)
    }
    // 拉取式布局按需取帧（见 TiebaRowListLayout）：行高变了只需作废缓存 + 失效布局，
    // 不再有"构建期快照"要重建。
    frameHeightCache = nil
    if !isSamePage {
      // 换页后可见区间即便与旧页数值相同（都 0…7）也必须重发，否则懒回填
      //（History/Subposts 依赖 visibleRangeChange）被去重吞掉。
      lastVisibleRange = nil
    }
    endRefreshing()
    // 行数取自页记录（[精简] 优先本列表自持的 currentPage）：度量被 LRU 淘汰时仍要画出
    // 等量占位行（行高走兜底），不能靠度量缓存的行数。
    let count = currentPage?.count ?? 0
    // [采用] 内容身份下，diffable 自己就能算出"哪几行变了"（旧身份消失 + 新身份出现），
    // 因此同页重推**不再需要 reconfigureSamePageItems() 把可见行全部重配**。
    // 位置身份（identities 未传，帖子页等整页重发路径）时行为不变，仍走全量重配。
    let useContentIdentity = identities.count == count && count > 0
    if isSamePage, count == itemCount {
      if useContentIdentity {
        var samePageSnapshot = NSDiffableDataSourceSnapshot<Int, TiebaKindItem>()
        samePageSnapshot.appendSections([0])
        samePageSnapshot.appendItems((0..<count).map {
          TiebaKindItem(pageKey: pageKey, identity: identities[$0], index: $0)
        }, toSection: 0)
        dataSource.apply(samePageSnapshot, animatingDifferences: false)
      } else {
        reconfigureSamePageItems()
      }
      refreshGeometry()
      flushPendingReveal()
      // 本次发布已按当前宽度产出内容：记下这一版宽度，避免紧随其后的布局趟再重配一次。
      lastReconfiguredWidth = itemWidth
      return
    }
    reachEndArmed = true
    itemCount = count
    if !entrancePlayed, count > 0 {
      entrancePlayed = true
      if entranceAnimationEnabled {
        entrancePending = true
      }
    }
    var snapshot = NSDiffableDataSourceSnapshot<Int, TiebaKindItem>()
    if count > 0 {
      snapshot.appendSections([0])
      // 内容身份优先；缺省（identities 为空或长度不符）退回位置身份 —— 见 setPage 的参数说明。
      // useContentIdentity 在外层已算好（同一判据，避免两处漂移）。
      snapshot.appendItems((0..<count).map { index in
        TiebaKindItem(
          pageKey: pageKey,
          identity: useContentIdentity
            ? identities[index]
            : TiebaRowDiff.Entry.Identity(fingerprint: UInt64(index), ordinal: 0),
          index: index
        )
      }, toSection: 0)
    }
    if isSamePage {
      // 同页重推（切排序/切只看楼主/点赞/回填）：先让 diffable 走完增删，再把整页标成
      // 重配（内容才是权威，标识不作数），最后失效布局——行高由拉取式布局重取。
      dataSource.apply(snapshot, animatingDifferences: false)
      if !useContentIdentity {
        reconfigureSamePageItems()
      }
      refreshGeometry()
    } else {
      dataSource.applySnapshotUsingReloadData(snapshot)
      // 换页键 = 整页更换：apply 完只需失效，不再整只换布局对象。
      refreshGeometry()
    }
    setNeedsLayout()
    flushPendingReveal()
    // 同上：整页/同页重建都按当前宽度产出，记下这一版宽度。
    lastReconfiguredWidth = itemWidth
  }

  /// 按当前几何失效布局（**入队**：同一 runloop 内的多处失效合并成一次）。行高/行数
  /// 变化都走这里：布局是拉取式的（TiebaRowListLayout），下一次布局趟会用新的帧高数组
  /// 重建**受影响的部分**，纯追加时前缀行的属性原样留用。
  /// 旧实现是组合布局的 `.custom` 组帧=构建期快照，必须整只换 layout 对象（= 整页属性
  /// 重建 + 可见 cell 全量重配，且正好落在"滚到底加载下一页"那一刻）。
  /// 语义不变：强失效要的是"属性一定重建"，而合并后的那一次仍早于当帧 CA commit，
  /// setPage 返回后的那一帧拿到的就是新几何。
  private func refreshGeometry() {
    geometryInvalidations.invalidateAndRebuild()
  }

  /// 事务队真正执行的那一次（一次数据变更 = 一次）。强失效是弱失效的超集：
  /// 同一批里出现过强请求就整批按强失效走。
  private func applyGeometryInvalidation(rebuild: Bool) {
    geometryInvalidationCount += 1
    if rebuild, let layout = collectionView.collectionViewLayout as? TiebaRowListLayout {
      layout.invalidateAndRebuild()
    } else {
      collectionView.collectionViewLayout.invalidateLayout()
    }
  }

  public func scrollToTop(animated: Bool) {
    withoutScrollCallbacks {
      collectionView.setContentOffset(
        CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
        animated: animated
      )
    }
  }

  // MARK: 在显页保活 / 缺页自愈

  /// 保活当前页——仅当挂在窗口上（= 确实在显示）。首次布局前 setPage 很常见，
  /// 那时 window == nil，"还没显示"的页没有保住的理由。
  ///
  /// [精简] 评估后**保留**（不是漏删）：pin 服务于**四个**存储中的"正在显示的这一份"，
  /// 而内容键只解决了其中一族的一部分问题 ——
  ///   · 页记录（TiebaKindRowPages）与三族**页索引**仍是整页 LRU：pin 掉的后果是行种类/
  ///     下标查不到（列表侧现由 currentPage 自持兜住，但 Message 列表的 liveRowCount、
  ///     Explore 的 rowCount 校验、Search/PostList 的自愈路径仍在共享存储上）；
  ///   · 帖子族（TiebaPostRowMetrics）本来就是整页键，没有内容键兜底；
  ///   · 行内容虽然内容键 + 跨页复用，但仍有行预算淘汰。
  /// 删掉 pin 的净效果是"正在显示的一页会更早被别的屏插页挤掉"，而它零运行成本（一次
  /// 集合判存），所以宁可留着。它**不服务于预取**（预取走 TiebaNuke 预取器，与页无关）。
  private func syncPagePin() {
    if tiebaIsOnScreen {
      TiebaRowPagePins.shared.pin(pageKey)
    } else {
      TiebaRowPagePins.shared.unpin(pageKey)
    }
  }

  // MARK: 页记录（自持优先）

  /// 页内行种类（[精简] 自持页记录优先）：页记录还在本列表手里就直接查它 —— 共享存储
  /// 的整页 LRU 挤不掉正在显示的这一页。`item.pageKey` 可能属于上一页（diffable 换页的
  /// 中间态），那就退回共享存储，与旧行为一致。
  private func kind(at index: Int, pageKey key: String) -> TiebaKindRowKind? {
    if key == pageKey, let currentPage { return currentPage.kind(at: index) }
    return TiebaKindRowPages.shared.kind(pageKey: key, index: index)
  }

  /// 页内行在它自己度量族页里的下标（自持页记录优先；见 kind(at:pageKey:)）。
  private func subIndex(at index: Int) -> Int? {
    if let currentPage { return currentPage.subIndex(at: index) }
    return TiebaKindRowPages.shared.subIndex(pageKey: pageKey, index: index)
  }

  /// 当前页行数（自持页记录优先；0 = 记录还没发布）。
  private var pageRowCount: Int { currentPage?.count ?? 0 }

  /// 当前页第 index 行的**内容身份**（列表本来就缓存了整页身份；缺省/长度不符 → nil，
  /// 此时只走位置查询）。行级度量缓存是内容键，所以它比位置查询稳：页索引被整页淘汰
  /// 也照样命中同一份测量。
  private func contentIdentity(at index: Int) -> TiebaRowDiff.Entry.Identity? {
    guard currentIdentities.count == itemCount, currentIdentities.indices.contains(index) else {
      return nil
    }
    return currentIdentities[index]
  }

  // MARK: 缺页自愈

  /// 发现**行内容确实没有测**（全局度量失效 / 换了宽度还没测完 / 页面发布晚到）：请宿主
  /// 用同一页键重推。重推是后台整页测量，不能被逐行通知打成风暴——按自适应间隔合并。
  ///
  /// [精简] 用途收窄：过去它还负责「页记录/整页度量被整页 LRU 挤掉」的自愈，现在
  ///   ①页记录由本列表自持（currentPage），②行内容是内容键 + 跨页复用，整页淘汰不再
  ///   必然致空白 —— 剩下的触发点都落在「内容真的不在」这一类上（那类只有重推能救）。
  private func notifyPageDataMissing() {
    guard onPageDataMissing != nil else { return }
    let now = ProcessInfo.processInfo.systemUptime
    guard pageMissingThrottle.shouldPass(now: now, inactive: isOffScreen) else { return }
    onPageDataMissing?()
  }

  /// 程序化滚动（scrollToTop / setContentOffset(animated:)）落位回调：
  /// 宿主用它做"回顶后刷新/收尾"，替代等待固定时长（动画结束才回）。
  var onScrollAnimationEnd: (() -> Void)?

  /// 是否已在顶部：回顶刷新据此判定"没有滚动动画可等"（否则刷新永不发生）。
  var isAtTop: Bool {
    collectionView.contentOffset.y <= -collectionView.adjustedContentInset.top + 0.5
  }

  public func endRefreshing() {
    guard refreshControl.isRefreshing else { return }
    refreshControl.endRefreshing()
    // 程序化 beginRefreshing 把 offset 压到刷新位（比静止位更低）——收尾时若
    // 还停在那儿（用户没在手拖），滚回静止位；用户主动下拉时交给橡皮筋自己回。
    if !collectionView.isDragging, !collectionView.isDecelerating,
       collectionView.contentOffset.y < -collectionView.adjustedContentInset.top - 0.5 {
      withoutScrollCallbacks {
        collectionView.setContentOffset(
          CGPoint(x: 0, y: -collectionView.adjustedContentInset.top),
          animated: true
        )
      }
    }
  }

  /// 程序化展示顶部刷新动画（底栏重按已在顶部时刷新用）：先起转再滚出可见位
  /// ——UIRefreshControl 只在 contentOffset 拉过阈值时可见，光 beginRefreshing
  /// 不滚是看不见的。收尾由数据侧 endRefreshing() 负责（reload 的 defer）。
  public func beginRefreshing() {
    guard !refreshControl.isRefreshing else { return }
    refreshControl.beginRefreshing()
    let reveal = max(refreshControl.bounds.height, 44)
    withoutScrollCallbacks {
      collectionView.setContentOffset(
        CGPoint(x: 0, y: -collectionView.adjustedContentInset.top - reveal),
        animated: true
      )
    }
  }

  // MARK: 状态

  private var itemCount = 0
  private var reachEndArmed = true
  private var lastVisibleRange: (start: Int, end: Int)?
  private var lastLaidOutSize: CGSize = .zero
  private var entrancePending = false
  private var entrancePlayed = false
  /// 首个布局趟的清标志已排程（entrancePending 的边界判定，见 endEntranceBatch）。
  private var entranceClearScheduled = false
  /// 整页帧高缓存：key =（pageKey, itemWidth, 行数）。布局输入不变时（页脚/主题/
  /// contentInset 变化都会 invalidateLayout）复用，不再逐行查度量（每行 2 次锁）。
  ///
  /// [精简] 评估后**保留**：它是本列表对"布局输入"的备忘，不是淘汰补偿 —— 删了它，每次
  /// 几何失效（页脚态/主题/contentInset/页头重建）都要 O(行数) 次加锁查询 + 逐行权威性判断，
  /// 而这些事件照样频繁。它会重算的唯一入口是 setPage（换页/重推）与布局失效，
  /// 即"度量变了"一定会走到，不会留下过期帧高。
  /// 帧高缓存 + **权威位图**（每行高度是不是当前宽度下的实测值）：可见窗口移到还没补测的
  /// 行上时缓存不再复用，否则那些行会一直顶着上一宽度的高度（N3）。
  private var frameHeightCache: (pageKey: String, width: CGFloat, heights: [CGFloat], authoritative: [Bool])?
  private weak var visibleFooterView: TiebaKindFooterView?
  private weak var visibleHeaderHostView: TiebaKindListHeaderHostView?
  /// 当前页头视图（headerSpec 造出；nil = 无页头）。
  private var headerContentView: (any TiebaKindListHeaderView)?
  /// 页头总高缓存（(列表宽) → contentInsetTop + 页头自适应高）。
  private var headerHeightCache: (width: CGFloat, height: CGFloat)?
  private var isBrowserPresented = false
  private let refreshControl = UIRefreshControl()

  private let prefetcher = TiebaNuke.makePrefetcher()

  /// 甩动闸门：高速滑动期间不启动预取（见 prefetchItemsAt）。
  private var isFlinging = false
  /// 判定"甩起来了"的竖直速度阈值（pt/s）。取高值：正常拖动/慢滑不受影响，
  /// 只有真甩动（每秒掠过好几行）才闸。
  private static let flingVelocityThreshold: CGFloat = 2500

  // MARK: 几何失效事务队

  /// 几何失效事务队：同一次 runloop 内的 N 处失效请求合并成 1 次真失效。
  /// 入口共 10 处（footerState / horizontalInset / separatorHeight / contentInsetTop /
  /// palette / setPage×3 / layoutSubviews / rebuildHeader）；设计与选型见
  /// TiebaGeometryInvalidationQueue 的头注。
  private lazy var geometryInvalidations = TiebaGeometryInvalidationQueue(
    apply: { [weak self] rebuild in
      self?.applyGeometryInvalidation(rebuild: rebuild)
    }
  )

  /// debug：真正执行过的几何失效次数（一次数据变更应当只 +1——验证"收成一条队"）。
  private(set) var geometryInvalidationCount = 0
  /// debug：入队请求次数（去重前）；与上者之差 = 被事务队合并掉的失效次数。
  var geometryInvalidationRequestCount: Int { geometryInvalidations.requestCount }

  // MARK: 子视图

  private lazy var collectionView: UICollectionView = {
    let view = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    view.backgroundColor = .clear
    view.isOpaque = false
    view.alwaysBounceVertical = true
    view.showsVerticalScrollIndicator = true
    view.contentInsetAdjustmentBehavior = .never
    view.allowsSelection = false
    view.register(
      TiebaKindFooterView.self,
      forSupplementaryViewOfKind: TiebaKindFooterView.elementKind,
      withReuseIdentifier: TiebaKindFooterView.reuseIdentifier
    )
    view.register(
      TiebaKindListHeaderHostView.self,
      forSupplementaryViewOfKind: TiebaKindListHeaderHostView.elementKind,
      withReuseIdentifier: TiebaKindListHeaderHostView.reuseIdentifier
    )
    return view
  }()

  private lazy var dataSource: UICollectionViewDiffableDataSource<Int, TiebaKindItem> = {
    let source = UICollectionViewDiffableDataSource<Int, TiebaKindItem>(
      collectionView: collectionView
    ) { [weak self] collectionView, indexPath, item in
      // weak 而不是 unowned：本闭包由 UIKit 侧（dataSource/collectionView）持有并调用，
      // 调用时点不由本仓控制（pop 转场中的布局趟、预取趟、reloadData…）。宿主已开始析构时
      // unowned 直接 SIGTRAP（"Attempted to read an unowned reference…"），weak 只是这一行
      // 不产出 cell，下一次布局趟自然会补上 —— 用户看到的是 0 影响，不是闪退。
      guard let self else { return nil }
      // [精简] 原「页记录被整页 LRU 挤掉 → 先请宿主重推」的探测点已删除：页记录由本
      // 列表自持（currentPage），能不能画只取决于本页记录里有没有这一行，与共享存储的
      // 时效无关。真正的度量缺失由各 cell 注册里的模型查询兜底（那才是内容真不在）。
      // 行种类分派：页记录说这一行是哪一族（缺省/未知 = simple，与旧页兼容）。
      switch self.kind(at: item.index, pageKey: item.pageKey) {
      case .feed:
        return collectionView.dequeueConfiguredReusableCell(
          using: self.feedCellRegistration,
          for: indexPath,
          item: item
        )
      case .post:
        return collectionView.dequeueConfiguredReusableCell(
          using: self.postCellRegistration,
          for: indexPath,
          item: item
        )
      case .simple, .none:
        return collectionView.dequeueConfiguredReusableCell(
          using: self.simpleCellRegistration,
          for: indexPath,
          item: item
        )
      }
    }
    // 补充视图：页头（top boundary item）+ 页脚（bottom boundary item），同一
    // provider 按 kind 分派；页头内容由本视图持有的 headerContentView 提供
    //（一页一个头，不做复用池）。
    source.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
      guard let self else { return nil }
      if kind == TiebaKindListHeaderHostView.elementKind {
        guard let host = collectionView.dequeueReusableSupplementaryView(
          ofKind: kind,
          withReuseIdentifier: TiebaKindListHeaderHostView.reuseIdentifier,
          for: indexPath
        ) as? TiebaKindListHeaderHostView else { return nil }
        host.configure(content: self.headerContentView)
        self.visibleHeaderHostView = host
        return host
      }
      guard kind == TiebaKindFooterView.elementKind else { return nil }
      guard let footer = collectionView.dequeueReusableSupplementaryView(
        ofKind: kind,
        withReuseIdentifier: TiebaKindFooterView.reuseIdentifier,
        for: indexPath
      ) as? TiebaKindFooterView else { return nil }
      footer.configure(state: self.footerState, palette: self.palette) { [weak self] in
        self?.handleFooterTap()
      }
      self.visibleFooterView = footer
      return footer
    }
    return source
  }()

  /// 简单行 cell（TiebaSimpleRowView；命中区域 = 行视图自己判定）。
  private lazy var simpleCellRegistration =
    UICollectionView.CellRegistration<TiebaKindListViewCell, TiebaKindItem> {
      [weak self] cell, indexPath, item in
      // 同 dataSource cellProvider：注册闭包由 UIKit 侧持有，宿主析构后仍可能被调一次。
      guard let self else { return }
      cell.onTap = { [weak self] point in
        self?.handleTap(at: indexPath, point: point)
      }
      cell.applyPalette(self.palette)
      let model = self.simpleModel(at: item.index)
      // [精简] 模型按**内容身份**优先取（见 simpleModel）：本页的度量页索引被整页淘汰
      // 也照样命中同一份测量 —— 走到这里的 nil 只剩「内容真的没测」，那才是重推能救的。
      if model == nil, !self.pageKey.isEmpty {
        self.notifyPageDataMissing()
      }
      cell.apply(model: model)
      if self.entrancePending {
        cell.playEntrance(index: item.index)
      }
    }

  /// 信息流行 cell（TiebaFeedRowView；行内菜单回传 + 整卡点击上报）。
  private lazy var feedCellRegistration =
    UICollectionView.CellRegistration<TiebaKindListFeedCell, TiebaKindItem> {
      [weak self] cell, indexPath, item in
      // 同 dataSource cellProvider：注册闭包由 UIKit 侧持有，宿主析构后仍可能被调一次。
      guard let self else { return }
      cell.onTap = { [weak self] point in
        self?.handleTap(at: indexPath, point: point)
      }
      cell.onRowMenuAction = { [weak self] action in
        self?.handleRowMenuAction(action, at: indexPath)
      }
      cell.onMediaMenuAction = { [weak self] mediaIndex, action in
        self?.handleMediaMenuAction(action, mediaIndex: mediaIndex, at: indexPath)
      }
      cell.onMediaOpen = { [weak self] mediaIndex in
        self?.openViewerFromPreview(at: indexPath, mediaIndex: mediaIndex)
      }
      cell.applyPalette(self.palette.base)
      // [精简] 族内下标改从**自持页记录**取（subIndex(at:)）：共享存储的页记录被整页淘汰
      // 不再让这里退化成「取不到下标 → 空行 + 重推」。
      if let sub = self.subIndex(at: item.index) {
        cell.apply(pageKey: item.pageKey, index: sub)
        // 行视图仍按 (pageKey, 族内下标) 取模型（TiebaFeedRowView 的契约，本次不动）：
        // 取不到才是内容真不在 —— 请宿主重推；查询与行视图完全一致，判据不漂移。
        if TiebaRowMetrics.shared.feedRow(pageKey: item.pageKey, index: sub) == nil {
          self.notifyPageDataMissing()
        }
      } else {
        self.notifyPageDataMissing()
      }
      if self.entrancePending {
        cell.playEntrance(index: item.index)
      }
    }

  /// 帖子行 cell（TiebaPostRowView；行内自管交互，cell 只转发事件）。
  private lazy var postCellRegistration =
    UICollectionView.CellRegistration<TiebaKindListPostCell, TiebaKindItem> {
      [weak self] cell, indexPath, item in
      // 同 dataSource cellProvider：注册闭包由 UIKit 侧持有，宿主析构后仍可能被调一次。
      guard let self else { return }
      cell.onPostEvent = { [weak self] event in
        self?.onPostEvent?(indexPath.item, event)
      }
      cell.applyPalette(self.palette)
      cell.apply(pageKey: item.pageKey, index: item.index)
      // 帖子行取不到模型会直接 isHidden（整行消失，看起来也是"空白"）→ 请宿主重推。
      // ⚠️ 必须走 postModel(at:)（内部过 subIndex），不能拿 item.index 直查度量：
      // 混合 kind 页里 subIndex != index，直查会让"cell 配置的模型"与"行高用的模型"
      // 不是同一行，而且两处各带缺页自愈判定会互相打架；当前只因 post 页一律以纯
      // .post 发布（subIndex == index）才没出事——那是隐含契约，不是保证。
      if self.postModel(at: item.index) == nil {
        self.notifyPageDataMissing()
      }
      if self.entrancePending {
        cell.playEntrance(index: item.index)
      }
    }

  // MARK: 初始化

  public override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    clipsToBounds = true

    addSubview(collectionView)
    collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    collectionView.frame = bounds
    collectionView.delegate = self
    collectionView.dataSource = dataSource
    collectionView.prefetchDataSource = self

    // ⚠️ 三个 cell 注册必须在这里就建好，不能等 cellProvider 首次访问 lazy 属性再建：
    // UIKit 会断言"registration 是在 cell provider 里创建的"并抛
    // NSInternalInconsistencyException（真机崩溃原文：Attempted to dequeue a cell
    // using a registration that was created inside … a UICollectionViewDiffableDataSource
    // cell provider）。三条具名访问就是"提前创建"本身——三者泛型不同，别写成数组。
    _ = simpleCellRegistration
    _ = feedCellRegistration
    _ = postCellRegistration

    refreshControl.addTarget(self, action: #selector(handleRefreshControl), for: .valueChanged)
    refreshControl.tintColor = palette.base.primary
    collectionView.refreshControl = refreshControl
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  deinit {
    prefetcher.stopPrefetching()
    // 销毁即交还保活位（否则 pin 表会留下永不再显示的页键，等于把 LRU 预算漏掉）。
    TiebaRowPagePins.shared.unpin(pageKey)
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    if collectionView.frame != bounds {
      collectionView.frame = bounds
    }
    // 宽度变化 = 行宽变化（高度缓存按宽度键控）：显式让 section provider 按新宽度
    // 重跑（量化口径见 TiebaLayout）。
    if bounds.size != lastLaidOutSize {
      lastLaidOutSize = bounds.size
      // 尺寸变化（旋转/分屏）同样入队：入队本身唤醒主队列，下一轮 runloop 立刻失效，
      // 仍落在显示刷新前的那次 commit——不会把新行宽拖到下一次无关事件。
      // （紧随其后的 reapplyPageIfNeeded → setPage 的强失效与它合并成同一次。）
      geometryInvalidations.invalidate()
      // setPage 早于首次布局时行宽为 0，行数查到 0、快照为空；布局拿到真实宽度
      // 后按新行宽重查一次（否则列表永久空白）。
      reapplyPageIfNeeded()
    }
    // 内容不足一屏时也要触发触底（首帧即 onEndReached 同语义）。
    updateReachEnd()
  }

  public override func didMoveToWindow() {
    super.didMoveToWindow()
    if tiebaIsOnScreen { hasBeenOnScreen = true }
    updatePrefetcherPause()
    // 挂窗 = 开始显示 → 保活当前页；离窗（被 push 的帖子页盖住、或整页销毁）
    // = 交还给 LRU。返回这一屏时列表不会重推，靠的正是这层保活 + 缺页自愈。
    syncPagePin()
  }

  private func updatePrefetcherPause() {
    // 离屏 ∥ 查看器打开：两个条件合成一处（否则"打开查看器 → 列表离屏 → 关
    // 查看器"会把离屏的那次暂停覆盖成运行态）。
    prefetcher.isPaused = isBrowserPresented || !tiebaIsOnScreen
  }

  /// 行宽变化后按新宽度复查页内行数；与当前 itemCount 不一致即重建快照。
  /// 行数取自页记录（宽度无关），两族度量的宽度失配由 cell/高度查询各自兜底。
  private func reapplyPageIfNeeded() {
    guard !pageKey.isEmpty else { return }
    // [精简] 页记录发布晚到时补取一次（自持优先；共享存储后把它挤掉也不影响已拿到的这份）。
    if currentPage == nil { currentPage = TiebaKindRowPages.shared.page(pageKey: pageKey) }
    // [N2] 宽度代次：行字典不含容器宽度 ⇒ 旋转/分屏后整行指纹逐行不变，同页重推会被
    // diffable 判成"零变化"，可见 cell 继续画旧宽度的 plan（新宽度行框里文字列宽/图片帧/
    // 卡片边距全错位），而全仓没有 viewWillTransition 兜底 —— 之前唯一的自愈是"滚出再滚回"。
    // 这里按**行宽**（TiebaLayout 量化值，与推页时的 containerWidth 同一式）比对：变了就重配一次。
    // reconfigureItems 只重跑 cell 提供者（模型按当前宽度现取）、不销毁 cell、不换页键，
    // 所以不是"整页重绑"；调用点在 layoutSubviews，同一布局趟最多一次，量化宽度相同的
    // 重复调用直接命中相等判断（分屏连续拖动按帧合并，不会每个 0.5pt 都重配）。
    let width = itemWidth
    if width != lastReconfiguredWidth {
      lastReconfiguredWidth = width
      if itemCount > 0 { reconfigureSamePageItems() }
    }
    let count = pageRowCount
    guard count != itemCount else { return }
    // [精简] 原「行数变 0 且快照非空 → notifyPageDataMissing()（页记录被整页 LRU 挤掉）」
    // 分支已删除：页记录由本列表自持，该状态不可达（发布晚到时 itemCount 也是 0，直接走
    // 下面的 setPage 重取）。行数确实变了（重推换了数据）仍照旧重建快照 —— 不清空。
    // [采用] 复用缓存的当前页身份（不能省略 —— 省略即退回位置身份，见 currentIdentities 注释）。
    setPage(pageKey: pageKey, identities: currentIdentities)
  }

  private func applyContentInset() {
    // 顶部内白**必须是真实的 contentInset.top**（不是内容内白）：`UIRefreshControl`
    // 的静止位挂在"内容顶"上方，而内容顶由 inset.top 决定——inset.top = 0 时内容顶
    // 贴着滚动视图顶（屏幕最上沿），下拉刷新动画就出现在灵动岛那一带被压扁
    //（用户 2026-09-17 报"应该在吧卡片上方"）。给了真实 inset 之后内容顶落在栏下，
    // 刷新动画出现在卡片上方、也在栏下。
    // 代价：下拉要拉过 inset 这一段才看得到 spinner（系统标准行为，Apple 自家列表同款）。
    collectionView.contentInset = UIEdgeInsets(
      top: max(contentInsetTop, 0),
      left: 0,
      bottom: contentInsetBottom,
      right: 0
    )
  }

  // MARK: 尺寸

  /// 单行宽 = TiebaLayout.quantize(集合视图宽 − 2×horizontalInset)；内缩已含居中留白，
  /// 故等价于 min(宽 − 2×声明内缩, maxContentWidth)。调用方推页时的 containerWidth 必须
  /// 按**同一式**算（= 列表宽 − 2×horizontalInset；各度量族的宽度闸门靠它命中）。
  private var itemWidth: CGFloat {
    TiebaLayout.quantize(max(collectionView.bounds.width - horizontalInset * 2, 0))
  }

  // 这里原先有两个**假高度**兜底（simple 行 72 / feed 行 160）。它们防的是同一个窗口：
  // 「同一内容在当前宽度下还没测过」（内容键把宽度算进了键，换宽后必然如此）。
  // 现在那个窗口由 frameHeight(at:width:syncRemeasure:) 的**同步补测**（TiebaRowMetrics.ensureFeedRow /
  // TiebaPostRowMetrics.ensureRow）当场关掉——不再需要任何与这一行无关的常量。
  // 残留的"连源都没有"那一帧走 rememberedHeights（这一行自己的上一次真实高度）。
  //
  // [N3] 但同步补测**只对可见窗口做**（syncRemeasureWindow）：换宽度后首个布局趟若为整页
  // 每一行当场跑 TextKit（400 楼 = 主线程数百次 1-5ms 排版），旋转动画与分屏拖动会冻结
  // 数百 ms～秒级，且分屏每个 0.5pt 量化步进都重来一轮。窗口之外的行这一帧顶它们**自己
  // 上一次的真实高度**（rememberedHeights，不是被删掉的常量假高度），随后由宿主页在后台按
  // 新宽度重测重推（TiebaPostListPageController.viewDidLayoutSubviews 的 resized 分支），
  // 或它们滚进可见窗口时当场补测——两条路都会让高度回到权威值。

  /// 每行**上一次真实测量**的高度（只在当前页内有效，换页即清）。
  /// 它与被删掉的假高度的区别：假高度是一个常量（与这一行毫无关系），
  /// 这里是这一行自己刚测出来的数——只在"连源数据都不在了"的那一帧顶一下。
  private var rememberedHeights: [Int: CGFloat] = [:]

  /// simple 行模型（当前列宽；cell 配置用）。
  private func simpleModel(at index: Int) -> TiebaSimpleRowModel? {
    simpleModel(at: index, width: itemWidth)
  }

  /// simple 行模型：**内容身份优先**，位置兜底。
  /// [精简] 行级度量缓存的键 =（内容身份, 宽度），所以本页的度量页索引被整页 LRU 挤掉
  /// 之后，同一行内容仍能命中（可能是别的页/别的屏测出来的那一份；值身份相同 ⇒ 渲染相同）。
  /// 位置查询保留：没传内容身份的路径（帖子页、旧调用方）行为不变。
  private func simpleModel(at index: Int, width: CGFloat) -> TiebaSimpleRowModel? {
    guard !pageKey.isEmpty else { return nil }
    if let identity = contentIdentity(at: index),
       let row = TiebaSimpleRowMetrics.shared.row(identity: identity, containerWidth: width) {
      return row
    }
    guard let sub = subIndex(at: index) else { return nil }
    return TiebaSimpleRowMetrics.shared.row(pageKey: pageKey, containerWidth: width, index: sub)
  }

  /// 信息流行模型（cell 配置 / 事件 / 预热用；宽度 = 当前列宽）。
  private func feedModel(at index: Int) -> TiebaFeedRowModel? {
    feedModel(at: index, width: itemWidth)
  }

  /// 信息流行模型：内容身份优先，位置兜底（同 simpleModel）。
  /// 位置分支是与 TiebaFeedRowView 完全相同的查询（行视图只拿得到 pageKey/下标）。
  private func feedModel(at index: Int, width: CGFloat) -> TiebaFeedRowModel? {
    guard !pageKey.isEmpty else { return nil }
    if let identity = contentIdentity(at: index),
       let row = TiebaRowMetrics.shared.feedRow(identity: identity, containerWidth: width) {
      return row
    }
    guard let sub = subIndex(at: index) else { return nil }
    return TiebaRowMetrics.shared.feedRow(pageKey: pageKey, index: sub)
  }

  /// 帖子行模型（族内下标 = 自持页记录给的 post 族下标）。
  private func postModel(at index: Int) -> TiebaPostRowModel? {
    guard !pageKey.isEmpty, let sub = subIndex(at: index) else { return nil }
    return TiebaPostRowMetrics.shared.row(pageKey: pageKey, index: sub)
  }

  /// 行高：**只来自真实测量**（假高度兜底已全部删除）。三条路径依次是：
  ///   ① 当前宽度已测 → 直接用；
  ///   ② 内容在、只是没在新宽度下测过（内容键含宽度 ⇒ 换宽后必然如此）→ **同步补测**一次
  ///      并写回内容键存储。这就是原来那两个假高度想绕过去的窗口，现在它不存在了；
  ///   ③ 连源都不在（页记录/模型确实没有）→ 用这一行**上一次的真实高度**顶住这一帧，
  ///      并触发缺页重推。一次都没测过的行走不到这里：页记录是测量完成后才发布的。
  ///   ④ [N3] 源在、只是不在同步窗口内（换宽度后的不可见行）→ 同样用 rememberedHeights
  ///      顶住，**不触发缺页重推**（数据没缺，只是还没按新宽度测）：等后台重推落地或滚进
  ///      可见窗口时再实测。
  ///
  /// - Parameter syncRemeasure: 这一行是否允许当场同步补测（= 在可见窗口内，见
  ///   syncRemeasureWindow）。换宽度后的首个布局趟只对窗口内补测，避免整页 TextKit 排版。
  /// - Returns: 高度 + 该高度是否为"当前宽度下的实测值"（帧高缓存据此判断能否复用）。
  private func frameHeight(
    at index: Int, width: CGFloat, syncRemeasure: Bool
  ) -> (height: CGFloat, authoritative: Bool) {
    var height: CGFloat
    var authoritative = true
    switch kind(at: index, pageKey: pageKey) {
    case .post:
      // 帖子行：高度自带（含卡片内外边距）；宽度闸门同 feed 行。
      if let model = postModel(at: index), model.containerWidth == width {
        height = model.measuredHeight
      } else if syncRemeasure, let sub = subIndex(at: index),
        let remeasured = TiebaPostRowMetrics.shared.ensureRow(
          pageKey: pageKey, index: sub, containerWidth: width)
      {
        height = remeasured.measuredHeight
      } else if let remembered = rememberedHeights[index] {
        authoritative = false
        height = remembered
      } else {
        notifyPageDataMissing()
        authoritative = false
        height = 0
      }
    case .feed:
      // 信息流行：高度 = 行模型自带（含卡片外 4pt 上下边距）。
      // 取模型走 feedModel(at:width:)（**内容身份优先**）：本页的度量页索引被整页 LRU
      // 挤掉也照样命中。
      if let row = feedModel(at: index, width: width), row.containerWidth == width {
        height = row.measuredHeight
      } else if syncRemeasure, let identity = contentIdentity(at: index),
        let remeasured = TiebaRowMetrics.shared.ensureFeedRow(
          identity: identity, pageKey: pageKey, index: index, containerWidth: width)
      {
        height = remeasured.measuredHeight
      } else if let remembered = rememberedHeights[index] {
        authoritative = false
        height = remembered
      } else {
        notifyPageDataMissing()
        authoritative = false
        height = 0
      }
    case .simple, .none:
      if let measured = simpleModel(at: index, width: width)?.measuredHeight, measured > 0 {
        height = measured
      } else if syncRemeasure, let identity = contentIdentity(at: index),
        let remeasured = TiebaSimpleRowMetrics.shared.ensureRow(
          identity: identity, pageKey: pageKey, index: index, containerWidth: width)
      {
        height = remeasured.measuredHeight
      } else if let remembered = rememberedHeights[index] {
        authoritative = false
        height = remembered
      } else {
        if pageRowCount > 0, !pageKey.isEmpty { notifyPageDataMissing() }
        authoritative = false
        height = 0
      }
    }
    if height > 0 {
      rememberedHeights[index] = height
    } else {
      // 残留分支：连"上一次真实高度"都没有（这一行从未测过）。按上面的契约它不该出现
      // （页记录是测量完成后才发布的）——这里仍然不编高度，但**不再 trap**：
      // 默认构建就是 Debug（.bazelrc: build --compilation_mode=dbg），assertionFailure 在
      // 那种包里会直接闪退，而触发条件（页记录/度量被整页 LRU 挤掉、宿主已离窗）恰好落在
      // "看完帖子返回上一级"这一拍 —— 用户报的偶发闪退与它同形。改为一律记 os_log 错误：
      // 开发期照样看得见（日志 + 0 高留白），但不再把用户的浏览打断；同分支上面的
      // notifyPageDataMissing() 会让宿主重推一次自愈。
      Self.log.error("frameHeight 无源：index=\(index, privacy: .public) kind=\(String(describing: self.kind(at: index, pageKey: self.pageKey)), privacy: .public) pageKey=\(self.pageKey, privacy: .public)")
    }
    // ItemSeparatorComponent 等价：行间距加在非末行（末行后不留空带）。
    if index < itemCount - 1 {
      height += separatorHeight
    }
    return (height, authoritative)
  }

  /// 可见窗口外多补几行：滚动时下一屏的行常落在窗口外沿，缓冲几行免得"滚一行补测一行"。
  private static let syncRemeasureBuffer = 4

  /// 同步补测窗口 = 可见行 ± 缓冲（N3）。可见 cell 为空（首帧还没有 cell）时取顶部一小段：
  /// 那一趟正是"首屏要立刻画准"的时刻。
  private func syncRemeasureWindow(count: Int) -> ClosedRange<Int> {
    guard count > 0 else { return 0...0 }
    let visible = collectionView.indexPathsForVisibleItems.map(\.item)
    guard let low = visible.min(), let high = visible.max() else {
      return 0...min(count - 1, 8)
    }
    let buffer = Self.syncRemeasureBuffer
    return max(low - buffer, 0)...min(high + buffer, count - 1)
  }

  /// 整页帧高：按 (pageKey, itemWidth, 行数) 缓存 **+ 权威位图**。页脚/主题/contentInset 变化
  /// 都会 invalidateLayout，但帧高输入没变——只重建失效部分，不逐行重查度量。
  ///
  /// [N3] 缓存只在"当前可见窗口整段都权威（当前宽度实测过）"时才复用：否则滚到还没补测的行上
  /// 会一直读上一宽度的高度。窗口外的非权威行留在缓存里也没关系——它们一旦进入可见窗口，
  /// 这个条件就会让这一趟重算并当场补测。宿主页后台重推落地时走 setPage（会清这份缓存）。
  private func frameHeights(width: CGFloat, count: Int) -> [CGFloat] {
    let window = syncRemeasureWindow(count: count)
    if let cache = frameHeightCache,
       cache.pageKey == pageKey,
       cache.width == width,
       cache.heights.count == count,
       cache.authoritative.count == count,
       window.allSatisfy({ cache.authoritative[$0] })
    {
      return cache.heights
    }
    var heights: [CGFloat] = []
    var authoritative: [Bool] = []
    heights.reserveCapacity(count)
    authoritative.reserveCapacity(count)
    for index in 0..<count {
      let row = frameHeight(at: index, width: width, syncRemeasure: window.contains(index))
      heights.append(row.height)
      authoritative.append(row.authoritative)
    }
    frameHeightCache = (pageKey, width, heights, authoritative)
    return heights
  }

  // MARK: 滚动头（top boundary supplementary item）

  private var hasHeader: Bool { headerContentView != nil }

  /// 页头项高 = 页头在**内容列宽**下的自适应高（顶部内白由 contentInset.top 承担）。
  /// 页头与行共用同一列（左缘 = horizontalInset、宽 = itemWidth），量多少就画多少；
  /// 0 = 不挂页头。缓存按宽度键控：宽度变化（旋转/分屏）时由 layoutSubviews 的 invalidate 重算。
  private func headerTotalHeight(width: CGFloat) -> CGFloat {
    guard let headerContentView else { return 0 }
    if let cache = headerHeightCache, cache.width == width {
      return cache.height
    }
    // 内白已由 contentInset.top 承担，页头项高 = 页头自身的自适应高。
    let height = headerContentView.headerHeight(forWidth: width)
    headerHeightCache = (width, height)
    return height
  }

  /// spec 变化 → 重建页头视图（spec 等值时不会走到这里，见 headerSpec.didSet）。
  private func rebuildHeader() {
    headerContentView?.removeFromSuperview()
    headerContentView = headerSpec.flatMap { TiebaKindListHeaderFactory.make(spec: $0) }
    headerContentView?.onAction = { [weak self] action, payload in
      self?.handleHeaderAction(action, payload)
    }
    headerContentView?.applyPalette(palette)
    headerHeightCache = nil
    geometryInvalidations.invalidate()
    updateVisibleHeader()
  }

  /// 在屏 host 重新接管页头（spec/insets/主题变化时；高度变化由 invalidateLayout
  /// 重跑 section provider 完成）。
  private func updateVisibleHeader() {
    visibleHeaderHostView?.configure(content: headerContentView)
  }

  /// 页头动作转事件（动作已类型化，payload 原样透传：只承载视图测量几何）。
  private func handleHeaderAction(_ action: TiebaKindListHeaderAction, _ payload: [String: Any]) {
    onListEvent?(.headerAction(action: action, payload: payload))
  }

  /// spec 等值比较（Fabric 每次 commit 都可能给新字典；引用比较会重建视图）。
  private static func specEquals(_ lhs: [String: Any]?, _ rhs: [String: Any]?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
      return true
    case let (lhs?, rhs?):
      return NSDictionary(dictionary: lhs).isEqual(to: rhs)
    default:
      return false
    }
  }

  // MARK: 布局（拉取式 TiebaRowListLayout）

  private func makeLayout() -> TiebaRowListLayout {
    let layout = TiebaRowListLayout()
    // 几何来源是闭包（现取）而非快照：prepare 时读到的行数与数据源一致，追加后
    // 只重建新增尾部的属性，前缀行留用。
    layout.geometryProvider = { [weak self] in
      guard let self else { return TiebaRowListLayoutInput() }
      return self.makeGeometry()
    }
    return layout
  }

  /// 行数与数据源同源（`numberOfItems` 在无 section 时会抛，先判段数）。
  private var currentItemCount: Int {
    collectionView.numberOfSections > 0 ? collectionView.numberOfItems(inSection: 0) : 0
  }

  private func makeGeometry() -> TiebaRowListLayoutInput {
    let width = itemWidth
    let count = currentItemCount
    let containerWidth = collectionView.bounds.width
    guard count > 0, width > 0, containerWidth > 0 else { return TiebaRowListLayoutInput() }
    // 行宽来源与 itemWidth / frameHeight 完全同一处（collectionView.bounds.width）
    // ——两边算法必须逐位一致，否则高度查询的宽度闸门拒绝命中：新宽度下查不到行高，
    // 只有可见窗口能当场同步补测，窗口外先沿用上一次的真实高度（不再是假高度）。
    var input = TiebaRowListLayoutInput()
    input.heights = frameHeights(width: width, count: count)
    input.itemWidth = width
    input.horizontalInset = horizontalInset
    input.containerWidth = containerWidth
    // 页头在内容顶（随内容滚走，不吸附）；内白由滚动视图 contentInset.top 承担。
    // 页头按内容列宽测量（与 TiebaRowListLayout 落帧的宽同源），画的宽度就是量的宽度。
    input.headerHeight = headerTotalHeight(width: width)
    input.footerHeight = TiebaKindFooterView.height(for: footerState)
    return input
  }


  // MARK: 快照辅助

  /// 同页重推的整页重配。行标识是 (pageKey, index)，**不含内容**：内容换了标识却一字
  /// 不变，而 diffable 只重配"变了"的行 ⇒ 行数一变（哪怕只差一行）那些没变的行就留着
  /// 旧 cell，要滚动一趟重新配 cell 才刷新（用户实证：切排序后旧回复残留）。
  private func reconfigureSamePageItems() {
    var snapshot = dataSource.snapshot()
    let items = snapshot.itemIdentifiers
    guard !items.isEmpty else { return }
    snapshot.reconfigureItems(items)
    dataSource.apply(snapshot, animatingDifferences: false)
  }

  // MARK: 事件

  private func handleTap(at indexPath: IndexPath, point: CGPoint) {
    guard !pageKey.isEmpty else { return }
    let index = indexPath.item
    // 信息流行：命中区域按行模型 layoutPlan 判定（几何单一来源 = TiebaFeedRowInteraction），
    // 真实图片点击 → 原生查看器直开（不发事件）。
    if kind(at: index, pageKey: pageKey) == .feed {
      guard let row = feedModel(at: index) else {
        onListEvent?(.rowTap(index: index, region: "card", actionIndex: nil))
        return
      }
      // 列表→详情已知数据快照（原 TweetCard 的 setThreadSnapshot）：帖子页首帧
      // 就能画出已加载过的标题/作者/摘要/首图，不必等首包。点任何一块都写，
      // 一次性消费 + 同 id 才命中，写多无害。
      var snapshot = TiebaThreadSnapshot(row: row)
      // 顺手把列表里已经解好的首图位图带上：占位卡按卡片宽取图（与列表文本列宽不同，
      // Nuke 缓存键也不同），不带它的话进帖会先显示一片灰再跳图。
      snapshot.thumbnailImage =
        (collectionView.cellForItem(at: indexPath) as? TiebaKindListFeedCell)?.loadedThumbnailImage
      TiebaThreadSnapshots.set(snapshot)
      let hit = TiebaFeedRowInteraction.tapRegion(for: point, row: row)
      if hit.region == "media", !row.media.isEmpty {
        if let cell = collectionView.cellForItem(at: indexPath) as? TiebaKindListFeedCell,
           let media = cell.mediaHit(at: point),
           presentPhotoBrowser(row: row, media: media, at: indexPath) {
          return
        }
        // 媒体区里没真点到图（首图左边的空白、末图之后的余量、格间空隙）→ 按整卡
        // 处理（进帖）。**不能报 region=media**：各页那一支是给视频 poster 用的
        // 「有图就 return」，报 media 会变成点了没反应（用户报的空白区行为反过来
        // 也说明这里必须落到卡）。
        onListEvent?(.rowTap(index: index, region: "card", actionIndex: nil))
        return
      }
      onListEvent?(.rowTap(index: index, region: hit.region, actionIndex: hit.actionIndex))
      return
    }
    // 简单行：命中区域由行视图给出（"avatar" = 作者点击区，其余 = 整卡）。
    let cell = collectionView.cellForItem(at: indexPath) as? TiebaKindListViewCell
    let region = cell?.hitRegion(at: point) ?? "card"
    onListEvent?(.rowTap(index: index, region: region, actionIndex: nil))
  }

  /// 图片带的**初始**预取区间：与带视口相交的格 + 其后 2 格（与
  /// TiebaFeedRowView.extendStripLoadWindow 同一口径：预取与展示必须同窗口，
  /// 否则两边各自解码一遍）。未上屏的行带偏移恒为 0（首格左缘对齐内容列）。
  private func stripPrefetchRange(_ row: TiebaFeedRowModel) -> Range<Int> {
    let frames = row.plan.mediaItemFrames
    guard !frames.isEmpty, let mediaFrame = row.plan.mediaFrame, mediaFrame.width > 0 else {
      return 0..<0
    }
    var last = -1
    for (index, frame) in frames.enumerated() where frame.minX < mediaFrame.width {
      last = max(last, index)
    }
    guard last >= 0 else { return 0..<0 }
    return 0..<min(last + 3, frames.count)
  }

  /// 行内菜单（右上角「更多」的 ActionSheet；行视图自弹，选中项只回传）。
  private func handleRowMenuAction(_ action: String, at indexPath: IndexPath) {
    onListEvent?(.menuAction(index: indexPath.item, action: action))
  }

  /// 不感兴趣退场：先让该行播折叠动画（数据保持在位），动画结束（真 completion，
  /// Reduce Motion 同步回调）后删数据。行已滚出/被复用 → 直接回调。
  func collapseRowThen(atIndex index: Int, remove: @escaping () -> Void) {
    let indexPath = IndexPath(item: index, section: 0)
    guard !pageKey.isEmpty,
          let item = dataSource.itemIdentifier(for: indexPath), item.pageKey == pageKey,
          let cell = collectionView.cellForItem(at: indexPath) as? TiebaKindListFeedCell
    else {
      remove()
      return
    }
    cell.playCollapse(completion: remove)
  }

  /// 图片长按菜单（保存照片 / 分享照片）事件外传（水印偏好/相册权限/toast 由
  /// 调用方执行）。url/originURL 缺媒体或对应字段时传 nil。
  private func handleMediaMenuAction(_ action: String, mediaIndex: Int, at indexPath: IndexPath) {
    var url: String?
    var originURL: String?
    if let row = feedModel(at: indexPath.item), mediaIndex >= 0, mediaIndex < row.media.count {
      let media = row.media[mediaIndex]
      url = media.url?.absoluteString
      originURL = media.originURL?.absoluteString
    }
    onListEvent?(.mediaAction(
      index: indexPath.item,
      mediaIndex: mediaIndex,
      action: action,
      url: url,
      originURL: originURL
    ))
  }

  // MARK: 查看器退出重算（几何只读查询；行不可见/未挂载 → nil 走框架 Fade）

  /// feed 行：行内第 mediaIndex 张图的窗口矩形；行已滚出/被复用/该图滑出图片带 → nil。
  func feedMediaWindowRect(rowIndex: Int, mediaIndex: Int) -> CGRect? {
    let indexPath = IndexPath(item: rowIndex, section: 0)
    guard !pageKey.isEmpty,
          let item = dataSource.itemIdentifier(for: indexPath), item.pageKey == pageKey,
          let cell = collectionView.cellForItem(at: indexPath) as? TiebaKindListFeedCell
    else { return nil }
    return cell.mediaWindowRect(atMediaIndex: mediaIndex)
  }

  /// post 行：第 imageIndex 张图的窗口矩形；同上，拿不到 → nil。
  func postImageWindowRect(rowIndex: Int, imageIndex: Int) -> CGRect? {
    let indexPath = IndexPath(item: rowIndex, section: 0)
    guard !pageKey.isEmpty,
          let item = dataSource.itemIdentifier(for: indexPath), item.pageKey == pageKey,
          let cell = collectionView.cellForItem(at: indexPath) as? TiebaKindListPostCell
    else { return nil }
    return cell.imageWindowRect(at: imageIndex)
  }

  /// 图片长按「点预览进大图」：只受理仍在本页/在屏的 feed 行，几何用该格当前
  /// 窗口矩形（mediaWindowRect，与点图/退出重算同一份换算）；拿不到（行已复用、
  /// 图滑出视口）就不开——不另造几何。入口与点图完全相同（presentPhotoBrowser）。
  private func openViewerFromPreview(at indexPath: IndexPath, mediaIndex: Int) {
    let index = indexPath.item
    guard !pageKey.isEmpty,
          kind(at: index, pageKey: pageKey) == .feed,
          let item = dataSource.itemIdentifier(for: indexPath), item.pageKey == pageKey,
          let row = feedModel(at: index),
          let cell = collectionView.cellForItem(at: indexPath) as? TiebaKindListFeedCell,
          let windowRect = cell.mediaWindowRect(atMediaIndex: mediaIndex)
    else { return }
    _ = presentPhotoBrowser(row: row, media: (index: mediaIndex, windowRect: windowRect), at: indexPath)
  }

  /// 图片点击 → 原生查看器（TiebaPhotoBrowser）直开：items/transition 全原生
  /// 构建，不发 rowTap。
  /// 揭示移位（useViewerSourceReveal 的原生等价）在展示转场完成回调里滚动列表，
  /// transition 用移位后矩形；打开期间暂停 Nuke 预取，关闭事件恢复。
  private func presentPhotoBrowser(
    row: TiebaFeedRowModel,
    media: (index: Int, windowRect: CGRect),
    at indexPath: IndexPath
  ) -> Bool {
    guard let plan = TiebaFeedRowInteraction.browserPlan(
      row: row,
      tappedMediaIndex: media.index,
      windowRect: media.windowRect,
      in: window,
      contentOffset: collectionView.contentOffset.y,
      contentSize: collectionView.contentSize,
      adjustedContentInset: collectionView.adjustedContentInset
    ) else {
      return false
    }
    // 关闭出口是本次 present 的私有 onClose（会话同一时刻只有一个；未受理即永不
    // 回调，无全局订阅可放回）：关闭后恢复"查看器打开期间暂停预取"的状态。
    // 闭包只带 Sendable 值（Int 数组/下标/位移），不把非 Sendable 的 plan 带进主机回调。
    let mediaIndexes = plan.mediaIndexes
    let rowIndex = indexPath.item
    let scrollDelta = plan.scrollDelta
    // 揭示移位：等查看器展示转场真正完成（onPresented；Reduce Motion 直显也会回）
    // 再滚动——此刻 Modal 已盖住列表，滚动不可见，也不会干扰 Zoom 转场。
    let onPresented: @MainActor @Sendable () -> Void = { [weak self] in
      guard let self, self.isBrowserPresented, let scrollDelta else { return }
      // 揭示移位是程序性滚动：不掐回调时它会惊动 reachEnd（可能在查看器打开期间
      // 误发一次"加载更多"）与浮动栏。
      self.withoutScrollCallbacks {
        self.collectionView.setContentOffset(
          CGPoint(x: 0, y: self.collectionView.contentOffset.y + scrollDelta),
          animated: true
        )
      }
    }
    let presented = TiebaPhotoBrowser.present(
      items: plan.items,
      initialIndex: plan.initialIndex,
      transition: plan.transition,
      // 被点那一格已加载的图：权威转场源（plan 给的矩形本来就是这一格的窗口矩形）。
      sourceImage: (collectionView.cellForItem(at: indexPath) as? TiebaKindListFeedCell)?
        .mediaImage(atMediaIndex: media.index),
      sourceFrameProvider: { [weak self] pageIndex in
        // 页号 → 行内 media 下标（url 为 nil 被过滤时会错位）→ 当前可见矩形。
        guard let self, mediaIndexes.indices.contains(pageIndex) else { return nil }
        return self.feedMediaWindowRect(
          rowIndex: rowIndex,
          mediaIndex: mediaIndexes[pageIndex]
        )
      },
      onClose: { [weak self] in
        self?.isBrowserPresented = false
        self?.updatePrefetcherPause()
      },
      onPresented: onPresented
    )
    if presented {
      isBrowserPresented = true
      updatePrefetcherPause()
    }
    return presented
  }

  private func handleFooterTap() {
    TiebaSceneHaptics.fire("press")
    onListEvent?(.footerTap)
  }

  private func updateVisibleFooter() {
    guard let footer = visibleFooterView else { return }
    footer.configure(state: footerState, palette: palette) { [weak self] in
      self?.handleFooterTap()
    }
  }

  @objc private func handleRefreshControl() {
    onListEvent?(.refreshRequested)
  }

  /// 视口区间（含端点）：仅变化时上报（调用方用它做页存活兜底）。
  private func updateVisibleRange() {
    let visible = collectionView.indexPathsForVisibleItems
    guard !visible.isEmpty else {
      lastVisibleRange = nil
      return
    }
    var first = Int.max
    var last = Int.min
    for path in visible {
      first = min(first, path.item)
      last = max(last, path.item)
    }
    guard lastVisibleRange?.start != first || lastVisibleRange?.end != last else { return }
    lastVisibleRange = (first, last)
    onListEvent?(.visibleRangeChange(start: first, end: last, count: itemCount))
  }

  /// 触底（阈值制）：距内容底 < 阈值×视口高 且已武装 → 发一次 reachEnd；
  /// 离开阈值区重新武装（一次性语义）。
  private func updateReachEnd() {
    guard itemCount > 0, !pageKey.isEmpty else { return }
    let inset = collectionView.adjustedContentInset
    let visibleHeight = collectionView.bounds.height
    guard visibleHeight > 0 else { return }
    // setPage 末尾的 setNeedsLayout 会先触发 layoutSubviews：此刻集合视图尚未
    // 按新快照布局（contentSize = 0/上一页高），负距离会直接误发 reachEnd。
    guard collectionView.contentSize.height > 0 else { return }
    let distance = collectionView.contentSize.height
      + inset.bottom
      - (collectionView.contentOffset.y + visibleHeight)
    let trigger = max(reachEndThreshold, 0) * visibleHeight
    if distance > trigger {
      reachEndArmed = true
      return
    }
    guard reachEndArmed else { return }
    reachEndArmed = false
    onListEvent?(.reachEnd(count: itemCount))
  }

  /// 首屏入场批次边界：首个布局趟里所有 willDisplay 已走完（下个 runloop 才清
  /// 标志），后续滚动回填的 cell 不再播入场——替代原来的 0.5s 时间窗口。
  private func endEntranceBatch() {
    guard entrancePending, !entranceClearScheduled else { return }
    entranceClearScheduled = true
    DispatchQueue.main.async { [weak self] in
      self?.entrancePending = false
    }
  }
}

// MARK: - UICollectionViewDelegate

extension TiebaKindListContentView: UICollectionViewDelegate {
  public func collectionView(
    _ collectionView: UICollectionView,
    willDisplay cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    updateVisibleRange()
    updateReachEnd()
    endEntranceBatch()
  }

  public func collectionView(
    _ collectionView: UICollectionView,
    didEndDisplaying cell: UICollectionViewCell,
    forItemAt indexPath: IndexPath
  ) {
    updateVisibleRange()
  }

  public func scrollViewDidScroll(_ scrollView: UIScrollView) {
    // ⚠️ 这里**不**扫可见区间：willDisplay/didEndDisplaying 对每次进出都会回调，
    // 区间只可能在那些时刻变化；滚动回调里再扫一遍等于每帧一次
    // indexPathsForVisibleItems（数组分配 + 逐个 IndexPath），而绝大多数帧的区间
    // 与上一帧相同 ⇒ 纯浪费（120Hz 下每秒 120 次）。
    guard !ignoreDidScroll else { return }
    updateFlingGate(scrollView)
    updateReachEnd()
    onScroll?(scrollView)
  }

  /// 减速开始前给外部一次改写落点的机会（上游 ScrollComponent.swift:100-105）。
  public func scrollViewWillEndDragging(
    _ scrollView: UIScrollView,
    withVelocity velocity: CGPoint,
    targetContentOffset: UnsafeMutablePointer<CGPoint>
  ) {
    contentOffsetWillCommit?(scrollView, &targetContentOffset.pointee)
  }

  public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
    if !decelerate { setFlinging(false) }
  }

  public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
    setFlinging(false)
  }

  /// 甩动判定：拖拽/惯性中且竖直速度过阈值。速度掉回阈值以下（用户慢下来了）
  /// 或滚动结束就放闸——放闸那一拍补一次可见窗口的预取，把闸住的那几行补上。
  private func updateFlingGate(_ scrollView: UIScrollView) {
    let moving = scrollView.isDragging || scrollView.isDecelerating
    let fast = abs(scrollView.panGestureRecognizer.velocity(in: scrollView).y)
      > Self.flingVelocityThreshold
    setFlinging(moving && fast)
  }

  private func setFlinging(_ value: Bool) {
    guard value != isFlinging else { return }
    isFlinging = value
    guard !value else { return }
    prefetchVisibleWindow()
  }

  /// 放闸后补预取：只取当前可见窗口（预取窗口由 UIKit 在后续滚动中自然补齐）。
  private func prefetchVisibleWindow() {
    guard !pageKey.isEmpty, tiebaIsOnScreen else { return }
    let paths = collectionView.indexPathsForVisibleItems
    guard !paths.isEmpty else { return }
    let requests = prefetchRequests(for: paths)
    guard !requests.isEmpty else { return }
    prefetcher.startPrefetching(with: requests)
  }

  /// 程序化滚动落位（setContentOffset(animated:)/scrollToTop 的完成回调）。
  public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
    setFlinging(false)
    onScrollAnimationEnd?()
  }

  /// 拖尾侧滑（**系统自带**，替代手写 TiebaSwipeActionView）：手势/物理/揭示
  /// 动画全由 UIKit 负责，本方法只按调用方下发的配置组装动作。
  /// 视觉映射（删除动作的原参数）：
  ///   actionBackgroundColor #FF3B30 → UIContextualAction.backgroundColor；
  ///   symbol trash 17 semibold → UIImage(systemName:, pointSize:)；
  ///   title 删除 → UIContextualAction.title。
  /// ⚠️ 与手写版的差异（系统不可配置，已报告）：动作条为整行高、无 4/16pt 外边距
  /// 与 16pt 连续圆角；图标与标题由系统纵向堆叠。
  public func collectionView(
    _ collectionView: UICollectionView,
    trailingSwipeActionsConfigurationForItemAt indexPath: IndexPath
  ) -> UISwipeActionsConfiguration? {
    guard !swipeActions.isEmpty else { return nil }
    var actions: [UIContextualAction] = []
    for spec in swipeActions {
      guard let actionId = spec["action"] as? String, !actionId.isEmpty else { continue }
      let destructive = (spec["destructive"] as? Bool) ?? false
      let action = UIContextualAction(
        style: destructive ? .destructive : .normal,
        title: spec["title"] as? String
      ) { [weak self] _, _, completion in
        guard let self else {
          completion(false)
          return
        }
        self.onListEvent?(.swipeAction(index: indexPath.item, action: actionId))
        // 数据变更由调用方执行，系统只负责收拢动作条。
        completion(true)
      }
      if let icon = spec["icon"] as? String, !icon.isEmpty {
        action.image = UIImage(
          systemName: icon,
          withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        )
      }
      if let raw = spec["backgroundColor"] as? String, let color = tiebaColor(from: raw) {
        action.backgroundColor = color
      }
      actions.append(action)
    }
    guard !actions.isEmpty else { return nil }
    let configuration = UISwipeActionsConfiguration(actions: actions)
    configuration.performsFirstActionWithFullSwipe = true
    return configuration
  }
}

// MARK: - 预取（Nuke ImagePrefetcher；按行种类分派同处理器请求）

extension TiebaKindListContentView: UICollectionViewDataSourcePrefetching {
  public func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
    // 甩动期间不预取：预取会给"马上就被划走"的行启动完整取图管线（建任务 + 读缓存
    // + 解码 + 缩放 + 写回内存缓存），主线程上落一份、后台又与滚动抢 CPU/带宽——
    // 掉一帧的感觉就是这么来的。停下来那一拍再补（见 setFlinging(false) 的
    // prefetchVisibleWindow）。慢滑/拖动不受影响。
    guard !isFlinging else { return }
    let requests = prefetchRequests(for: indexPaths)
    if !requests.isEmpty {
      prefetcher.startPrefetching(with: requests)
    }
    // 位图预热：与取图**并行**的第二条独立管线（BitmapPipeline/ 说明 §四.1）。
    // 预取窗口里就把行位图烘进 TiebaFeedBitmapStore，等 cell 上屏时画布的
    // applyBitmap 直接命中缓存 —— 否则第一次出现的行仍是静止路径的同步烘制
    // （异步化的收益全丢在这一拍）。
    // ⚠️ 不随 requests 是否为空短路：纯文本行（无头像/无图/无吧徽章）同样有 9 段
    // 文字要趁预取窗口烘好，而取图那条本来就没活干。
    prewarmFeedBitmaps(at: indexPaths)
  }

  /// 位图预热（只写缓存、不 attach；谁拥有 layer.contents 始终是画布）。
  ///
  /// Job 必须与画布**同键**，逐字段对齐 TiebaFeedRowTextCanvas.applyBitmap：
  ///   size    = plan.cardFrame.size（= cardView.bounds = 画布 bounds）
  ///   scale   = max(displayScale, 1)（= 画布的 scaleForDisplay）
  ///   styleRaw / paletteFingerprint = 本视图 traitCollection 与 palette.base
  ///   runs    = TiebaFeedRowView.makeRuns（与画布同一条静态纯函数产出）
  ///   epoch   = 0（纯预取，不发生取消；见 TiebaFeedBitmapJob 的 epoch 契约）
  /// ⚠️ 键里**不含 runs**，只认 (model, size, scale, styleRaw, paletteFingerprint) ——
  /// 所以 runs 也必须同源，否则画布会命中一张"键对但内容不对"的位图。
  /// ⚠️ **只在 kind == .feed 时**做：simple / post 行各有自己的绘制路径，不走位图管线。
  /// ⚠️ 甩动期间不预热（prefetchItemsAt 顶部的 isFlinging 闸门）——与取图同一条纪律。
  private func prewarmFeedBitmaps(at indexPaths: [IndexPath]) {
    guard !pageKey.isEmpty else { return }
    let traits = traitCollection
    let scale = max(traits.displayScale, 1)
    let styleRaw = traits.userInterfaceStyle.rawValue
    let palette = self.palette.base
    let paletteFingerprint = palette.bitmapFingerprint(in: traits)
    for path in indexPaths {
      guard kind(at: path.item, pageKey: pageKey) == .feed else {
        continue
      }
      // 与展示侧取同一个行模型（feedModel 就是 cell 配置用的那条查询）；置顶横幅行
      // 走 bannerView、画布恒被 clear()，预热它只会白烘一张永远不会命中的位图。
      guard let model = feedModel(at: path.item), !model.isTopBanner else { continue }
      let size = model.plan.cardFrame.size
      let key = TiebaFeedBitmapKey(
        model: ObjectIdentifier(model),
        size: size,
        scale: scale,
        styleRaw: styleRaw,
        paletteFingerprint: paletteFingerprint
      )
      let job = TiebaFeedBitmapJob(
        key: key,
        runs: TiebaFeedRowView.makeRuns(
          model: model,
          palette: palette,
          quoteVisible: TiebaFeedRowView.isQuoteVisible(model: model)
        ),
        size: size,
        scale: scale,
        opaque: false,
        epoch: 0
      )
      TiebaFeedBitmapStore.shared.prewarm(job, traits: traits, model: model)
    }
  }

  public func collectionView(
    _ collectionView: UICollectionView,
    cancelPrefetchingForItemsAt indexPaths: [IndexPath]
  ) {
    let requests = prefetchRequests(for: indexPaths)
    guard !requests.isEmpty else { return }
    prefetcher.stopPrefetching(with: requests)
  }

  /// 预取请求必须与展示侧同 URL（secureURL）+ 同处理器：Nuke 的缓存键含处理器，
  /// 裸 URL 预取既不命中展示缓存，还会把全尺寸位图写进内存缓存。
  private func prefetchRequests(for indexPaths: [IndexPath]) -> [ImageRequest] {
    guard !pageKey.isEmpty else { return [] }
    // UIScreen.main 自 iOS 26 起废弃：像素口径取本视图 trait 的 displayScale。
    let scale = max(traitCollection.displayScale, 1)
    var seen = Set<String>()
    var requests: [ImageRequest] = []
    // 目标像素口径与展示侧逐一对齐（feed=fitProcessor，simple/post=resizeProcessor）。
    func append(_ url: URL?, maxPixel: CGFloat, mode: TiebaNuke.Mode) {
      guard let url, maxPixel > 0 else { return }
      let secure = TiebaNuke.secureURL(url)
      let key = "\(secure.absoluteString)#\(maxPixel)#\(mode)"
      guard seen.insert(key).inserted else { return }
      let pixel = CGSize(width: maxPixel, height: maxPixel)
      requests.append(
        ImageRequest(
          url: secure,
          processors: [
            mode == .fit
              ? TiebaNuke.fitProcessor(targetPixelSize: pixel)
              : TiebaNuke.resizeProcessor(targetPixelSize: pixel),
          ]
        )
      )
    }
    /// 显示档预取：与展示侧（tiebaPostLoadDisplayImage）传入同一组参数 ⇒ 同一
    /// 处理器 ⇒ 同一缓存键；尺寸/圆角不同就是另一次解码，不能只按 URL 去重。
    /// URL 不加工（显示档 = 服务端原样字段；CDN 的 sign 绑定变换段，改写会被
    /// 打回占位图，见 TiebaNuke「GIF 三档」注）。
    /// - Parameter fit: true = 单图 **fit 档**（`TiebaNuke.fitDisplayProcessor`，与展示侧
    ///   `loadFitDisplay` 同参 ⇒ 同处理器 ⇒ 同缓存键）；false = 图片带/头像的 **fill 档**。
    ///   两档是不同处理器、不同缓存键，必须各按展示侧的口径预取 —— 混用等于预取整趟白做，
    ///   而且 fill 位图会以展示永不查询的键挤占内存缓存。
    func appendDisplay(_ url: URL?, size: CGSize, radius: CGFloat, fit: Bool = false) {
      guard let url, size.width > 1, size.height > 1 else { return }
      let secure = TiebaNuke.secureURL(url)
      let key = "\(secure.absoluteString)#\(fit ? "fit" : "display")#\(Int(size.width))x\(Int(size.height))#\(radius)"
      guard seen.insert(key).inserted else { return }
      let processor: any ImageProcessing = fit
        ? TiebaNuke.fitDisplayProcessor(targetSize: size, cornerRadius: radius, scale: scale)
        : TiebaNuke.displayProcessor(targetSize: size, cornerRadius: radius, scale: scale)
      requests.append(ImageRequest(url: secure, processors: [processor]))
    }
    for path in indexPaths {
      switch kind(at: path.item, pageKey: pageKey) {
      case .feed:
        guard let row = feedModel(at: path.item), !row.isTopBanner else { continue }
        append(row.avatarURL, maxPixel: TiebaFeedRowLayout.avatarSize * scale, mode: .fit)
        if row.showsMedia {
          if row.mediaIsStrip {
            // 带的显示目标 = 帧计划里那一格的真实尺寸（与展示侧 loadDisplay 同口径）。
            // **只预取初始窗口**（可见 + 2 格，口径同 TiebaFeedRowView.extendStripLoadWindow）：
            // 展示侧已经改成懒加载，这里若仍预取全部 9 张，等于把省下的解码又做了一遍。
            for index in stripPrefetchRange(row) {
              let media = row.media[index]
              appendDisplay(
                media.url,
                size: row.plan.mediaItemFrames[index].size,
                radius: 0
              )
            }
          } else {
            // 改前症状：这里调的是 fill 档 appendDisplay，而展示侧单图走 loadFitDisplay（fit 档）
            // ⇒ 两键永不相等：预取整趟「下载→解码→fill 裁切→烘焙」白做，fill 位图还以展示永不
            // 查询的键塞进内存缓存。旧注释自称「同参数 ⇒ 同缓存键」，与实现相反。
            // 改后行为：单图支按 fit 档预取，尺寸取与展示侧**同一来源** row.geometry.textColumnWidth，
            // 圆角同为 16 ⇒ 处理器与缓存键都与展示侧一致。
            let columnWidth = row.geometry.textColumnWidth
            let height = row.singleMediaHeight ?? 0
            if let url = row.media.first?.url, height > 0 {
              appendDisplay(
                url,
                size: CGSize(width: columnWidth, height: height),
                radius: 16,
                fit: true
              )
            } else {
              append(
                row.media.first?.url ?? row.videoPosterURL,
                maxPixel: max(height, columnWidth) * scale,
                mode: .fit
              )
            }
          }
        }
        if row.showsForumChip {
          append(
            row.forumAvatarURL,
            maxPixel: TiebaFeedRowLayout.chipAvatarSize * scale,
            mode: .fit
          )
        }
      case .post:
        guard let row = postModel(at: path.item), !row.imagesHidden,
              row.preferences.imageLoadType != "all_no" else { continue }
        append(row.avatarURL, maxPixel: row.plan.avatarFrame.width * scale, mode: .fill)
        guard let imagesFrame = row.plan.imagesFrame else { continue }
        let single = row.images.count == 1
        let shown = row.images.prefix(TiebaPostRowLayout.maxImages)
        for (index, image) in shown.enumerated() {
          let frame = single || !row.plan.imageItemFrames.indices.contains(index)
            ? imagesFrame
            : row.plan.imageItemFrames[index]
          guard let url = TiebaPostRowText.displayURL(image, preferences: row.preferences) else {
            continue
          }
          appendDisplay(url, size: frame.size, radius: TiebaPostRowLayout.imageRadius)
        }
      case .simple, .none:
        guard let row = simpleModel(at: path.item) else { continue }
        append(row.avatarURL, maxPixel: row.avatarSize * scale, mode: .fill)
      }
    }
    return requests
  }
}
