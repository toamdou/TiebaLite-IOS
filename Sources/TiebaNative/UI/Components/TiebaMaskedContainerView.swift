// 反相挖洞遮罩：一张位图 mask 里「先填满、再用 copy 混合模式把几个形状擦成透明洞」。
//
// 移植自上游 submodules/MaskedContainerComponent/Sources/MaskedContainerComponent.swift:52-92
//（:61-63 空数组时摘掉 mask、:69-75 反相分支、:77-85 椭圆/圆角矩形、:91 挂 mask）。
//
// 为什么不是「每个形状挂一条 CAShapeLayer 当 mask」：layer.mask 只能挂一条 path，
// 多个不连续区域（页内查找的多个命中、教程聚光灯）没法一次表达；用 even-odd 填充规则
// 又很难把圆角矩形和椭圆混在同一条 path 里。**一张位图一次画完**是唯一简单的正解。
import UIKit

/// 高亮/压暗非连续区域的容器。挂在宿主视图上、frame 铺满即可用。
final class TiebaMaskedContainerView: UIView {
  struct Item: Equatable {
    enum Shape: Equatable {
      case ellipse
      case roundedRect(cornerRadius: CGFloat)
    }

    var frame: CGRect
    var shape: Shape
  }

  /// 内容视图（调用方持有；本视图只负责摆它 + 挂 mask）。
  let contentView = UIView()
  private let contentMaskView = UIImageView()

  private struct Params: Equatable {
    let size: CGSize
    let items: [Item]
    let isInverted: Bool
  }
  private var params: Params?

  override init(frame: CGRect) {
    super.init(frame: frame)
    addSubview(contentView)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  /// isInverted = true：整张铺满、形状处挖洞（压暗其余、高亮命中）。
  /// isInverted = false：只有形状处不透明（当普通形状遮罩用）。
  func update(size: CGSize, items: [Item], isInverted: Bool) {
    let params = Params(size: size, items: items, isInverted: isInverted)
    guard params != self.params else { return }
    self.params = params
    contentView.frame = CGRect(origin: .zero, size: size)
    contentMaskView.frame = CGRect(origin: .zero, size: size)

    // A7（报告 37）：形状降级回"简单路径"时**主动把 mask 卸掉**（上游 ClippingShapeContext.swift:419-422）。
    // 判据：非反相 + 恰好一个圆角矩形 + 它铺满整个尺寸 = 一次普通的圆角裁剪，
    // 用 layer.cornerRadius 表达即可 —— 位图 mask 会让这个视图**永久背着一次离屏合成**
    // （形状动过一次之后即使回到普通圆角也一直掉帧，报告 37 A7②）。半径过 A6 的等比钳制。
    if !isInverted, items.count == 1, case let .roundedRect(cornerRadius) = items[0].shape,
      items[0].frame.contains(CGRect(origin: .zero, size: size))
    {
      contentMaskView.image = nil
      contentView.mask = nil
      contentView.layer.masksToBounds = true
      contentView.layer.cornerRadius = TiebaRoundedRectGeometry.clampedCornerRadii(
        size: size,
        cornerRadii: TiebaCornerRadii(radius: cornerRadius)
      ).maximum
      return
    }
    // 需要真 mask 的分支：把上一条降级留下的圆角/裁剪还回去，形状交给 mask 表达。
    contentView.layer.masksToBounds = false
    contentView.layer.cornerRadius = 0

    guard !items.isEmpty else {
      contentMaskView.image = nil
      contentView.mask = nil
      return
    }
    let renderer = UIGraphicsImageRenderer(bounds: CGRect(origin: .zero, size: size))
    contentMaskView.image = renderer.image { context in
      let cgContext = context.cgContext
      if isInverted {
        cgContext.setFillColor(UIColor.black.cgColor)
        cgContext.fill(CGRect(origin: .zero, size: size))
        // copy：后面的填充是「替换」而不是「叠加」⇒ clear 才能真的擦出透明洞。
        cgContext.setFillColor(UIColor.clear.cgColor)
        cgContext.setBlendMode(.copy)
      } else {
        cgContext.setFillColor(UIColor.black.cgColor)
      }
      for item in items {
        switch item.shape {
        case .ellipse:
          cgContext.fillEllipse(in: item.frame)
        case let .roundedRect(cornerRadius):
          // A6/A7：半径统一过等比钳制，半径 ≤ 0 的角走两段直线（不留第二套圆角路径）。
          cgContext.addPath(
            TiebaRoundedRectGeometry.path(
              rect: item.frame,
              cornerRadii: TiebaCornerRadii(radius: cornerRadius)
            )
          )
          cgContext.fillPath()
        }
      }
    }
    contentView.mask = contentMaskView
  }
}
