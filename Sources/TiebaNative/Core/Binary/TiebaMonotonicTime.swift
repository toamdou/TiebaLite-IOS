// 移植自上游 submodules/MonotonicTime/Sources/DeviceUptime.m
//         （对应头文件 submodules/MonotonicTime/PublicHeaders/MonotonicTime/DeviceUptime.h）
//
// 改动清单（逐条，相对上游 ObjC）：
// 1. C 函数 getDeviceUptimeSeconds(int32_t *bootTime) → TiebaMonotonicTime 命名空间下的 Swift 属性/方法，
//    「返回值 + 出参」的 C 风格拆成两个语义清晰的属性。
// 2. KERN_BOOTTIME 在一次开机内是常量 → 按进程缓存（上游每次调用都重新 sysctl）。
// 3. bootTime 由 tv_sec 还原为带小数秒的时间戳（tv_sec + tv_usec/1e6），比上游只取 tv_sec 精确。
// 4. 新增 now：以「本次开机时刻」为锚的 Unix 时间戳。上游只有开机秒数，没法直接当时间戳用。
// 6. 并发：所有 API 都是 nonisolated 纯读取；进程内缓存用 TiebaMutex<State>（TiebaMutex shim：iOS 18 的 Synchronization.Mutex 在 iOS 17 不可用，见 Core/TiebaMutex.swift），
//    没有 nonisolated(unsafe) / @unchecked Sendable / assumeIsolated。
//
// 为什么不用 CACurrentMediaTime()：它从上次开机起算，设备一重启就归零，
// 前后两次采样做差会得到负数或离谱的值；「本次开机时刻 + 已开机秒数」重启后依然连续。

import Foundation

#if canImport(Darwin)
import Darwin
#endif

public enum TiebaMonotonicTime {
    /// KERN_BOOTTIME 在一次开机内恒定，缓存避免每次 sysctl；nil 表示取不到（极罕见）。
    private static let cachedBootTime = TiebaMutex<TimeInterval?>(nil)

    /// 本次开机的时刻（Unix 时间戳，秒）。
    public nonisolated static var bootTime: TimeInterval? {
        cachedBootTime.withLock { cached in
            if let cached {
                return cached
            }
            let value = readKernelBootTime()
            cached = value
            return value
        }
    }

    /// 以开机时刻为锚的 Unix 时间戳（秒）。
    /// 数值上约等于 Date().timeIntervalSince1970，但来源是 KERN_BOOTTIME + 开机秒数：
    /// 重启不会像 CACurrentMediaTime() 那样归零，两次采样做差才是正确的「停留时长」。
    public nonisolated static var now: TimeInterval {
        guard let bootTime = bootTime else {
            return Date().timeIntervalSince1970
        }
        return bootTime + (Date().timeIntervalSince1970 - bootTime)
    }

    /// 读 sysctl(CTL_KERN, KERN_BOOTTIME)。取不到或值非法返回 nil。
    private nonisolated static func readKernelBootTime() -> TimeInterval? {
        var bootTimeValue = timeval()
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        var size = MemoryLayout<timeval>.stride
        let result = sysctl(&mib, u_int(mib.count), &bootTimeValue, &size, nil, 0)
        // 上游同样把 boottime.tv_sec == 0 当作失败（内核偶发返回全 0）。
        guard result == 0, bootTimeValue.tv_sec != 0 else {
            return nil
        }
        return TimeInterval(bootTimeValue.tv_sec) + TimeInterval(bootTimeValue.tv_usec) / 1_000_000
    }
}

#if DEBUG
extension TiebaMonotonicTime {
    /// 自检：开机时刻必须落在过去、且不早于 2001 年（拿不到就跳过，不算失败）。
    public nonisolated static func debugSelfCheck() -> Bool {
        guard let bootTime else {
            return true
        }
        let wallClock = Date().timeIntervalSince1970
        assert(bootTime <= wallClock, "开机时刻不可能在未来")
        assert(bootTime > 978_307_200, "开机时刻早于 2001 年，说明 sysctl 取值有误")
        // 「开机时刻 + 已开机秒数」必须落在墙钟附近：这一步同时校验了 sysctl 取到的开机秒数没有畸形。
        let sampled = now
        assert(sampled >= bootTime, "以开机时刻为锚的时间戳不可能早于开机时刻")
        assert(abs(sampled - wallClock) < 1, "锚定时间戳与墙钟偏差超过 1 秒，说明开机秒数有误")
        assert(now >= sampled, "单调时钟不许回退")
        return true
    }
}
#endif
