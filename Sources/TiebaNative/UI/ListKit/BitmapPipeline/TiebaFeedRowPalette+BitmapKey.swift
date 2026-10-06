// ============================================================
// TiebaLite — 异步位图管线 · 色板指纹（R1 的落地，接入第一件事）
//
// ⚠️ 本文件是 BitmapPipeline/ 里**唯一**引用 TiebaNative 其他类型的文件
//（TiebaFeedRowPalette，TiebaRowMetrics.swift:1253）。其余 5 个文件只吃传入的
// 值类型，可独立 typecheck（见交付说明）。
//
// 为什么需要它（报告 §6 R1，接入前必读）：
//   TiebaFeedRowPalette 是 Equatable **不是 Hashable**（:1253），旧缓存查找是
//   逐字段比对（TiebaFeedRowView.swift:869-880 的 entries[index].palette == palette），
//   所以一直没暴露。而新的位图缓存键 TiebaFeedBitmapKey 必须在 Set / Dictionary 里用。
//
//   把 UIColor 直接塞进 Hasher 是**错的**：UIColor.hash 对动态色（.label /
//   .secondaryLabel / .secondarySystemFill / UIColor { traits in ... }）只反映
//   「这是个动态色」这一身份 —— 浅色与深色两档会撞成同一个 hash，于是深色模式下
//   命中浅色位图（行文字保持黑色）。必须先 resolvedColor(with:) 再混**分量**。
//
// 顺带订正一处旧行为：指纹按传入的外观档解析，所以「同一色板 + 换深浅档」也是不同键
//（键里另有 styleRaw，双保险）。
// ============================================================

import UIKit

extension TiebaFeedRowPalette {
  /// 位图缓存键用的色板指纹。
  ///
  /// - Parameter traits: 解析动态色用的外观档。**必须传被烘位图那一次渲染真正会用的档**
  ///   （画布传自己的 traitCollection）—— 后台线程的 UITraitCollection.current 是默认档，
  ///   用它算指纹会与渲染期的解析结果不一致。
  public func bitmapFingerprint(in traits: UITraitCollection) -> Int {
    var hasher = Hasher()
    // 顺序固定：字段一变（增删色）指纹即变，不会出现「新色板撞上旧色板」。
    Self.mix(card, into: &hasher, traits: traits)
    Self.mix(borderCard, into: &hasher, traits: traits)
    Self.mix(text, into: &hasher, traits: traits)
    Self.mix(textSecondary, into: &hasher, traits: traits)
    Self.mix(textTertiary, into: &hasher, traits: traits)
    Self.mix(primary, into: &hasher, traits: traits)
    Self.mix(chip, into: &hasher, traits: traits)
    Self.mix(onChip, into: &hasher, traits: traits)
    Self.mix(separator, into: &hasher, traits: traits)
    Self.mix(liked, into: &hasher, traits: traits)
    Self.mix(warning, into: &hasher, traits: traits)
    Self.mix(placeholder, into: &hasher, traits: traits)
    Self.mix(avatarFallback, into: &hasher, traits: traits)
    hasher.combine(isNight)
    return hasher.finalize()
  }

  /// 便利入口：当前线程的外观档。
  /// 只在**主线程**调用才正确（后台线程的 UITraitCollection.current 是默认档）。
  public var paletteFingerprint: Int {
    bitmapFingerprint(in: .current)
  }

  private static func mix(_ color: UIColor, into hasher: inout Hasher, traits: UITraitCollection) {
    let resolved = color.resolvedColor(with: traits)
    // 色彩空间也进指纹：P3 与 sRGB 下同样的分量是不同的像素。
    hasher.combine(resolved.cgColor.colorSpace?.name as String?)
    if let components = resolved.cgColor.components {
      hasher.combine(components.count)
      for component in components { hasher.combine(component) }
    } else {
      // 图案色等没有分量：退化为 alpha（本仓库的语义色不会走到这里，防御性分支）。
      hasher.combine(resolved.cgColor.alpha)
    }
    hasher.combine(resolved.cgColor.alpha)
  }
}
