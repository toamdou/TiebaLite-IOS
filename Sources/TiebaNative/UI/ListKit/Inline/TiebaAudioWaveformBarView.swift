// 从 TiebaPostRowInline.swift 拆出（按类型分文件，纯搬运、整类型逐字搬走）。

import UIKit

/// 15 根柱（原 AudioSegment.tsx 的 AUDIO_WAVEFORM_BARS 同值），按进度着色。
/// 渲染算法移植自上游 submodules/AudioWaveformNode/Sources/AudioWaveformNode.swift:121-232。
final class TiebaAudioWaveformBarView: UIView {
  /// 兜底波形：没有样本、或样本是坏数据时画它，而不是留空。上游 :162-170 生成**随机**
  /// 假样本；本仓改用固定 15 根手工柱，保证同一个波形宽度下观感稳定（也正是原有外观）。
  static let fallbackHeights: [CGFloat] = [12, 18, 8, 22, 14, 20, 10, 24, 16, 6, 19, 13, 21, 9, 17]

  var activeColor: UIColor = .systemBlue { didSet { setNeedsDisplay() } }
  var inactiveColor: UIColor = .secondaryLabel { didSet { setNeedsDisplay() } }
  var progress: Double = 0 { didSet { setNeedsDisplay() } }
  override init(frame: CGRect) {
    super.init(frame: frame)
    isOpaque = false
    backgroundColor = .clear
    // 保持不吃触摸：拖动定位的手势挂在**整个语音条**上（见 TiebaAudioPillView），
    // 波形这一段一旦 interactive，铺满的 actionButton 就收不到点击/长按了。
    isUserInteractionEnabled = false
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  /// 每根柱的高度：本仓恒用兜底表。
  /// 为什么没有"真实样本"这条路径（算法审查 §4 点名的 samples 从未赋值）：
  /// 贴吧接口只给语音的 src + duration，**没有波形字段**；唯一真实数据源是音频字节本身，
  /// 要 `AVAssetReader` 全量解码 —— 列表里每一行语音都解一遍 = 滚动掉帧。
  /// 按「不许造假数据」的要求，这里删掉了 samples/bucketPeaks/isDegenerate 那条从未被喂过数据的分支，
  /// 只保留固定 15 根柱（= 本仓一直以来的外观）。将来若接口下发波形，再从本注释处接回。
  private func resolvedHeights() -> [CGFloat] {
    Self.fallbackHeights
  }

  override func draw(_ rect: CGRect) {
    guard bounds.width > 0 else { return }
    let heights = resolvedHeights()
    let count = heights.count
    let gap: CGFloat = 2
    let barWidth = max((bounds.width - gap * CGFloat(count - 1)) / CGFloat(count), 1)
    let shown = Int((Double(count) * progress).rounded(.up))
    for (index, height) in heights.enumerated() {
      let x = CGFloat(index) * (barWidth + gap)
      let y = (bounds.height - height) / 2
      let color = index < shown ? activeColor : inactiveColor
      color.setFill()
      // 圆头柱 = 一个矩形 + 上下各一个圆（移植自上游 :211-225）：比
      // UIBezierPath(roundedRect:) 便宜得多，像素结果一样（圆角半径 = 半宽）。
      let radius = barWidth / 2
      let barHeight = max(height, barWidth)
      UIBezierPath(rect: CGRect(x: x, y: y + radius, width: barWidth, height: barHeight - barWidth)).fill()
      for centerY in [y + radius, y + barHeight - radius] {
        UIBezierPath(ovalIn: CGRect(x: x, y: centerY - radius, width: barWidth, height: barWidth)).fill()
      }
    }
  }
}
