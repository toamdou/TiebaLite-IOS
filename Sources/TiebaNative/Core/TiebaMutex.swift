import Foundation

/// 跨版本互斥量：本仓共享可变状态的**唯一**写法（等价于标准库 `Synchronization.Mutex<State>`）。
///
/// 为什么不用标准库 `Synchronization.Mutex`：
///   `Mutex`（以及同模块的 `Atomic`）是 **iOS 18+** 才有的 API，而 ios17 那条线的最低系统版本
///   必须保持 **17.0**（见 `.bazelrc` 的 `--ios_minimum_os=17.0` 与 `BUILD.bazel` 的
///   `minimum_os_version = "17.0"`）。同一个类型必须两边共用，否则以后每次 main ⇄ ios17
///   同步都会在这 12 个文件上反复冲突——所以 shim 放在 main、按 `Mutex` 的 API 形状对齐。
///
/// 为什么是 `@unchecked Sendable`（本仓唯一一处）：
///   `State` 的全部读写都必须经过 `withLock`，进入闭包前先拿 `NSLock`、出闭包才放锁，
///   所以同一时刻只有一个线程能碰到 `state`——跨线程共享是安全的。这一条编译器无法自己证明
///   （它看不到 `NSLock` 与 `state` 的绑定关系），故由人工声明 `@unchecked`；
///   除了这里，本仓不再新增任何 `@unchecked Sendable`。
///
/// 与标准库 `Mutex` 的差异（只放宽、不收紧，调用点无需改动）：
///   - `Mutex` 是值类型 + `borrowing`/`sending` 区域隔离；本类是引用类型，闭包参数少一层
///     `sending` 检查。语义同为「不可重入」（NSLock 与 Mutex 都不是递归锁）。
///   - 未实现 `withLockIfAvailable`：全仓无调用点，按「按实际调用点补齐成员」原则不预置。
final class TiebaMutex<State>: @unchecked Sendable {
  private let lock = NSLock()
  private var state: State

  init(_ initial: State) {
    self.state = initial
  }

  /// 独占执行 `body`：进入前加锁、返回（含抛错）后解锁。
  ///
  /// 与 `Mutex.withLock` 同形：`body` 拿到的是 `inout State`（原地改，不产生副本），
  /// 返回值/抛出原样透出，因此 `try connections.withLock { ... }` 这类调用点零改动。
  func withLock<R>(_ body: (inout State) throws -> R) rethrows -> R {
    lock.lock()
    defer { lock.unlock() }
    return try body(&state)
  }
}
