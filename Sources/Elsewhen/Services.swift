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

  /// The body of a successful HTTPS GET, delivered on the main queue; nil on any failure.
  static func get(_ url: URL?, _ done: @escaping (Data?) -> Void) {
    guard let url, url.scheme == "https" else {
      DispatchQueue.main.async { done(nil) }
      return
    }
    session.dataTask(with: url) { data, response, error in
      let ok = error == nil && ((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false)
      DispatchQueue.main.async { done(ok ? data : nil) }
    }.resume()
  }

  /// Several GETs at once, answered together in request order.
  static func getAll(_ urls: [URL?], _ done: @escaping ([Data?]) -> Void) {
    if urls.isEmpty {
      done([])
      return
    }
    var results = [Data?](repeating: nil, count: urls.count)
    let group = DispatchGroup()
    for (i, url) in urls.enumerated() {
      group.enter()
      get(url) { data in
        results[i] = data
        group.leave()
      }
    }
    group.notify(queue: .main) { done(results) }
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
  static func load(_ handles: [String], _ done: @escaping ([String: Profile]) -> Void) {
    let valid = handles.map { $0.lowercased() }.filter { Model.isGitHubHandle($0) }
    let dir = directory
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
    let group = DispatchGroup()
    for handle in valid {
      let json = dir.appendingPathComponent(handle + ".json")
      let image = dir.appendingPathComponent(handle + ".avatar")
      let stale = age(json).map { $0 > week } ?? true
      group.enter()
      if stale {
        Network.get(URL(string: "https://api.github.com/users/" + handle)) { data in
          if let data, (try? JSONSerialization.jsonObject(with: data)) != nil {
            try? data.write(to: json, options: .atomic)
            fetchAvatar(json, image, force: true) { group.leave() }
          } else {
            fetchAvatar(json, image, force: false) { group.leave() }
          }
        }
      } else {
        fetchAvatar(json, image, force: false) { group.leave() }
      }
    }
    group.notify(queue: .main) {
      var out: [String: Profile] = [:]
      for handle in valid {
        if let profile = read(handle, in: dir) { out[handle] = profile }
      }
      done(out)
    }
  }

  static func age(_ url: URL) -> TimeInterval? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
          let date = attrs[.modificationDate] as? Date, (attrs[.size] as? Int ?? 0) > 0 else { return nil }
    return Date().timeIntervalSince(date)
  }

  /// The avatar comes from GitHub's own avatar host by numeric id: the API's
  /// answer is not trusted to name a URL.
  static func fetchAvatar(_ json: URL, _ image: URL, force: Bool, _ done: @escaping () -> Void) {
    guard force || age(image) == nil,
          let data = try? Data(contentsOf: json),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let id = (object["id"] as? NSNumber)?.int64Value else {
      done()
      return
    }
    Network.get(URL(string: "https://avatars.githubusercontent.com/u/\(id)?s=96")) { data in
      if let data { try? data.write(to: image, options: .atomic) }
      done()
    }
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
