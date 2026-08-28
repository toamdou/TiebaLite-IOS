import ExpoModulesCore
import QuartzCore
import UIKit

public final class TiebaAudioWaveformView: ExpoView {
  private let shapeLayer = CAShapeLayer()

  var heights: [Double] = [] {
    didSet { setNeedsLayout() }
  }

  var isPlaying: Bool = false {
    didSet { updateColor() }
  }

  var color: UIColor = .systemBlue {
    didSet { updateColor() }
  }

  var inactiveColor: UIColor = .secondaryLabel {
    didSet { updateColor() }
  }

  var barWidth: Double = 2 {
    didSet { setNeedsLayout() }
  }

  var gap: Double = 2 {
    didSet { setNeedsLayout() }
  }

  public required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    shapeLayer.fillColor = nil
    shapeLayer.lineCap = .round
    layer.addSublayer(shapeLayer)
    updateColor()
  }

  public override func layoutSubviews() {
    super.layoutSubviews()
    shapeLayer.frame = bounds
    updatePath()
  }

  private func updatePath() {
    let path = UIBezierPath()
    guard !heights.isEmpty, bounds.width > 0, bounds.height > 0 else {
      shapeLayer.path = nil
      return
    }

    let width = CGFloat(barWidth)
    let spacing = CGFloat(gap)
    let totalWidth = CGFloat(heights.count) * width + CGFloat(max(heights.count - 1, 0)) * spacing
    let startX = max(0, (bounds.width - totalWidth) / 2)
    let midY = bounds.midY

    for (index, raw) in heights.enumerated() {
      let barHeight = min(max(CGFloat(raw), 0), bounds.height)
      let x = startX + CGFloat(index) * (width + spacing)
      let y = midY - barHeight / 2
      path.move(to: CGPoint(x: x + width / 2, y: y))
      path.addLine(to: CGPoint(x: x + width / 2, y: y + barHeight))
    }

    shapeLayer.path = path.cgPath
    shapeLayer.lineWidth = width
  }

  private func updateColor() {
    shapeLayer.strokeColor = (isPlaying ? color : inactiveColor).cgColor
  }
}
