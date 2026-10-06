// ============================================================
// Query 值编码集（TiebaURLQueryValue）
//
// [采用] 移植自上游: submodules/UrlEscaping/Sources/UrlEscaping.swift:21-31
// （上游 `CharacterSet.urlQueryValueAllowed`，逐行照搬）。
//
// 为什么需要：`CharacterSet.urlQueryAllowed` 是给**整条 query 串**用的，它**不转义**
// `&` 与 `=`（二者是 query 的分隔符）。把它当"单个参数值"的编码集用，
// 值里的 `&` 会被解析成参数边界 —— **静默丢参数**。已实测复现：
//
//   原始值   https://tieba.baidu.com/p/123?pn=2&see_lz=1
//   编码后   https://tieba.baidu.com/p/123?pn=2&see_lz=1      ← & 与 = 原样留着
//   拼进深链 tieba-native://link?url=<上面那个>
//   回读     https://tieba.baidu.com/p/123?pn=2               ← see_lz=1 没了
//
// 换成下面的集合后，`&` → `%26`、`=` → `%3D`，往返完整。
//
// 用法：**只在编码"单个 query 参数值"时用它**；编码整条 query 串仍应用
// `.urlQueryAllowed`（否则分隔符会被一起转义）。
// ============================================================

import Foundation

public extension CharacterSet {
    /// 单个 query 参数值的编码集 = `.urlQueryAllowed` 再减去通用/子分隔符。
    /// 上游：UrlEscaping.swift:22-30。
    static let tiebaURLQueryValueAllowed: CharacterSet = {
        let generalDelimitersToEncode = ":#[]@"
        let subDelimitersToEncode = "!$&'()*+,;="

        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: generalDelimitersToEncode + subDelimitersToEncode)

        return allowed
    }()
}
