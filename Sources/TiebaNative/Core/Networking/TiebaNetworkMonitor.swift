// 轻量网络类型快照：给 API / 图片会话提供自适应超时与网络服务类型决策。
//
// 注意：这里刻意不把 NWPathMonitor 暴露给每个请求。全进程只有一个 monitor +
// 一个受锁保护的快照；请求路径只做一次同步内存读，不创建 monitor、不注册回调。
import Foundation
import Network

struct TiebaNetworkSnapshot: Sendable {
  enum Interface: Sendable {
    case wifi
    case cellular
    case wiredEthernet
    case other
    case unknown
  }

  let isConnected: Bool
  let isExpensive: Bool
  let isConstrained: Bool
  let interface: Interface

  /// 首个 path 回调到达前采用乐观默认值：不确定时不要主动缩短/延长超时。
  static let initial = TiebaNetworkSnapshot(
    isConnected: true,
    isExpensive: false,
    isConstrained: false,
    interface: .unknown
  )
}

final class TiebaNetworkMonitor: @unchecked Sendable {
  static let shared = TiebaNetworkMonitor()

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "com.tiebalite.network-monitor", qos: .utility)
  private let state = TiebaMutex<TiebaNetworkSnapshot>(.initial)

  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let interface: TiebaNetworkSnapshot.Interface
      if path.usesInterfaceType(.wifi) {
        interface = .wifi
      } else if path.usesInterfaceType(.cellular) {
        interface = .cellular
      } else if path.usesInterfaceType(.wiredEthernet) {
        interface = .wiredEthernet
      } else if path.usesInterfaceType(.other) {
        interface = .other
      } else {
        interface = .unknown
      }
      self.state.withLock {
        $0 = TiebaNetworkSnapshot(
          isConnected: path.status == .satisfied,
          isExpensive: path.isExpensive,
          isConstrained: path.isConstrained,
          interface: interface
        )
      }
    }
    monitor.start(queue: queue)
  }

  deinit {
    monitor.cancel()
  }

  func snapshot() -> TiebaNetworkSnapshot {
    state.withLock { $0 }
  }

  /// 按当前链路质量调整单个 URLRequest 的超时。
  /// 已断网时把基础超时抬到至少 30s。
  /// 蜂窝或热点流量（expensive）x1.25，低数据模式（constrained）再 x1.5。
  func adjustedTimeout(base: TimeInterval, maximum: TimeInterval) -> TimeInterval {
    let snapshot = snapshot()
    var timeout = max(base, 1)
    if snapshot.isConnected == false {
      timeout = max(timeout, 30)
    }
    if snapshot.isExpensive {
      timeout *= 1.25
    }
    if snapshot.isConstrained {
      timeout *= 1.5
    }
    return min(timeout, max(maximum, 1))
  }
}
