import Foundation

/// Sunrise and sunset for a place on its own day, from the globe's own
/// subsolar point so the strip and the terminator cannot disagree.
public enum Sun {
  /// Refraction plus the sun's radius, the figure published sunrise tables use.
  static let horizon = -0.833
  static let deg = Double.pi / 180

  public enum Kind: Sendable { case normal, midnightSun, polarNight }

  public struct Times: Equatable, Sendable {
    public var kind: Kind
    public var noonMs: Double
    public var riseMs: Double?
    public var setMs: Double?
    /// Minutes from local midnight; may fall outside 0...1440 for a zone far from its own sun.
    public var riseMinutes: Double?
    public var setMinutes: Double?
    public var dayMinutes: Double
  }

  public struct Span: Equatable, Sendable {
    public var x0: Double
    public var x1: Double

    public init(x0: Double, x1: Double) {
      self.x0 = x0
      self.x1 = x1
    }
  }

  static func wrap180(_ deg: Double) -> Double {
    (deg + 540).truncatingRemainder(dividingBy: 360) - 180
  }

  /// Local solar noon: three corrections take the residual below a second.
  public static func solarNoonMs(lon: Double, near: Double) -> Double {
    var t = near
    for _ in 0..<3 {
      let sub = Solar.subsolarPoint(t)
      t += wrap180(sub.lon - lon) / 15 * 3600000
    }
    return t
  }

  /// The zone's own local midnight, as a UTC instant.
  public static func localMidnightMs(_ ms: Double, offsetMinutes: Int) -> Double {
    let local = ms + Double(offsetMinutes) * 60000
    return (local / 86400000).rounded(.down) * 86400000 - Double(offsetMinutes) * 60000
  }

  /// Sunrise and sunset for the local day containing `ms`.
  public static func sunTimes(lat: Double, lon: Double, ms: Double, offsetMinutes: Int) -> Times {
    let midnight = localMidnightMs(ms, offsetMinutes: offsetMinutes)
    let noon = solarNoonMs(lon: lon, near: midnight + 43200000)
    let dec = Solar.subsolarPoint(noon).lat
    let cosH = (sin(horizon * deg) - sin(lat * deg) * sin(dec * deg)) / (cos(lat * deg) * cos(dec * deg))
    if cosH <= -1 {
      return Times(kind: .midnightSun, noonMs: noon, riseMs: nil, setMs: nil, riseMinutes: nil, setMinutes: nil, dayMinutes: 1440)
    }
    if cosH >= 1 {
      return Times(kind: .polarNight, noonMs: noon, riseMs: nil, setMs: nil, riseMinutes: nil, setMinutes: nil, dayMinutes: 0)
    }
    let halfDay = acos(cosH) / deg / 15 * 3600000
    let rise = noon - halfDay, set = noon + halfDay
    return Times(kind: .normal, noonMs: noon, riseMs: rise, setMs: set,
                 riseMinutes: (rise - midnight) / 60000, setMinutes: (set - midnight) / 60000,
                 dayMinutes: (set - rise) / 60000)
  }

  /// The lit parts of a 24-hour strip as 0...1 spans, drawn a day either side
  /// so a sunset past midnight lights the start of the bar too.
  public static func litSpans(_ times: Times?) -> [Span] {
    guard let times else { return [] }
    switch times.kind {
    case .polarNight: return []
    case .midnightSun: return [Span(x0: 0, x1: 1)]
    case .normal:
      guard let rise = times.riseMinutes, let set = times.setMinutes else { return [] }
      var out: [Span] = []
      for shift in [-1440.0, 0, 1440] {
        let a = max(0, min(1440, rise + shift)), b = max(0, min(1440, set + shift))
        if b > a { out.append(Span(x0: a / 1440, x1: b / 1440)) }
      }
      return out
    }
  }

  /// Where an event's tick goes, or nil when it falls off this bar.
  public static func eventMark(_ minutes: Double?) -> Double? {
    guard let minutes, minutes >= 0, minutes <= 1440 else { return nil }
    return minutes / 1440
  }

  /// Daylight at `minutes`, read from the same three days litSpans draws.
  public static func litAt(_ times: Times?, minutes: Double) -> Bool {
    guard let times else { return false }
    switch times.kind {
    case .midnightSun: return true
    case .polarNight: return false
    case .normal:
      guard let rise = times.riseMinutes, let set = times.setMinutes else { return false }
      return [-1440.0, 0, 1440].contains { minutes >= rise + $0 && minutes < set + $0 }
    }
  }
}

/// A line of text laid along a shallow circular arc.
public enum Arc {
  public struct Glyph: Equatable, Sendable {
    public var x: Double
    public var y: Double
    /// Degrees, about the glyph box's centre.
    public var rotation: Double
  }

  public struct Layout: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var chars: [Glyph]
  }

  /// `widths` are character advances; `rise` is how far the ends sit from the
  /// middle; `smile` bends the ends up. Each glyph is its box's top-left.
  public static func layout(_ widths: [Double], rise: Double, smile: Bool = false) -> Layout {
    let total = widths.reduce(0, +)
    if total <= 0 || rise <= 0 {
      var x = 0.0
      var chars: [Glyph] = []
      for w in widths {
        chars.append(Glyph(x: x, y: 0, rotation: 0))
        x += w
      }
      return Layout(width: total, height: 0, chars: chars)
    }
    let sag = min(rise, total / 4)
    let radius = total * total / (8 * sag)
    let halfAngle = total / (2 * radius)
    let maxDrop = radius * (1 - cos(halfAngle))
    let chord = 2 * radius * sin(halfAngle)

    var chars: [Glyph] = []
    var travelled = 0.0
    var left = 0.0, right = chord
    for w in widths {
      let a = (travelled + w / 2 - total / 2) / radius
      let drop = radius * (1 - cos(a))
      let x = chord / 2 + radius * sin(a) - w / 2
      chars.append(Glyph(x: x, y: smile ? maxDrop - drop : drop, rotation: (smile ? -a : a) * 180 / Double.pi))
      left = min(left, x)
      right = max(right, x + w)
      travelled += w
    }
    for i in chars.indices { chars[i].x -= left }
    return Layout(width: right - left, height: maxDrop, chars: chars)
  }
}
