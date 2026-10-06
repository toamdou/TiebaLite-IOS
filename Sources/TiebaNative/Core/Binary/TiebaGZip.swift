// 移植自上游 submodules/GZip/Sources/GZip.m
//         （对应头文件 Sources/GZip.h：TGGZipData / TGGUnzipData / TGIsGzippedData）
//
// 【判据③复核（系统原生更优 → 不搬）——结论：保留，不动】
//   本文件的两处消费方（TiebaKvStore 的大值、TiebaBackgroundSnapshot 的 payload）目前都是**自有格式**，
//   单看这两处，Foundation 的 NSData.compressed(using: .zlib) 确实更简短。但本文件真正的价值是
//   **能读写标准 gzip 容器（RFC1952）**：与外部 gzip 流互通、以及读回旧版本写下的 gzip 数据都靠它。
//   这属于判据③明确列出的「系统有但不适用」例外（NSData.compressed 没有 gzip 容器）→ 保留。
//
// ⚠️ 任务里问的「Foundation 的 NSData.compressed(using:) 是否已覆盖」——答案是没有：
//   Foundation 的压缩 API 只有 .zlib(RFC1950) / .lzfse / .lz4 / .lzma 几种容器，**没有 gzip(RFC1952)**；
//   而上游 TGGZipData 产出的是带 gzip 头的流（deflateInit2 的 windowBits = 31），上游 服务端只认这个。
//   所以不能删掉 zlib 实现，全量保留；解压端仍用 windowBits = 47（自动识别 gzip 与 zlib 两种头），
//   顺带就能吃下 NSData.compressed(using: .zlib) 的产物。
//
// 改动清单（逐条，相对上游 ObjC/C）：
// 1. 三个 C 函数 → TiebaGZip 命名空间的静态方法：isGzipped / compress / decompress。
// 2. 输出缓冲区所有权显式化：上游用 NSMutableData 边压边扩容，Swift 这里用
//    UnsafeMutableRawPointer.allocate + defer deallocate（谁分配谁释放，所有 return 路径都不漏），
//    最后才拷进 Data 返回——避免在 withUnsafeMutableBytes 闭包里扩容 Data（会让指针失效）。
// 3. 压缩输出按 deflateBound() 一次性分配（zlib 保证的上界），不会再走「边压边 resize」那条路。
// 4. 上游 TGGUnzipData 在「超出 sizeLimit」时直接 return nil，漏了 inflateEnd（内存泄漏）；
//    这里用 defer inflateEnd 保证释放。
// 5. 上游解压的 sizeLimit 判断在写之前、且用 > 比较，边界含糊；这里改成「已产出字节数超过 sizeLimit 立即失败」。
// 6. 末尾把 stream.next_in / next_out 置空再离开作用域，避免留下指向已失效缓冲区的悬垂指针。
// 7. 并发：nonisolated 纯函数（无共享状态，z_stream 是栈上的局部变量）。
// 8. 新增 #if DEBUG 自检：压缩→解压回环、isGzipped 判定、非法输入。

import Foundation
import zlib

public enum TiebaGZip {
    /// 上游 TGIsGzippedData：gzip 头(1f 8b) 或 zlib 头(78 9c)。
    public nonisolated static func isGzipped(_ data: Data) -> Bool {
        data.withUnsafeBytes { bytes -> Bool in
            guard bytes.count >= 2, let base = bytes.baseAddress else {
                return false
            }
            let first = base.load(as: UInt8.self)
            let second = base.load(fromByteOffset: 1, as: UInt8.self)
            return (first == 0x1f && second == 0x8b) || (first == 0x78 && second == 0x9c)
        }
    }

    /// gzip 压缩（windowBits = 31 → 带 gzip 头）。
    /// - level: 0...1 的比例（上游语义：level * 9 取整）；负数用 zlib 默认级别。
    /// - 空数据或已经是压缩数据时按上游语义原样返回。
    public nonisolated static func compress(_ data: Data, level: Float = -1) -> Data? {
        guard !data.isEmpty, !isGzipped(data) else {
            return data
        }

        let compressionLevel: Int32 = level < 0 ? Z_DEFAULT_COMPRESSION : Int32(max(0, min(9, (level * 9).rounded())))

        var stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil
        let initResult = deflateInit2_(
            &stream, compressionLevel, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard initResult == Z_OK else {
            return nil
        }
        defer { deflateEnd(&stream) }

        // deflateBound 给出「压缩后不会超过」的上界，再加 64 字节余量（含 gzip 头/尾）。
        let capacity = max(Int(deflateBound(&stream, uLong(data.count))) + 64, 128)
        let outputBuffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        defer { outputBuffer.deallocate() }

        let status: Int32 = data.withUnsafeBytes { input -> Int32 in
            stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress!.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(input.count)
            stream.next_out = outputBuffer.assumingMemoryBound(to: Bytef.self)
            stream.avail_out = uInt(capacity)

            var result: Int32 = Z_OK
            // Z_FINISH：一直压到流结束。deflateBound 保证一次就够，循环只是把 zlib 的
            // 「输出没写完」这种情况也兜住。
            while result == Z_OK, stream.avail_out > 0 {
                result = deflate(&stream, Z_FINISH)
            }
            return result
        }
        let produced = Int(stream.total_out)
        guard status == Z_STREAM_END else {
            return nil
        }
        return Data(bytes: outputBuffer, count: produced)
    }

    /// gzip/zlib 解压（windowBits = 47 → 自动识别两种头）。
    /// - sizeLimit: > 0 时，解压结果一旦超过该字节数就返回 nil（防压缩炸弹）。
    /// - 空数据或非压缩数据返回 nil（上游语义）。
    public nonisolated static func decompress(_ data: Data, sizeLimit: Int = 0) -> Data? {
        guard !data.isEmpty, isGzipped(data) else {
            return nil
        }

        var stream = z_stream()
        stream.zalloc = nil
        stream.zfree = nil
        stream.opaque = nil
        let initResult = inflateInit2_(&stream, 47, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard initResult == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }

        // 输出长度未知：从 4 倍输入起步，写满就翻倍（上游是按 data.length/2 递增，行为等价）。
        var capacity = max(data.count * 4, 16 * 1024)
        var outputBuffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 1)
        defer { outputBuffer.deallocate() }

        var failure = false
        let status: Int32 = data.withUnsafeBytes { input -> Int32 in
            stream.next_in = UnsafeMutablePointer(mutating: input.baseAddress!.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(input.count)

            var result: Int32 = Z_OK
            while true {
                if Int(stream.total_out) == capacity {
                    // 写满了：扩容后把已有内容搬过去，再继续
                    let grown = capacity * 2
                    if sizeLimit > 0, grown > sizeLimit * 2 {
                        // 已经明显超过调用方给的上限，没必要继续吃内存
                        failure = true
                        return Z_MEM_ERROR
                    }
                    let newBuffer = UnsafeMutableRawPointer.allocate(byteCount: grown, alignment: 1)
                    newBuffer.copyMemory(from: outputBuffer, byteCount: capacity)
                    outputBuffer.deallocate()
                    outputBuffer = newBuffer
                    capacity = grown
                }

                stream.next_out = outputBuffer.assumingMemoryBound(to: Bytef.self).advanced(by: Int(stream.total_out))
                stream.avail_out = uInt(capacity - Int(stream.total_out))
                result = inflate(&stream, Z_NO_FLUSH)

                if sizeLimit > 0, Int(stream.total_out) > sizeLimit {
                    failure = true
                    return Z_MEM_ERROR
                }
                if result == Z_STREAM_END {
                    return Z_STREAM_END
                }
                if result != Z_OK {
                    return result
                }
                if stream.avail_in == 0, stream.avail_out != 0 {
                    // 输入耗尽但流没结束：数据被截断
                    return Z_DATA_ERROR
                }
            }
        }

        stream.next_in = nil
        stream.next_out = nil
        guard !failure, status == Z_STREAM_END else {
            return nil
        }
        return Data(bytes: outputBuffer, count: Int(stream.total_out))
    }
}

#if DEBUG
extension TiebaGZip {
    public nonisolated static func debugSelfCheck() -> Bool {
        assert(!isGzipped(Data()) && !isGzipped(Data([0x00, 0x01])))
        let source = Data(repeating: 0x41, count: 4096) + Data((0 ..< 2048).map { UInt8($0 & 0xFF) })
        guard let compressed = compress(source) else {
            assertionFailure("压缩失败")
            return false
        }
        assert(isGzipped(compressed), "压缩产物必须带 gzip 头")
        assert(compressed.count < source.count, "全 A 的数据必须能压小")
        assert(compress(compressed) == compressed, "已压缩的数据按上游语义原样返回")
        guard let restored = decompress(compressed) else {
            assertionFailure("解压失败")
            return false
        }
        assert(restored == source, "压缩→解压必须逐字节还原")
        assert(decompress(source) == nil, "非压缩输入必须返回 nil")
        assert(decompress(compressed, sizeLimit: 16) == nil, "超过 sizeLimit 必须失败")
        return true
    }
}
#endif
