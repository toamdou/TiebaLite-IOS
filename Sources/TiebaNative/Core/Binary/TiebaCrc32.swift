// 移植自上游 submodules/Crc32/Sources/Crc32.m
//         （对应头文件 PublicHeaders/Crc32/Crc32.h）
//
// 改动清单（逐条，相对上游 ObjC/C）：
// 1. C 函数 Crc32(const void *, int) → TiebaCrc32 命名空间下的静态方法，并补齐 Data / String 入口。
// 2. 仍然走 zlib 的 crc32()：CRC-32/ISO-HDLC（多项式 0xEDB88320，反射，初值/终值异或 0xFFFFFFFF）。
//    上游只有「一次性」用法，这里保持同样的算法与结果，不自己实现查表（省 1KB 常驻表也更不容易写错）。
// 3. 长度用 uInt 传递（zlib 的 uInt 是 32 位）；超过 4GB 的单次输入在 zlib 层就不可能，直接按上游语义截断。
// 4. 并发：nonisolated 纯函数。
// 5. 新增 #if DEBUG 自检：CRC32("123456789") == 0xCBF43926。

import Foundation
import zlib

public enum TiebaCrc32 {
    /// 一次性 CRC32。空输入返回 0（zlib 初值即 0）。
    public nonisolated static func checksum(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
        guard let base = bytes.baseAddress, !bytes.isEmpty else {
            return 0
        }
        let result = crc32(crc32(0, nil, 0), base.assumingMemoryBound(to: Bytef.self), uInt(bytes.count))
        return UInt32(truncatingIfNeeded: result)
    }

    public nonisolated static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { checksum($0) }
    }

    public nonisolated static func checksum(_ string: String) -> UInt32 {
        let utf8 = Array(string.utf8)
        return utf8.withUnsafeBytes { checksum($0) }
    }
}

#if DEBUG
extension TiebaCrc32 {
    public nonisolated static func debugSelfCheck() -> Bool {
        assert(checksum("") == 0, "空输入 CRC32 应为 0")
        assert(checksum("123456789") == 0xCBF4_3926, "CRC32(\"123456789\") 标准检验值")
        assert(checksum("The quick brown fox jumps over the lazy dog") == 0x414F_A339, "CRC32 常见检验值")
        return true
    }
}
#endif
