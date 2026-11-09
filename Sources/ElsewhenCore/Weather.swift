import Foundation

/// A city's current reading, remembering where it was read for.
public struct WeatherReading: Equatable, Sendable {
  public var celsius: Double
  public var code: Int?
  public var atMs: Double
  public var lat: Double?
  public var lon: Double?

  public init(celsius: Double, code: Int?, atMs: Double, lat: Double? = nil, lon: Double? = nil) {
    self.celsius = celsius
    self.code = code
    self.atMs = atMs
    self.lat = lat
    self.lon = lon
  }
}

/// What is known of a row's place: where it is and what the sky is doing.
public struct Facts: Equatable, Sendable {
  public var lat: Double?
  public var lon: Double?
  public var celsius: Double?
  public var code: Int?

  public init(lat: Double? = nil, lon: Double? = nil, celsius: Double? = nil, code: Int? = nil) {
    self.lat = lat
    self.lon = lon
    self.celsius = celsius
    self.code = code
  }

  public var hasCoordinates: Bool { lat != nil && lon != nil }
}

public enum WeatherKind: String, Sendable { case sunny, partly, cloudy, rain, snow }

extension Model {
  public static let weatherTTLms: Double = 20 * 60 * 1000

  public static func forecastURL(_ points: [Place]) -> URL? {
    let lats = points.map { Words.plainNumber($0.lat ?? 0, nil) }.joined(separator: ",")
    let lons = points.map { Words.plainNumber($0.lon ?? 0, nil) }.joined(separator: ",")
    return URL(string: "https://api.open-meteo.com/v1/forecast?current=temperature_2m,weather_code&temperature_unit=celsius"
      + "&latitude=" + lats + "&longitude=" + lons)
  }

  /// Open-Meteo answers one point as an object and several as an array, in request order.
  public static func parseForecast(_ data: Data, keys: [String], nowMs: Double, points: [Place]? = nil) -> [String: WeatherReading] {
    guard let json = try? JSONSerialization.jsonObject(with: data) else { return [:] }
    let payload: [Any] = (json as? [Any]) ?? [json]
    var out: [String: WeatherReading] = [:]
    for i in 0..<min(keys.count, payload.count) {
      guard let item = payload[i] as? [String: Any], let current = item["current"] as? [String: Any],
            let temp = (current["temperature_2m"] as? NSNumber)?.doubleValue else { continue }
      var reading = WeatherReading(celsius: (temp * 10).rounded() / 10,
                                   code: (current["weather_code"] as? NSNumber)?.intValue, atMs: nowMs)
      if let points, i < points.count {
        reading.lat = points[i].lat
        reading.lon = points[i].lon
      }
      out[keys[i]] = reading
    }
    return out
  }

  /// Twenty minutes old, or read for somewhere other than `coords`.
  public static func weatherStale(_ entry: WeatherReading?, nowMs: Double, coords: Place?) -> Bool {
    guard let entry, nowMs - entry.atMs < weatherTTLms else { return true }
    guard let coords, entry.lat != nil else { return false }
    return !nearPlace(entry.lat, entry.lon, coords.lat, coords.lon)
  }

  /// WMO present-weather codes collapsed to the five glyphs a row can show.
  public static func weatherKind(_ code: Int?) -> WeatherKind? {
    guard let c = code else { return nil }
    switch c {
    case ...1: return .sunny
    case 2: return .partly
    case 3, 45, 48: return .cloudy
    case 71...77, 85, 86: return .snow
    case 51...67, 80...82, 95...99: return .rain
    default: return nil
    }
  }
}
