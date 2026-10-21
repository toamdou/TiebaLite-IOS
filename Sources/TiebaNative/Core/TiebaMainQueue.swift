// 主线程跳板：全仓唯一一份。
//
// 历史：原先它是 TiebaNavBarChrome.swift 里的一个裸函数（闭包不带隔离），
// TiebaPhotoBrowser 另有一份私有副本；两处都已并入这里。
import Foundation

/// 主线程执行（已在主线程则就地同步执行）。
///
/// `@MainActor` 是这条跳板的要点：闭包体进入主线程域，UIKit / chrome 状态可以
/// 直接读写，不必在闭包内再手写 `MainActor.assumeIsolated`（那是闭包被推断成
/// 非隔离时的补救）。`@Sendable` 约束捕获面——闭包里不要塞可变的非 Sendable
/// 状态；需要 `self` 时显式写 `[weak self]` 并在闭包内取值。
///
/// ⚠️ 按裸名 `onMain` 搜索引用，不要写成 `\.onMain(`——曾因此被误判为死代码删除。
func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
  if Thread.isMainThread {
    // 已在主线程：就地同步执行。调用方要的是同步语义（例如"首帧即深色"），
    // 多派一拍主队列会把写入推后一帧。
    MainActor.assumeIsolated { work() }
  } else {
    // 派到主队列：DispatchQueue.main 保证在**主线程**执行，assumeIsolated 的
    // 前提（当前就在主线程）因此成立。
    DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
  }
}
