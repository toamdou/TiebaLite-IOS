// TiebaUrlEscaping —— URL 转义/还原与「文本里的链接」判定。
//
// 移植自上游 submodules/UrlEscaping/Sources/UrlEscaping.swift。
// 本仓改名：doesUrlMatchText → tiebaDoesUrlMatchText、isValidUrl → tiebaIsValidUrl、explicitUrl → tiebaExplicitUrl、urlEncodedStringFromString → tiebaUrlEncodedStringFromString —— 公开符号加本仓前缀，避免污染模块全局命名空间
// 本仓改动：正文算法/常量逐行未改，只有上面那项改名。

import Foundation

public func tiebaDoesUrlMatchText(url: String, text: String, fullText: String) -> Bool {
    if fullText.range(of: "\u{202e}") != nil {
        return false
    }
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
    if !url.unicodeScalars.allSatisfy({ allowed.contains($0) }) {
        return false
    }
    if url == text {
        return true
    }
    return false
}

public extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        let generalDelimitersToEncode = ":#[]@"
        let subDelimitersToEncode = "!$&'()*+,;="
        
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: generalDelimitersToEncode + subDelimitersToEncode)
        
        return allowed
    }()
}

public func tiebaIsValidUrl(_ url: String, validSchemes: [String: Bool] = ["http": true, "https": true, "tonsite": true]) -> Bool {
    if let escapedUrl = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed), let url = URL(string: escapedUrl), let scheme = url.scheme?.lowercased(), let requiresTopLevelDomain = validSchemes[scheme], let host = url.host, (!requiresTopLevelDomain || host.contains(".")) && url.user == nil {
        if requiresTopLevelDomain {
            let components = host.components(separatedBy: ".")
            let domain = (components.last ?? "")
            if domain.isEmpty {
                return false
            }
        }
        return true
    } else {
        return false
    }
}

public func tiebaExplicitUrl(_ url: String) -> String {
    var url = url
    if !url.lowercased().hasPrefix("http:") && !url.lowercased().hasPrefix("https:") && !url.lowercased().hasPrefix("tonsite:") && url.range(of: "://") == nil {
        if let parsedUrl = URL(string: "http://\(url)"), parsedUrl.host?.hasSuffix(".ton") == true {
            url = "tonsite://\(url)"
        } else {
            url = "https://\(url)"
        }
    }
    return url
}

private let validUrlSet: CharacterSet = {
    var set = CharacterSet(charactersIn: "a".unicodeScalars.first! ... "z".unicodeScalars.first!)
    set.insert(charactersIn: "A".unicodeScalars.first! ... "Z".unicodeScalars.first!)
    set.insert(charactersIn: "0".unicodeScalars.first! ... "9".unicodeScalars.first!)
    set.insert(charactersIn: ".?!@#$^&%*-+=,:;'\"`<>()[]{}/\\|~ ")
    return set
}()

public func tiebaUrlEncodedStringFromString(_ string: String) -> String {
    var nsString: NSString = string as NSString
    if let value = nsString.removingPercentEncoding {
        nsString = value as NSString
    }
    return nsString.addingPercentEncoding(withAllowedCharacters: validUrlSet) ?? ""
}
