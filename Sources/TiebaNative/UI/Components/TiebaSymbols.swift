// SF Symbol 渲染缓存（行内图标用）。
//
// 为什么要有它：`UIImage(systemName:withConfiguration:)` 每次都会走 CoreGlyphs 组装
// 一张新图（名字+配置的内部查找与拷贝）。列表滚动时每行要配 3–5 个图标
//（操作栏三个、chevron、类型图标…），几个新 cell 一屏进来就是十几次调用，正好压在
// 16.6ms/8.3ms 的帧预算里。名字与（尺寸, 粗细）组合是**有限枚举**，缓存即可。
//
// 线程纪律：只允许主线程访问（行视图与列表都在主线程构造/配置）；@MainActor 让编译器
// 守住这条不变量，不引锁。
import UIKit

@MainActor
enum TiebaSymbols {
  private static var cache: [String: UIImage] = [:]

  /// 取（或渲染并缓存）一个 SF Symbol。名字或配置非法 → nil（调用方按缺图处理）。
  /// 粗细用符号自己的 `UIImage.SymbolWeight`（与 `UIImage.SymbolConfiguration` 同口径，
  /// 不要在这里收 UIFont.Weight —— 两者是不同的枚举，传错即编译不过）。
  static func image(
    _ name: String,
    pointSize: CGFloat,
    weight: UIImage.SymbolWeight
  ) -> UIImage? {
    guard !name.isEmpty else { return nil }
    let size = max(pointSize, 1)
    let key = "\(name)#\(size)#\(weight.rawValue)"
    if let cached = cache[key] { return cached }
    let image = UIImage(
      systemName: name,
      withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: weight)
    )
    cache[key] = image
    return image
  }
}
