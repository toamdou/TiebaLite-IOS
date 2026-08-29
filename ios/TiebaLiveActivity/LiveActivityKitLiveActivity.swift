//
//  LiveActivityKitLiveActivity.swift
//  TiebaLite sign progress Live Activity
//
//  Custom SwiftUI template copied into the generated widget extension by
//  plugins/withTiebaLiveActivity.js. It renders a polished lock-screen card
//  plus Dynamic Island compact / minimal / expanded states.
//

import ActivityKit
import CoreGraphics
import Foundation
import SwiftUI
import WidgetKit

@available(iOS 16.1, *)
struct LiveActivityKitLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: LiveActivityKitAttributes.self) { context in
      TiebaLiveActivityLockScreenView(state: context.state)
        .activityBackgroundTint(Color.black.opacity(0.35))
        .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      let state = context.state
      let tint = LiveActivityKitTheme.color(state.tintColorHex) ?? .blue
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          // 系统把展开态裁剪成摄像头轮廓（大圆角、连续曲线、不可改），
          // 内容若贴边会被四角裁掉——统一内缩让内容离开角区（2026-08-29）。
          HStack(spacing: 8) {
            LiveActivityKitTheme.symbol(state.imageName, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
              Text(state.title)
                .font(.headline)
                .lineLimit(1)
              Text(LiveActivityKitTheme.statusLine(state))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
          }
          .padding(.horizontal, 4)
        }

        DynamicIslandExpandedRegion(.center) {
          VStack(spacing: 3) {
            Text(state.status ?? "0/0")
              .font(.headline)
              .monospacedDigit()
              .foregroundStyle(tint)
            if let progress = state.progress {
              ProgressView(value: LiveActivityKitTheme.clamp(progress))
                .progressViewStyle(.linear)
                .frame(width: 56)
                .tint(tint)
            }
          }
        }

        DynamicIslandExpandedRegion(.trailing) {
          VStack(alignment: .trailing, spacing: 3) {
            if let date = state.date {
              Text(LiveActivityKitTheme.relativeDate(date), style: .timer)
                .font(.headline)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
            }
            if let extra = state.extra {
              HStack(spacing: 5) {
                Text("✓ \(extra["success"] ?? "0")")
                  .foregroundStyle(.green)
                Text("✗ \(extra["fail"] ?? "0")")
                  .foregroundStyle(.red)
              }
              .font(.caption2)
              .monospacedDigit()
            }
          }
          .padding(.horizontal, 4)
        }

        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 4) {
            if let progress = state.progress {
              ProgressView(value: LiveActivityKitTheme.clamp(progress))
                .tint(tint)
            }
            HStack(spacing: 10) {
              if let body = state.body {
                Text(body)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Spacer(minLength: 8)
              if let progress = state.progress {
                Text("\(Int(LiveActivityKitTheme.clamp(progress) * 100))%")
                  .font(.caption2)
                  .bold()
                  .monospacedDigit()
                  .foregroundStyle(tint)
              }
            }
          }
          // 底部区横跨全宽，左右两端正好落在系统圆角裁剪区——内缩最关键
          .padding(.horizontal, 12)
        }
      } compactLeading: {
        HStack(spacing: 5) {
          // 左 = App 图标（液态玻璃圆角小图）；摄像头右侧 = 圆环进度（compactTrailing）
          LiveActivityKitTheme.appIcon(size: 18)
          Text(state.status ?? "签到")
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.primary)
            .lineLimit(1)
        }
      } compactTrailing: {
        if let progress = state.progress {
          ProgressView(value: LiveActivityKitTheme.clamp(progress))
            .progressViewStyle(.circular)
            .tint(tint)
        } else if let status = state.status {
          Text(status)
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
      } minimal: {
        if let progress = state.progress {
          ProgressView(value: LiveActivityKitTheme.clamp(progress))
            .progressViewStyle(.circular)
            .tint(tint)
        } else if let symbol = state.imageName {
          Image(systemName: symbol)
            .foregroundStyle(tint)
        } else {
          Text(String(state.title.prefix(1)))
            .font(.caption)
            .foregroundStyle(tint)
        }
      }
      .keylineTint(tint)
    }
  }
}

@available(iOS 16.1, *)
private struct TiebaLiveActivityLockScreenView: View {
  let state: LiveActivityKitAttributes.ContentState

  var body: some View {
    let tint = LiveActivityKitTheme.color(state.tintColorHex) ?? .blue
    let progress = state.progress.map { LiveActivityKitTheme.clamp($0) }

    HStack(alignment: .center, spacing: 12) {
      // 锁屏卡片左侧 = App 图标（与灵动岛紧凑态左图标一致）
      LiveActivityKitTheme.appIcon(size: 34)
        .frame(width: 38)

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 8) {
          Text(state.title)
            .font(.headline)
            .lineLimit(1)
          if let status = state.status {
            Text(status)
              .font(.caption)
              .bold()
              .monospacedDigit()
              .padding(.horizontal, 8)
              .padding(.vertical, 3)
              .background(tint.opacity(0.18), in: Capsule())
              .foregroundStyle(tint)
          }
        }

        Text(LiveActivityKitTheme.statusLine(state))
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(1)

        if let progress {
          ProgressView(value: progress)
            .tint(tint)
        }

        HStack(alignment: .firstTextBaseline, spacing: 10) {
          if let body = state.body {
            Text(body)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer(minLength: 8)
          if let date = state.date {
            Text(LiveActivityKitTheme.relativeDate(date), style: .timer)
              .font(.caption)
              .monospacedDigit()
              .foregroundStyle(tint)
          }
        }
      }
    }
    .padding(16)
  }
}

enum LiveActivityKitTheme {
  /// App 图标（widget bundle 内嵌 AppIcon.png 资源；缺失时回退 SF Symbol）。
  /// 灵动岛紧凑态左侧 + 锁屏卡片左侧共用，与主屏图标视觉一致。
  @ViewBuilder
  static func appIcon(size: CGFloat) -> some View {
    if let image = UIImage(named: "AppIcon") {
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    } else {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: size, weight: .semibold))
        .foregroundStyle(.blue)
        .frame(width: size, height: size)
    }
  }

  @ViewBuilder
  static func symbol(
    _ name: String?,
    tint: Color,
    pointSize: CGFloat = 16
  ) -> some View {
    let resolved = (name?.isEmpty == false ? name : "checkmark.circle.fill") ?? "checkmark.circle.fill"
    Image(systemName: resolved)
      .font(.system(size: pointSize, weight: .semibold))
      .foregroundStyle(tint)
      .frame(width: pointSize + 8, height: pointSize + 8)
  }

  static func color(_ hex: String?) -> Color? {
    guard var raw = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    if raw.hasPrefix("#") { raw.removeFirst() }
    guard let value = UInt64(raw, radix: 16) else { return nil }
    let r, g, b, a: Double
    switch raw.count {
    case 6:
      r = Double((value & 0xFF0000) >> 16) / 255
      g = Double((value & 0x00FF00) >> 8) / 255
      b = Double(value & 0x0000FF) / 255
      a = 1
    case 8:
      a = Double((value & 0xFF00_0000) >> 24) / 255
      r = Double((value & 0x00FF_0000) >> 16) / 255
      g = Double((value & 0x0000_FF00) >> 8) / 255
      b = Double(value & 0x0000_00FF) / 255
    default:
      return nil
    }
    return Color(.sRGB, red: r, green: g, blue: b, opacity: a)
  }

  static func clamp(_ value: Double) -> Double {
    min(max(value, 0), 1)
  }

  static func relativeDate(_ epochMs: Double) -> Date {
    Date(timeIntervalSince1970: epochMs / 1000)
  }

  static func forumText(_ forum: String?) -> String {
    guard let forum, !forum.isEmpty else { return "正在签到" }
    return "正在签到 \(forum)吧"
  }

  static func statusLine(_ state: LiveActivityKitAttributes.ContentState) -> String {
    if let subtitle = state.subtitle, !subtitle.isEmpty {
      return subtitle
    }
    return forumText(state.currentForum)
  }
}
