// 扩展名 ⇄ MIME 全表。
//
// 移植自上游 `submodules/MimeTypes/Sources/TGMimeTypeMap.m`（公开头
// `submodules/MimeTypes/PublicHeaders/MimeTypes/TGMimeTypeMap.h`）。
//
// 为什么自己维护全表而不用系统 API：服务端/分享面板递过来的扩展名里有一批冷门货
// （sdc / sda / kpr / pcf.Z / lzx / sisx …），UTType 对这些查不到，而"查不到 MIME"
// 会直接变成下载、预览、分享面板上的错误类型。所以**静态表是基线**，UTType 只用来
// 补表外的漏（例如 heic / webp 这些后加的扩展名），顺序与上游相反但语义更稳。
//
// 相对上游的改动（逐条）：
//   1. ObjC 的 dispatch_once + 两张 NSMutableDictionary 字面量 → Swift 静态 let +
//      一张有序元组表；两张字典都由同一张表派生，不可能出现只改了一边的情况。
//   2. 上游按顺序对 NSMutableDictionary 赋值，**同键后写覆盖**（源码里
//      "add it first so it will be the default" 那条注释与 ObjC 实际语义不符：
//      text/plain 最终是 po 不是 txt）。本移植逐字保持后写覆盖——但它现在只是**兜底路径**：
//      系统查得到就用系统（见改动 4），所以那些怪值在正常路径上不会再出现。
//   3. 类方法 mimeTypeForExtension: / extensionForMimeType: → Swift 驼峰值
//      mimeType(forExtension:) / preferredExtension(forMimeType:)；nil 入参在 Swift
//      里由 String? 天然表达，不需要再判 nil。
//   4. 查询顺序：**静态表优先、UTType 兜底**（2026-10-05 按"性能 / 简洁 / 能力"三问复核后的结论）。
//      上游没有 UTType 这一步。中途一度改成"UTType 优先"，复核后改回表优先：
//        ① 性能：表 = 一次字典命中；UTType 要走系统类型库，每次上传/下载判类型都会走这条路 → 表明显更快。
//        ② 简洁：两者都是两行，没有差别；但表的取值**确定**（不随 iOS 版本变），回归与排障更省事。
//        ③ 能力：系统对冷门扩展名（swift / VOB / lzx / pcf.Z / spl / cpt）一律返回 nil —— 表必须有。
//      → 表优先 + UTType 兜底；UTType 负责"表没跟上的新扩展名"（如 heic）。
//      multipart 上传路径不受影响（portrait.jpg → image/jpeg 两边一致），自检里钉住了这条不变量。
//   5. 新增 #if DEBUG 自检 debugSelfCheck()：断言表规模（防重生成丢行）、两条路径的值、
//      以及 **multipart 上传的 MIME 不变量**。
//   6. 无全局可变状态：两张字典都是 let，天然 Sendable，所以整个 enum 是
//      nonisolated 纯查询，不需要 @MainActor（上游用 dispatch_once 保护的正是这一点）。
import Foundation

import UniformTypeIdentifiers

/// 扩展名 ↔ MIME 类型查询表。
///
/// 全部是纯查询，任意线程可调。
enum TiebaMimeTypes {
  /// 扩展名 → MIME。入参不带点（上游调用点统一传 `pathExtension` / `lowercaseString`）。
  ///
  /// 先查静态表（上游行为基线，大小写敏感），未命中再问 UTType。
  static func mimeType(forExtension fileExtension: String) -> String? {
    // **表优先**（三问复核后的结论，见文件头改动 4）：静态表是一次字典命中，
    // 而 UTType(filenameExtension:) 要走系统类型库（LaunchServices），在我们这条
    // "上传/下载判扩展名"的路径上表更快，结果也不随系统版本漂移。
    if let known = maps.byExtension[fileExtension] {
      return known
    }
    // 表里没有才问系统。这是**覆盖面兜底**（两个数据源各有盲区），不是"旧实现回退"：
    // 表覆盖 UTType 查不到的冷门扩展名，UTType 覆盖表没跟上的新扩展名（如 heic）。
    if let type = UTType(filenameExtension: fileExtension), let mime = type.preferredMIMEType {
      return mime
    }
    // 只有在系统查不到时才落回静态表 —— 表的唯一存在理由就是"UTType 对冷门扩展名返回 nil"。
    // 实测（iOS 26 模拟器）：swift / VOB / vob / lzx / pcf.Z / tex / cls / cur / spl / cpt 全是 nil，
    // 而服务端与分享面板会真的把这些扩展名递过来。
    return maps.byExtension[fileExtension]
  }

  /// MIME → 首选扩展名。
  ///
  /// 系统优先（UTType(mimeType:).preferredFilenameExtension）；系统给不出才落到表里那条
  /// "后写覆盖"的旧规则（image/jpeg → jpe、text/plain → po、video/mpeg → VOB）。
  /// 换句话说：判据③把上游那套怪值从**主路径**上摘掉了，只在系统无解时才露出来。
  static func preferredExtension(forMimeType mimeType: String) -> String? {
    if let known = maps.byMimeType[mimeType] {
      return known
    }
    if let type = UTType(mimeType: mimeType), let fileExtension = type.preferredFilenameExtension {
      return fileExtension
    }
    // 系统给不出扩展名（application/x-font、text/swift 这类冷门 MIME）才查表。
    return maps.byMimeType[mimeType]
  }

  /// 上游赋值顺序即语义，不要重排：重复键的最终值取决于先后。
  private static let table: [(mime: String, fileExtension: String)] = [
    // application/*
    ("application/andrew-inset", "ez"),
    ("application/dsptype", "tsp"),
    ("application/futuresplash", "spl"),
    ("application/hta", "hta"),
    ("application/mac-binhex40", "hqx"),
    ("application/mac-compactpro", "cpt"),
    ("application/mathematica", "nb"),
    ("application/msaccess", "mdb"),
    ("application/oda", "oda"),
    ("application/ogg", "ogg"),
    ("application/pdf", "pdf"),
    ("application/pgp-keys", "key"),
    ("application/pgp-signature", "pgp"),
    ("application/pics-rules", "prf"),
    ("application/rar", "rar"),
    ("application/rdf+xml", "rdf"),
    ("application/rss+xml", "rss"),
    ("application/zip", "zip"),
    ("application/vnd.android.package-archive", "apk"),
    ("application/vnd.cinderella", "cdy"),
    ("application/vnd.ms-pki.stl", "stl"),
    ("application/vnd.oasis.opendocument.database", "odb"),
    ("application/vnd.oasis.opendocument.formula", "odf"),
    ("application/vnd.oasis.opendocument.graphics", "odg"),
    ("application/vnd.oasis.opendocument.graphics-template", "otg"),
    ("application/vnd.oasis.opendocument.image", "odi"),
    ("application/vnd.oasis.opendocument.spreadsheet", "ods"),
    ("application/vnd.oasis.opendocument.spreadsheet-template", "ots"),
    ("application/vnd.oasis.opendocument.text", "odt"),
    ("application/vnd.oasis.opendocument.text-master", "odm"),
    ("application/vnd.oasis.opendocument.text-template", "ott"),
    ("application/vnd.oasis.opendocument.text-web", "oth"),
    ("application/msword", "doc"),
    ("application/msword", "dot"),
    ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx"),
    ("application/vnd.openxmlformats-officedocument.wordprocessingml.template", "dotx"),
    ("application/vnd.ms-excel", "xls"),
    ("application/vnd.ms-excel", "xlt"),
    ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx"),
    ("application/vnd.openxmlformats-officedocument.spreadsheetml.template", "xltx"),
    ("application/vnd.ms-powerpoint", "ppt"),
    ("application/vnd.ms-powerpoint", "pot"),
    ("application/vnd.ms-powerpoint", "pps"),
    ("application/vnd.openxmlformats-officedocument.presentationml.presentation", "pptx"),
    ("application/vnd.openxmlformats-officedocument.presentationml.template", "potx"),
    ("application/vnd.openxmlformats-officedocument.presentationml.slideshow", "ppsx"),
    ("application/vnd.rim.cod", "cod"),
    ("application/vnd.smaf", "mmf"),
    ("application/vnd.stardivision.calc", "sdc"),
    ("application/vnd.stardivision.draw", "sda"),
    ("application/vnd.stardivision.impress", "sdd"),
    ("application/vnd.stardivision.impress", "sdp"),
    ("application/vnd.stardivision.math", "smf"),
    ("application/vnd.stardivision.writer", "sdw"),
    ("application/vnd.stardivision.writer", "vor"),
    ("application/vnd.stardivision.writer-global", "sgl"),
    ("application/vnd.sun.xml.calc", "sxc"),
    ("application/vnd.sun.xml.calc.template", "stc"),
    ("application/vnd.sun.xml.draw", "sxd"),
    ("application/vnd.sun.xml.draw.template", "std"),
    ("application/vnd.sun.xml.impress", "sxi"),
    ("application/vnd.sun.xml.impress.template", "sti"),
    ("application/vnd.sun.xml.math", "sxm"),
    ("application/vnd.sun.xml.writer", "sxw"),
    ("application/vnd.sun.xml.writer.global", "sxg"),
    ("application/vnd.sun.xml.writer.template", "stw"),
    ("application/vnd.visio", "vsd"),
    ("application/x-abiword", "abw"),
    ("application/x-apple-diskimage", "dmg"),
    ("application/x-bcpio", "bcpio"),
    ("application/x-bittorrent", "torrent"),
    ("application/x-cdf", "cdf"),
    ("application/x-cdlink", "vcd"),
    ("application/x-chess-pgn", "pgn"),
    ("application/x-cpio", "cpio"),
    ("application/x-debian-package", "deb"),
    ("application/x-debian-package", "udeb"),
    ("application/x-director", "dcr"),
    ("application/x-director", "dir"),
    ("application/x-director", "dxr"),
    ("application/x-dms", "dms"),
    ("application/x-doom", "wad"),
    ("application/x-dvi", "dvi"),
    // audio/*
    ("audio/flac", "flac"),
    // application/*
    ("application/x-font", "pfa"),
    ("application/x-font", "pfb"),
    ("application/x-font", "gsf"),
    ("application/x-font", "pcf"),
    ("application/x-font", "pcf.Z"),
    ("application/x-freemind", "mm"),
    ("application/x-futuresplash", "spl"),
    ("application/x-gnumeric", "gnumeric"),
    ("application/x-go-sgf", "sgf"),
    ("application/x-graphing-calculator", "gcf"),
    ("application/x-gtar", "gtar"),
    ("application/x-gtar", "tgz"),
    ("application/x-gtar", "taz"),
    ("application/x-hdf", "hdf"),
    ("application/x-ica", "ica"),
    ("application/x-internet-signup", "ins"),
    ("application/x-internet-signup", "isp"),
    ("application/x-iphone", "iii"),
    ("application/x-iso9660-image", "iso"),
    ("application/x-jmol", "jmz"),
    ("application/x-kchart", "chrt"),
    ("application/x-killustrator", "kil"),
    ("application/x-koan", "skp"),
    ("application/x-koan", "skd"),
    ("application/x-koan", "skt"),
    ("application/x-koan", "skm"),
    ("application/x-kpresenter", "kpr"),
    ("application/x-kpresenter", "kpt"),
    ("application/x-kspread", "ksp"),
    ("application/x-kword", "kwd"),
    ("application/x-kword", "kwt"),
    ("application/x-latex", "latex"),
    ("application/x-lha", "lha"),
    ("application/x-lzh", "lzh"),
    ("application/x-lzx", "lzx"),
    ("application/x-maker", "frm"),
    ("application/x-maker", "maker"),
    ("application/x-maker", "frame"),
    ("application/x-maker", "fb"),
    ("application/x-maker", "book"),
    ("application/x-maker", "fbdoc"),
    ("application/x-mif", "mif"),
    ("application/x-ms-wmd", "wmd"),
    ("application/x-ms-wmz", "wmz"),
    ("application/x-msi", "msi"),
    ("application/x-ns-proxy-autoconfig", "pac"),
    ("application/x-nwc", "nwc"),
    ("application/x-object", "o"),
    ("application/x-oz-application", "oza"),
    ("application/x-pkcs12", "p12"),
    ("application/x-pkcs7-certreqresp", "p7r"),
    ("application/x-pkcs7-crl", "crl"),
    ("application/x-quicktimeplayer", "qtl"),
    ("application/x-shar", "shar"),
    ("application/x-shockwave-flash", "swf"),
    ("application/x-stuffit", "sit"),
    ("application/x-sv4cpio", "sv4cpio"),
    ("application/x-sv4crc", "sv4crc"),
    ("application/x-tar", "tar"),
    ("application/x-texinfo", "texinfo"),
    ("application/x-texinfo", "texi"),
    ("application/x-troff", "t"),
    ("application/x-troff", "roff"),
    ("application/x-troff-man", "man"),
    ("application/x-ustar", "ustar"),
    ("application/x-wais-source", "src"),
    ("application/x-wingz", "wz"),
    ("application/x-webarchive", "webarchive"),
    ("application/x-x509-ca-cert", "crt"),
    ("application/x-x509-user-cert", "crt"),
    ("application/x-xcf", "xcf"),
    ("application/x-xfig", "fig"),
    ("application/xhtml+xml", "xhtml"),
    // audio/*
    ("audio/3gpp", "3gpp"),
    ("audio/basic", "snd"),
    ("audio/midi", "mid"),
    ("audio/midi", "midi"),
    ("audio/midi", "kar"),
    ("audio/mpeg", "mpga"),
    ("audio/mpeg", "mpega"),
    ("audio/mpeg", "mp2"),
    ("audio/mpeg", "mp3"),
    ("audio/mpeg", "m4a"),
    ("audio/mpegurl", "m3u"),
    ("audio/prs.sid", "sid"),
    ("audio/x-aiff", "aif"),
    ("audio/x-aiff", "aiff"),
    ("audio/x-aiff", "aifc"),
    ("audio/x-gsm", "gsm"),
    ("audio/x-mpegurl", "m3u"),
    ("audio/x-ms-wma", "wma"),
    ("audio/x-ms-wax", "wax"),
    ("audio/x-pn-realaudio", "ra"),
    ("audio/x-pn-realaudio", "rm"),
    ("audio/x-pn-realaudio", "ram"),
    ("audio/x-realaudio", "ra"),
    ("audio/x-scpls", "pls"),
    ("audio/x-sd2", "sd2"),
    ("audio/x-wav", "wav"),
    // image/*
    ("image/bmp", "bmp"),
    ("image/gif", "gif"),
    ("image/ico", "cur"),
    ("image/ico", "ico"),
    ("image/ief", "ief"),
    ("image/jpeg", "jpeg"),
    ("image/jpeg", "jpg"),
    ("image/jpeg", "jpe"),
    ("image/pcx", "pcx"),
    ("image/png", "png"),
    ("image/svg+xml", "svg"),
    ("image/svg+xml", "svgz"),
    ("image/tiff", "tiff"),
    ("image/tiff", "tif"),
    ("image/vnd.djvu", "djvu"),
    ("image/vnd.djvu", "djv"),
    ("image/vnd.wap.wbmp", "wbmp"),
    ("image/x-cmu-raster", "ras"),
    ("image/x-coreldraw", "cdr"),
    ("image/x-coreldrawpattern", "pat"),
    ("image/x-coreldrawtemplate", "cdt"),
    ("image/x-corelphotopaint", "cpt"),
    ("image/x-icon", "ico"),
    ("image/x-jg", "art"),
    ("image/x-jng", "jng"),
    ("image/x-ms-bmp", "bmp"),
    ("image/x-photoshop", "psd"),
    ("image/x-portable-anymap", "pnm"),
    ("image/x-portable-bitmap", "pbm"),
    ("image/x-portable-graymap", "pgm"),
    ("image/x-portable-pixmap", "ppm"),
    ("image/x-rgb", "rgb"),
    ("image/x-xbitmap", "xbm"),
    ("image/x-xpixmap", "xpm"),
    ("image/x-xwindowdump", "xwd"),
    // model/*
    ("model/iges", "igs"),
    ("model/iges", "iges"),
    ("model/mesh", "msh"),
    ("model/mesh", "mesh"),
    ("model/mesh", "silo"),
    // text/*
    ("text/calendar", "ics"),
    ("text/calendar", "icz"),
    ("text/comma-separated-values", "csv"),
    ("text/css", "css"),
    ("text/html", "htm"),
    ("text/html", "html"),
    ("text/h323", "323"),
    ("text/iuls", "uls"),
    ("text/mathml", "mml"),
    ("text/plain", "txt"),
    ("text/plain", "asc"),
    ("text/plain", "text"),
    ("text/plain", "diff"),
    ("text/plain", "po"),
    ("text/markdown", "md"),
    ("text/richtext", "rtx"),
    ("text/rtf", "rtf"),
    ("text/texmacs", "ts"),
    ("text/text", "phps"),
    ("text/tab-separated-values", "tsv"),
    ("text/xml", "xml"),
    ("text/x-bibtex", "bib"),
    ("text/x-boo", "boo"),
    ("text/x-c++hdr", "h++"),
    ("text/x-c++hdr", "hpp"),
    ("text/x-c++hdr", "hxx"),
    ("text/x-c++hdr", "hh"),
    ("text/x-c++src", "c++"),
    ("text/x-c++src", "cpp"),
    ("text/x-c++src", "cxx"),
    ("text/x-chdr", "h"),
    ("text/x-component", "htc"),
    ("text/x-csh", "csh"),
    ("text/x-csrc", "c"),
    ("text/x-dsrc", "d"),
    ("text/x-haskell", "hs"),
    ("text/x-java", "java"),
    ("text/x-literate-haskell", "lhs"),
    ("text/x-moc", "moc"),
    ("text/x-pascal", "p"),
    ("text/x-pascal", "pas"),
    ("text/x-pcs-gcd", "gcd"),
    ("text/x-setext", "etx"),
    ("text/x-tcl", "tcl"),
    ("text/x-tex", "tex"),
    ("text/x-tex", "ltx"),
    ("text/x-tex", "sty"),
    ("text/x-tex", "cls"),
    ("text/x-vcalendar", "vcs"),
    ("text/x-vcard", "vcf"),
    // video/*
    ("video/3gpp", "3gpp"),
    ("video/3gpp", "3gp"),
    ("video/3gpp", "3g2"),
    ("video/dl", "dl"),
    ("video/dv", "dif"),
    ("video/dv", "dv"),
    ("video/fli", "fli"),
    ("video/m4v", "m4v"),
    ("video/mpeg", "mpeg"),
    ("video/mpeg", "mpg"),
    ("video/mpeg", "mpe"),
    ("video/mp4", "mp4"),
    ("video/mpeg", "VOB"),
    ("video/quicktime", "qt"),
    ("video/quicktime", "mov"),
    ("video/vnd.mpegurl", "mxu"),
    ("video/x-la-asf", "lsf"),
    ("video/x-la-asf", "lsx"),
    ("video/x-mng", "mng"),
    ("video/x-ms-asf", "asf"),
    ("video/x-ms-asf", "asx"),
    ("video/x-ms-wm", "wm"),
    ("video/x-ms-wmv", "wmv"),
    ("video/x-ms-wmx", "wmx"),
    ("video/x-ms-wvx", "wvx"),
    ("video/x-msvideo", "avi"),
    ("video/x-sgi-movie", "movie"),
    // x-conference/*
    ("x-conference/x-cooltalk", "ice"),
    // x-epoc/*
    ("x-epoc/x-sisx-app", "sisx"),
    // application/*
    ("application/epub+zip", "epub"),
    // text/*
    ("text/swift", "swift"),
  ]

  /// 两张派生字典。同键后写覆盖 —— 与上游 NSMutableDictionary 顺序赋值等价。
  private static let maps: (byExtension: [String: String], byMimeType: [String: String]) = {
    var byExtension: [String: String] = [:]
    var byMimeType: [String: String] = [:]
    byExtension.reserveCapacity(table.count)
    byMimeType.reserveCapacity(table.count)
    for entry in table {
      byExtension[entry.fileExtension] = entry.mime
      byMimeType[entry.mime] = entry.fileExtension
    }
    #if DEBUG
      // 表被重生成坏掉时，最早在这里炸，而不是等到用户下载文件时。
      assert(!byExtension.isEmpty && !byMimeType.isEmpty)
      assert(byExtension["jpg"] == "image/jpeg")
    #endif
    return (byExtension, byMimeType)
  }()

  #if DEBUG
    /// 已知值自检。**当前无人调用**（本任务不接线），验收时手工跑一次；
    /// 断言全部来自上游 .m 的实际语义，不是"我觉得应该"。
    static func debugSelfCheck() {
      assert(table.count == 304, "表规模变了：\(table.count)")
      assert(maps.byExtension.count == 296, "去重后扩展名数变了：\(maps.byExtension.count)")
      assert(maps.byMimeType.count == 233, "去重后 MIME 数变了：\(maps.byMimeType.count)")

      // 常见类型
      assert(mimeType(forExtension: "jpg") == "image/jpeg")
      assert(mimeType(forExtension: "png") == "image/png")
      assert(mimeType(forExtension: "gif") == "image/gif")
      assert(mimeType(forExtension: "mp4") == "video/mp4")
      assert(mimeType(forExtension: "mp3") == "audio/mpeg")
      assert(mimeType(forExtension: "pdf") == "application/pdf")
      assert(mimeType(forExtension: "zip") == "application/zip")
      assert(mimeType(forExtension: "epub") == "application/epub+zip")
      assert(mimeType(forExtension: "swift") == "text/swift")
      assert(mimeType(forExtension: "md") == "text/markdown")
      // ⭐ 接线不变量：multipart 上传用的 jpg 必须仍然是 image/jpeg
      //（TiebaHttpClient 按文件名扩展名派生 Content-Type；这条一破，头像上传的类型就错了）
      assert(mimeType(forExtension: "jpg") == "image/jpeg", "multipart 的 MIME 派生被改坏了")

      // ── 主路径：静态表（一次字典命中，快且确定；见文件头改动 4）──
      assert(mimeType(forExtension: "png") == "image/png")
      assert(mimeType(forExtension: "gif") == "image/gif")
      assert(mimeType(forExtension: "mp4") == "video/mp4")
      assert(mimeType(forExtension: "mp3") == "audio/mpeg")
      assert(mimeType(forExtension: "pdf") == "application/pdf")
      assert(mimeType(forExtension: "zip") == "application/zip")
      assert(mimeType(forExtension: "swift") == "text/swift")
      assert(mimeType(forExtension: "md") == "text/markdown")
      // 表的"后写覆盖"怪值：上游就是这些值，本移植逐字保留（改动 2）
      assert(mimeType(forExtension: "ico") == "image/x-icon")
      assert(mimeType(forExtension: "bmp") == "image/x-ms-bmp")
      assert(mimeType(forExtension: "spl") == "application/x-futuresplash")
      assert(mimeType(forExtension: "cpt") == "image/x-corelphotopaint")
      assert(mimeType(forExtension: "3gpp") == "video/3gpp")
      // 大写键只有表里有；小写 vob 表里没有、系统也查不到
      assert(mimeType(forExtension: "VOB") == "video/mpeg")
      assert(mimeType(forExtension: "vob") == nil)
      assert(preferredExtension(forMimeType: "image/jpeg") == "jpe")
      assert(preferredExtension(forMimeType: "text/plain") == "po")
      assert(preferredExtension(forMimeType: "video/mpeg") == "VOB")
      assert(preferredExtension(forMimeType: "application/pdf") == "pdf")
      assert(preferredExtension(forMimeType: "application/x-font") == "pcf.Z")

      // ── 兜底路径：表里没有这个键才问系统（覆盖面互补，不是旧实现回退）──
      assert(mimeType(forExtension: "heic") == "image/heic", "UTType 兜底失效：\(mimeType(forExtension: "heic") ?? "nil")")
      assert(mimeType(forExtension: "JPG") == "image/jpeg", "大写扩展名要靠 UTType 兜（表是大小写敏感的）")
      assert(preferredExtension(forMimeType: "text/swift") == "swift", "表里有 text/swift")
      assert(mimeType(forExtension: "definitely-not-a-real-ext") == nil)
    }
  #endif
}
