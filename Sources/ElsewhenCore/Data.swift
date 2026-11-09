import Foundation

/// The data files that ship with the app, found whether it runs from an .app
/// bundle (where the build script copies the resource bundle into
/// Contents/Resources) or straight out of `swift build`/`swift test`.
public enum CoreResources {
  private final class Token {}

  public static let bundle: Bundle = locate("Elsewhen_ElsewhenCore") ?? Bundle.module

  /// A SwiftPM resource bundle by name, looked for where an app and a build put it.
  public static func locate(_ name: String) -> Bundle? {
    let file = name + ".bundle"
    let places = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle(for: Token.self).resourceURL,
                  Bundle(for: Token.self).bundleURL.deletingLastPathComponent()]
    for place in places.compactMap({ $0 }) {
      if let bundle = Bundle(url: place.appendingPathComponent(file)) { return bundle }
    }
    return nil
  }

  public static func data(_ name: String) -> Data? {
    guard let url = bundle.url(forResource: name, withExtension: "json") else { return nil }
    return try? Data(contentsOf: url)
  }
}

/// The globe's coastlines and built-in cities.
public enum GlobeData {
  /// Natural Earth 110m coastlines as flat [lon, lat, ...] rings.
  public static let land: [Ring] = {
    guard let data = CoreResources.data("world"),
          let rings = try? JSONDecoder().decode([[Double]].self, from: data) else { return [] }
    return rings
  }()

  /// Half the vertices, for the small end of the zoom.
  public static let landCoarse: [Ring] = land.map { Solar.decimateRing($0, keepEvery: 2, minPoints: 8) }

  /// The major city of every zone.
  public static let cities: [GlobeCity] = {
    guard let data = CoreResources.data("cities"),
          let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [] }
    return rows.compactMap { row in
      guard row.count >= 5, let name = row[0] as? String, let zone = row[1] as? String,
            let lat = (row[2] as? NSNumber)?.doubleValue, let lon = (row[3] as? NSNumber)?.doubleValue,
            let rank = (row[4] as? NSNumber)?.intValue else { return nil }
      return GlobeCity(name: name, zone: zone, lat: lat, lon: lon, rank: rank)
    }
  }()
}

/// What people say to each other at this hour where a clock points: zone ->
/// country -> the language you would hear spoken there, with a few city overrides.
public enum Greetings {
  public struct Greeting: Equatable, Sendable {
    public var text: String
    /// A pronunciation, given only where the script is not Latin.
    public var roman: String
    public var language: String
    public var key: String
  }

  struct Band: Decodable {
    var from: Int
    var text: String
    var roman: String
  }

  struct Language: Decodable {
    var name: String
    var bands: [Band]
  }

  struct Table: Decodable {
    var fallback: String
    var languages: [String: Language]
    var countries: [String: String]
    var overrides: [String: String]
    var aliasCountry: [String: String]
    var zoneCountry: [String: String]
  }

  static let table: Table? = {
    guard let data = CoreResources.data("greetings") else { return nil }
    return try? JSONDecoder().decode(Table.self, from: data)
  }()

  /// "" for the offset-only zones.
  public static func countryFor(_ zone: String) -> String {
    guard let table else { return "" }
    return table.aliasCountry[zone] ?? table.zoneCountry[zone] ?? ""
  }

  public static func languageFor(_ zone: String) -> String {
    guard let table else { return "en" }
    if let o = table.overrides[zone], table.languages[o] != nil { return o }
    if let key = table.countries[countryFor(zone)], table.languages[key] != nil { return key }
    return table.fallback
  }

  /// The greeting for a zone at a local hour.
  public static func greeting(_ zone: String, hour: Int) -> Greeting {
    guard let table, let language = table.languages[languageFor(zone)], let first = language.bands.first else {
      return Greeting(text: "", roman: "", language: "", key: "")
    }
    let h = max(0, min(23, hour))
    var band = first
    for b in language.bands.dropFirst() {
      if b.from > h { break }
      band = b
    }
    return Greeting(text: band.text, roman: band.roman, language: language.name, key: languageFor(zone))
  }
}
