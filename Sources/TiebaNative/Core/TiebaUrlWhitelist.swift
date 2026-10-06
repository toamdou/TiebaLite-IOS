// TiebaUrlWhitelist —— URL 白名单（哪些链接可以应用内打开）。
//
// 移植自上游 submodules/UrlWhitelist/Sources/UrlWhitelist.swift。
// 本仓改名：isConcealedUrlWhitelisted → tiebaIsConcealedUrlWhitelisted、parseUrl → tiebaParseUrl —— 公开符号加本仓前缀，避免污染模块全局命名空间
// 本仓改动：
//   1) 白名单域名换成百度系 —— 上游那份是它自家域名，在贴吧里恒不命中，等于白名单失效。
//   2) 删掉上游"官网域名 + /blog/ /tour/ 原生路径"那段分支：那是它自家官网路径，
//      对 tieba.baidu.com 无意义；百度系域名靠下面的域名集合命中即可。
//   3) 删掉上游 "tg://premium_*" 分支：那是上游自家深层链接协议，贴吧不存在这个词法。
// 其余（同形字检测 hasLatin && hasNonLatin、tel: 直通）逐行未改。

import Foundation

private let whitelistedHosts: Set<String> = Set([
    "baidu.com",
    "tieba.baidu.com",
    "pan.baidu.com",
    "tieba.com"
])

public func tiebaIsConcealedUrlWhitelisted(_ url: URL) -> Bool {
    if var host = url.host?.lowercased() {
        let www = "www."
        if host.hasPrefix(www) {
            host.removeFirst(www.count)
        }
        if whitelistedHosts.contains(host) {
            return true
        }
    }
    return false
}

public func tiebaParseUrl(url: String, wasConcealed: Bool) -> (string: String, concealed: Bool) {
    var parsedUrlValue: URL?
    if url.hasPrefix("tel:") {
        return (url, false)
    } else if url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://"), let parsed = URL(string: url) {
        parsedUrlValue = parsed
    } else if let parsed = URL(string: "https://" + url) {
        parsedUrlValue = parsed
    } else if let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let parsed = URL(string: encoded) {
        parsedUrlValue = parsed
    }
    let host = parsedUrlValue?.host ?? url
    
    let rawHost = (host as NSString).removingPercentEncoding ?? host
    var latin = CharacterSet()
    latin.insert(charactersIn: "A"..."Z")
    latin.insert(charactersIn: "a"..."z")
    latin.insert(charactersIn: "0"..."9")
    var punctuation = CharacterSet()
    punctuation.insert(charactersIn: ".-/+_?=")
    var hasLatin = false
    var hasNonLatin = false
    for c in rawHost {
        if c.unicodeScalars.allSatisfy(punctuation.contains) {
        } else if c.unicodeScalars.allSatisfy(latin.contains) {
            hasLatin = true
        } else {
            hasNonLatin = true
        }
    }
    var concealed = wasConcealed
    if hasLatin && hasNonLatin {
        concealed = true
    }
    
    var rawDisplayUrl: String
    if hasNonLatin {
        rawDisplayUrl = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
    } else {
        rawDisplayUrl = url
    }
    
    if let parsedUrlValue = parsedUrlValue, tiebaIsConcealedUrlWhitelisted(parsedUrlValue) {
        concealed = false
    }
    
    let whitelistedSchemes: [String] = [
        "tel",
    ]
    if let parsedUrlValue = parsedUrlValue, let scheme = parsedUrlValue.scheme, whitelistedSchemes.contains(scheme) {
        concealed = false
    }
    
    return (rawDisplayUrl, concealed)
}
