import Foundation

/// 贴吧图源 URL 归一：http 一律升级 https（全仓同约定），再解析成 URL。
/// 从 UI/Media/TiebaPhotoBrowserTypes.swift 的 TiebaPhotoItem.normalizedURL 下沉而来：
/// "按偏好选哪张图 + URL 怎么归一"是纯口径，列表行模型与查看器都要按同一份实现走，
/// 留在媒体层会把行模型拖成它的下游。TiebaPhotoItem.normalizedURL 仍保留为转发入口。
enum TiebaImageURL {
  static func normalized(_ raw: String) -> URL? {
    let upgraded = raw.hasPrefix("http://") ? "https://" + raw.dropFirst("http://".count) : raw
    return URL(string: upgraded)
  }
}
