// The MIT License (MIT)
//
// Copyright (c) 2016 Luke Zhao <me@lkzhao.com>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#if canImport(QuartzCore)
import QuartzCore

public extension CAMediaTimingFunction {
  // TiebaLite patch (Swift 6): CAMediaTimingFunction 由控制点/名字构造后没有任何
  // setter，是不可变值对象、进程级共享常量；nonisolated(unsafe) 是对该事实的断言。
  // default
  nonisolated(unsafe) static let linear = CAMediaTimingFunction(name: CAMediaTimingFunctionName.linear)
  nonisolated(unsafe) static let easeIn = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeIn)
  nonisolated(unsafe) static let easeOut = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeOut)
  nonisolated(unsafe) static let easeInOut = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)

  // material
  nonisolated(unsafe) static let standard = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.2, 1.0)
  nonisolated(unsafe) static let deceleration = CAMediaTimingFunction(controlPoints: 0.0, 0.0, 0.2, 1)
  nonisolated(unsafe) static let acceleration = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 1, 1)
  nonisolated(unsafe) static let sharp = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.6, 1)

  // easing.net
  nonisolated(unsafe) static let easeOutBack = CAMediaTimingFunction(controlPoints: 0.175, 0.885, 0.32, 1.275)

  static func from(name: String) -> CAMediaTimingFunction? {
    switch name {
    case "linear":
      return .linear
    case "easeIn":
      return .easeIn
    case "easeOut":
      return .easeOut
    case "easeInOut":
      return .easeInOut
    case "standard":
      return .standard
    case "deceleration":
      return .deceleration
    case "acceleration":
      return .acceleration
    case "sharp":
      return .sharp
    default:
      return nil
    }
  }
}

#endif
