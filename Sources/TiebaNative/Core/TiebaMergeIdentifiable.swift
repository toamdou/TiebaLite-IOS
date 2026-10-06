// TiebaMergeIdentifiable —— 可合并列表元素的稳定标识协议。
//
// 移植自上游 submodules/MergeLists/Sources/Identifiable.swift。
// 本仓位置：早期住在 早期 vendor 目录（该目录已解散），现在直接放在 Core/ 下。
// 本仓改动：协议改名 Identifiable → TiebaMergeIdentifiable —— 与 Swift 标准库
//        的 Identifiable（associatedtype ID）同名会在本模块内造成歧义。
//        另：本模块不需要 public，但保留以减少 diff。

public protocol TiebaMergeIdentifiable {
    associatedtype T: Hashable
    var stableId: T { get }
}
