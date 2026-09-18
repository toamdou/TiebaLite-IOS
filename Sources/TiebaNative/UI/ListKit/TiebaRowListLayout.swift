// ============================================================
// 行列表布局（拉取式）：几何由宿主现取，数据变化只需 invalidateLayout()。
//
// 组合布局的 .custom 组帧是**构建期快照**，行数/行高一变就只能整只换布局对象
//（= 整页属性重建 + 可见 cell 全量重配，且正好落在"滚到底加载下一页"那一刻）。
// 拉取式只在可见区间上取属性，追加时前缀行的属性原样留用——每加载一页只花
// "新增行"的代价。做法与 IGListCollectionViewLayout 同源（按需给尺寸，不做快照）。
// ============================================================

import UIKit

/// 布局输入：单一 section；行左缘 = horizontalInset、宽 = itemWidth、高 = heights[i]；
/// 页头在内容顶、页脚在最后一行之后，两者都随内容滚走（不吸附）。
struct TiebaRowListLayoutInput: Equatable {
  var heights: [CGFloat] = []
  var itemWidth: CGFloat = 0
  var horizontalInset: CGFloat = 0
  var containerWidth: CGFloat = 0
  var headerHeight: CGFloat = 0
  var footerHeight: CGFloat = 0

  /// 无内容（行数为 0 或宽度未就位）= 不挂页头页脚（与旧组合布局的空 section 同口径）。
  var isEmpty: Bool { heights.isEmpty || itemWidth <= 0 || containerWidth <= 0 }
}

/// 拉取式布局。几何来源是闭包（宿主现取）而非快照：UIKit 在取属性前必先
/// `prepare()`，所以行数刚变、快照还没 apply 完时读到的也是新行数，不会出现
/// "属性比数据源少一行"（旧组合布局的 section provider 靠的也是同一时序）。
final class TiebaRowListLayout: UICollectionViewLayout {
  /// 几何来源。宿主用 `[weak self]` 闭包赋值，避免布局 → 宿主成环。
  var geometryProvider: (() -> TiebaRowListLayoutInput)?

  /// 属性缓存（下标 = 行号）：只在 prepare 里建，滚动路径不再分配。
  private var itemAttributes: [UICollectionViewLayoutAttributes] = []
  private var headerAttributes: UICollectionViewLayoutAttributes?
  private var footerAttributes: UICollectionViewLayoutAttributes?
  /// 最后一行之后的 y（= 页脚位置）；追加时它同时是"已建属性的前缀高之和"。
  private var itemsBottom: CGFloat = 0
  /// prepare 用过的输入：等值时直接返回（页脚/主题变更会重复失效）。
  private var preparedInput = TiebaRowListLayoutInput()

  /// 丢弃属性缓存并失效：下一次布局趟的 `prepare()` 必然重建（即使几何与上次逐位相同）。
  ///
  /// 与裸 `invalidateLayout()` 的区别只在"几何恰好没变"这一种情形：那时裸失效会被
  /// `guard input != preparedInput` 短路、留下按旧行数建的属性。清空 `preparedInput`
  /// 保证重建一定发生。不直接调 prepare()——UIKit 在取属性前必调它，自己提前调只会
  /// 在数据源尚未稳定的窗口里读行数。
  func invalidateAndRebuild() {
    preparedInput = TiebaRowListLayoutInput()
    invalidateLayout()
  }

  override func prepare() {
    super.prepare()
    let input = geometryProvider?() ?? TiebaRowListLayoutInput()
    guard input != preparedInput else { return }
    let previous = preparedInput
    preparedInput = input

    headerAttributes = nil
    footerAttributes = nil
    guard !input.isEmpty else {
      itemAttributes = []
      itemsBottom = 0
      return
    }
    let heights = input.heights
    let count = heights.count
    // 纯追加（行宽/内缩/页头高不变 且 旧行高逐位未变）：前缀行的属性对象留用，
    // 只给新增尾部造属性——这是相对"整页重建"省下的那一笔。
    let reuse: Int
    if itemAttributes.count == previous.heights.count,
       previous.heights.count < count,
       previous.itemWidth == input.itemWidth,
       previous.horizontalInset == input.horizontalInset,
       previous.headerHeight == input.headerHeight,
       Self.isPrefix(previous.heights, of: heights) {
      reuse = previous.heights.count
    } else {
      reuse = 0
    }
    if reuse == 0 {
      itemAttributes = []
      itemsBottom = input.headerHeight
    }
    itemAttributes.reserveCapacity(count)
    var y = itemsBottom
    for index in reuse..<count {
      let attributes = UICollectionViewLayoutAttributes(
        forCellWith: IndexPath(item: index, section: 0)
      )
      attributes.frame = CGRect(
        x: input.horizontalInset,
        y: y,
        width: input.itemWidth,
        height: heights[index]
      )
      itemAttributes.append(attributes)
      y += heights[index]
    }
    itemsBottom = y

    if input.headerHeight > 0 {
      let header = UICollectionViewLayoutAttributes(
        forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
        with: IndexPath(item: 0, section: 0)
      )
      header.frame = CGRect(
        x: 0,
        y: 0,
        width: input.containerWidth,
        height: input.headerHeight
      )
      headerAttributes = header
    }
    if input.footerHeight > 0 {
      let footer = UICollectionViewLayoutAttributes(
        forSupplementaryViewOfKind: UICollectionView.elementKindSectionFooter,
        with: IndexPath(item: 0, section: 0)
      )
      footer.frame = CGRect(
        x: 0,
        y: itemsBottom,
        width: input.containerWidth,
        height: input.footerHeight
      )
      footerAttributes = footer
    }
  }

  override var collectionViewContentSize: CGSize {
    guard !preparedIsEmpty else { return .zero }
    return CGSize(
      width: preparedInput.containerWidth,
      height: itemsBottom + preparedInput.footerHeight
    )
  }

  override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
    guard indexPath.section == 0, itemAttributes.indices.contains(indexPath.item) else { return nil }
    return itemAttributes[indexPath.item]
  }

  override func layoutAttributesForSupplementaryView(
    ofKind elementKind: String,
    at indexPath: IndexPath
  ) -> UICollectionViewLayoutAttributes? {
    switch elementKind {
    case UICollectionView.elementKindSectionHeader:
      return headerAttributes
    case UICollectionView.elementKindSectionFooter:
      return footerAttributes
    default:
      return nil
    }
  }

  override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
    var result: [UICollectionViewLayoutAttributes] = []
    if let headerAttributes, headerAttributes.frame.intersects(rect) {
      result.append(headerAttributes)
    }
    if !itemAttributes.isEmpty {
      // 二分找首个 frame.maxY > rect.minY 的行，再顺次收到 rect.maxY 之下。
      var low = 0
      var high = itemAttributes.count - 1
      while low < high {
        let mid = (low + high) / 2
        if itemAttributes[mid].frame.maxY <= rect.minY {
          low = mid + 1
        } else {
          high = mid
        }
      }
      var index = low
      while index < itemAttributes.count, itemAttributes[index].frame.minY < rect.maxY {
        result.append(itemAttributes[index])
        index += 1
      }
    }
    if let footerAttributes, footerAttributes.frame.intersects(rect) {
      result.append(footerAttributes)
    }
    return result
  }

  private var preparedIsEmpty: Bool { itemAttributes.isEmpty && headerAttributes == nil && footerAttributes == nil }

  /// `prefix` 是否逐位等于 `array` 的前缀（纯追加判据，同 TiebaRowPageDriver.isAppend 的用法）。
  private static func isPrefix(_ prefix: [CGFloat], of array: [CGFloat]) -> Bool {
    guard prefix.count <= array.count else { return false }
    for index in prefix.indices where prefix[index] != array[index] {
      return false
    }
    return true
  }
}
