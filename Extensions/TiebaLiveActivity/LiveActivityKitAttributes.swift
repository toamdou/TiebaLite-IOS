import ActivityKit
import Foundation

public struct LiveActivityKitAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    public var title: String
    public var subtitle: String?
    public var body: String?
    public var currentForum: String?
    public var status: String?
    public var progress: Double?
    public var date: Double?
    public var imageName: String?
    public var tintColorHex: String?
    public var leading: String?
    public var trailing: String?
    public var extra: [String: String]?

    public init(
      title: String,
      subtitle: String? = nil,
      body: String? = nil,
      currentForum: String? = nil,
      status: String? = nil,
      progress: Double? = nil,
      date: Double? = nil,
      imageName: String? = nil,
      tintColorHex: String? = nil,
      leading: String? = nil,
      trailing: String? = nil,
      extra: [String: String]? = nil
    ) {
      self.title = title
      self.subtitle = subtitle
      self.body = body
      self.currentForum = currentForum
      self.status = status
      self.progress = progress
      self.date = date
      self.imageName = imageName
      self.tintColorHex = tintColorHex
      self.leading = leading
      self.trailing = trailing
      self.extra = extra
    }
  }

  public var name: String
  public var extra: [String: String]?

  public init(name: String, extra: [String: String]? = nil) {
    self.name = name
    self.extra = extra
  }
}
