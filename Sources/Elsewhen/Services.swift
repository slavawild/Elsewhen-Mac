import Foundation
import ElsewhenCore

/// The network, as little of it as the panel needs: Open-Meteo for places and
/// weather (no key), and the public GitHub profile of anyone added by handle.
enum Network {
  static let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 8
    config.timeoutIntervalForResource = 12
    config.httpAdditionalHeaders = ["User-Agent": "Elsewhen-macOS"]
    return URLSession(configuration: config)
  }()

  /// The body of a successful HTTPS GET; nil on any failure.
  static func get(_ url: URL?) async -> Data? {
    guard let url, url.scheme == "https" else { return nil }
    guard let answer = try? await session.data(from: url),
          let http = answer.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
    return answer.0
  }

  /// Several GETs at once, answered together in request order.
  static func getAll(_ urls: [URL?]) async -> [Data?] {
    await withTaskGroup(of: (Int, Data?).self) { group in
      for (i, url) in urls.enumerated() {
        group.addTask { (i, await Network.get(url)) }
      }
      var results = [Data?](repeating: nil, count: urls.count)
      for await (i, data) in group { results[i] = data }
      return results
    }
  }
}

/// The tz database's representative city for each zone, the offline fallback for coordinates.
enum ZoneTab {
  static let text: String = {
    for path in ["/usr/share/zoneinfo/zone1970.tab", "/usr/share/zoneinfo/zone.tab", "/var/db/timezone/zoneinfo/zone.tab"] {
      if let text = try? String(contentsOfFile: path, encoding: .utf8) { return text }
    }
    return ""
  }()
}

/// GitHub profiles by handle, cached on disk for a week with their avatars.
enum Profiles {
  static let week: TimeInterval = 7 * 24 * 3600

  static var directory: URL {
    let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSTemporaryDirectory())
    return base.appendingPathComponent("io.github.slavawild.Elsewhen/people", isDirectory: true)
  }

  /// Fetches what is missing or stale, then answers with every profile it has.
  static func load(_ handles: [String]) async -> [String: Profile] {
    let valid = handles.map { $0.lowercased() }.filter { Model.isGitHubHandle($0) }
    let dir = directory
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    await withTaskGroup(of: Void.self) { group in
      for handle in valid {
        group.addTask {
          let json = dir.appendingPathComponent(handle + ".json")
          let image = dir.appendingPathComponent(handle + ".avatar")
          var fresh = false
          if age(json).map({ $0 > week }) ?? true,
             let data = await Network.get(URL(string: "https://api.github.com/users/" + handle)),
             (try? JSONSerialization.jsonObject(with: data)) != nil {
            try? data.write(to: json, options: .atomic)
            fresh = true
          }
          await fetchAvatar(json, image, force: fresh)
        }
      }
    }
    var out: [String: Profile] = [:]
    for handle in valid {
      if let profile = read(handle, in: dir) { out[handle] = profile }
    }
    return out
  }

  static func age(_ url: URL) -> TimeInterval? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let date = attrs[.modificationDate] as? Date, (attrs[.size] as? Int ?? 0) > 0 else { return nil }
    return Date().timeIntervalSince(date)
  }

  /// The avatar comes from GitHub's own avatar host by numeric id: the API's
  /// answer is not trusted to name a URL.
  static func fetchAvatar(_ json: URL, _ image: URL, force: Bool) async {
    guard force || age(image) == nil,
          let data = try? Data(contentsOf: json),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = (object["id"] as? NSNumber)?.int64Value,
          let avatar = await Network.get(URL(string: "https://avatars.githubusercontent.com/u/\(id)?s=96")) else { return }
    try? avatar.write(to: image, options: .atomic)
  }

  static func read(_ handle: String, in dir: URL) -> Profile? {
    guard let data = try? Data(contentsOf: dir.appendingPathComponent(handle + ".json")),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let image = dir.appendingPathComponent(handle + ".avatar")
    return Profile(
      login: (object["login"] as? String) ?? handle,
      name: Model.cleanLabel(object["name"] as? String),
      avatar: age(image) == nil ? "" : image.path
    )
  }
}
