// TiebaPersistentStringHash —— 跨进程稳定的字符串哈希（行内容指纹的基石）。
//
// 移植自上游 submodules/PersistentStringHash/Sources/StringHash.swift。
// 本仓位置：早期住在 早期 vendor 目录（该目录已解散），现在直接放在 Core/ 下。
// 本仓改动：仅此头注，正文逐行未改。
import Foundation

public extension String {
    var persistentHashValue: UInt64 {
        var result = UInt64 (5381)
        let buf = [UInt8](self.utf8)
        for b in buf {
            result = 127 * (result & 0x00ffffffffffffff) + UInt64(b)
        }
        return result
    }
}
