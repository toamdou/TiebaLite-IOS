// 桶文件（bucket file）：本 module 里 238 个既有文件一行 import 都没改，
// 靠这一条 @_exported import 把 Proto 子模块（TiebaNativeProto）的 public API
// 传进 TiebaNative 的命名空间。Swift 的 @_exported import 是 **module 级**可见的
// （不是 file 级），已用 swiftc 单独实测过。
//
// 生成代码的访问级已统一放宽到 public（等价于 protoc-gen-swift 的 Visibility=Public），
// 因此 Tieba_* / SwiftProtobuf 的消息类型在宿主 module 里照旧直接可用。
@_exported import TiebaNativeProto
