import Foundation

/// A point on the disc, its centre at the origin and y pointing down.
public struct DiscPoint: Equatable, Sendable {
  public var x: Double
  public var y: Double

  public init(x: Double, y: Double) {
    self.x = x
    self.y = y
  }
}

public struct Projected: Sendable {
  public var x: Double
  public var y: Double
  public var visible: Bool
  public var cosc: Double

  public var point: DiscPoint { DiscPoint(x: x, y: y) }
}

/// A latitude and longitude in degrees.
public struct LatLon: Equatable, Sendable {
  public var lat: Double
  public var lon: Double

  public init(lat: Double, lon: Double) {
    self.lat = lat
    self.lon = lon
  }
}

/// A coastline ring as flat [lon, lat, lon, lat, ...], as world.json stores it.
public typealias Ring = [Double]

/// Orthographic globe math: projection, the day/night terminator, the moon, and label placement.
public enum Solar {
  static let deg = Double.pi / 180

  /// Earth's obliquity, also the hero globe's lean.
  public static let axialTilt = 23.44

  /// Every `keepEvery`th vertex of a ring, for drawing while the globe is small.
  public static func decimateRing(_ ring: Ring, keepEvery: Int = 2, minPoints: Int = 8) -> Ring {
    let n = ring.count / 2
    if keepEvery < 2 || n <= minPoints { return ring }
    var out: Ring = []
    var i = 0
    while i < n {
      out.append(ring[i * 2]); out.append(ring[i * 2 + 1])
      i += keepEvery
    }
    // End on the original last vertex, not a chord back to the start.
    let last = (n - 1) * 2
    if out[out.count - 2] != ring[last] || out[out.count - 1] != ring[last + 1] {
      out.append(ring[last]); out.append(ring[last + 1])
    }
    return out
  }

  /// Orthographic projection onto a disc of radius r seen from over (viewLat, spin).
  public static func project(_ lat: Double, _ lon: Double, spin: Double, viewLat: Double, r: Double) -> Projected {
    let phi = lat * deg, lam = (lon - spin) * deg, p0 = viewLat * deg
    let cosc = sin(p0) * sin(phi) + cos(p0) * cos(phi) * cos(lam)
    return Projected(
      x: r * cos(phi) * sin(lam),
      y: -r * (cos(p0) * sin(phi) - sin(p0) * cos(phi) * cos(lam)),
      visible: cosc > 0,
      cosc: cosc
    )
  }

  /// The point with the sun directly overhead, good to a fraction of a degree.
  public static func subsolarPoint(_ ms: Double) -> LatLon {
    let jd = ms / 86400000 + 2440587.5
    let n = jd - 2451545.0
    let L = (280.460 + 0.9856474 * n).truncatingRemainder(dividingBy: 360)
    let g = ((357.528 + 0.9856003 * n).truncatingRemainder(dividingBy: 360)) * deg
    let lambda = (L + 1.915 * sin(g) + 0.020 * sin(2 * g)) * deg
    let eps = (axialTilt - 0.0000004 * n) * deg

    let decl = asin(sin(eps) * sin(lambda)) / deg
    let alpha = atan2(cos(eps) * sin(lambda), cos(lambda)) / deg
    let eot = (L - alpha + 540).truncatingRemainder(dividingBy: 360) - 180
    let dayMs = ms.truncatingRemainder(dividingBy: 86400000)
    let utcHours = (dayMs < 0 ? dayMs + 86400000 : dayMs) / 3600000
    var lon = -15 * (utcHours - 12) - eot
    lon = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
    return LatLon(lat: decl, lon: lon)
  }

  /// Degrees above the horizon, negative below it.
  public static func solarElevation(_ lat: Double, _ lon: Double, _ sub: LatLon) -> Double {
    let cosz = sin(lat * deg) * sin(sub.lat * deg) + cos(lat * deg) * cos(sub.lat * deg) * cos((lon - sub.lon) * deg)
    return asin(max(-1, min(1, cosz))) / deg
  }

  /// -0.833 allows for refraction and the sun's disc, as sunrise tables do.
  public static func isDaylight(_ lat: Double, _ lon: Double, _ sub: LatLon) -> Bool {
    solarElevation(lat, lon, sub) > -0.833
  }

  /// The great circle 90 degrees from the subsolar point: the day/night line.
  public static func terminator(_ sub: LatLon, steps: Int = 180) -> [LatLon] {
    let slat = sub.lat * deg, slon = sub.lon * deg
    let s = [cos(slat) * cos(slon), cos(slat) * sin(slon), sin(slat)]
    let up: [Double] = abs(s[2]) < 0.9 ? [0, 0, 1] : [1, 0, 0]
    let a = norm(cross(up, s))
    let b = norm(cross(s, a))
    return (0...steps).map { i in
      let t = Double(i) / Double(steps) * 2 * Double.pi
      let v = (0..<3).map { a[$0] * cos(t) + b[$0] * sin(t) }
      return LatLon(lat: asin(v[2]) / deg, lon: atan2(v[1], v[0]) / deg)
    }
  }

  static func cross(_ u: [Double], _ v: [Double]) -> [Double] {
    [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]]
  }

  static func norm(_ v: [Double]) -> [Double] {
    let m = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot()
    let d = m == 0 ? 1 : m
    return v.map { $0 / d }
  }

  /// A candidate for a dot on the globe.
  public struct Plot: Sendable {
    public var index: Int
    public var x: Double
    public var y: Double
    public var cosc: Double
    public var rank: Int
    public var keep: Bool

    public init(index: Int, x: Double, y: Double, cosc: Double, rank: Int, keep: Bool) {
      self.index = index
      self.x = x
      self.y = y
      self.cosc = cosc
      self.rank = rank
      self.keep = keep
    }
  }

  /// Keep points, in priority order, that clear every kept point by minDist. `keep` always survives.
  public static func declutter(_ points: [Plot], minDist: Double) -> [Plot] {
    var kept: [Plot] = []
    for p in points {
      if p.keep || !kept.contains(where: { hypot(p.x - $0.x, p.y - $0.y) < minDist }) { kept.append(p) }
    }
    return kept
  }

  // ---- the moon

  public static let synodicMonth = 29.530588853
  static let knownNewMoonJD = 2451550.1

  /// Position through the lunation: 0 new, 0.25 first quarter, 0.5 full, 0.75 last quarter.
  public static func moonPhase(_ ms: Double) -> Double {
    let jd = ms / 86400000 + 2440587.5
    let p = ((jd - knownNewMoonJD) / synodicMonth).truncatingRemainder(dividingBy: 1)
    return p < 0 ? p + 1 : p
  }

  /// The lit part of the moon on a disc of radius r at the origin.
  public static func moonLitOutline(_ phase: Double, r: Double, steps: Int = 24) -> [DiscPoint] {
    let squash = cos(2 * Double.pi * phase)
    let side: Double = phase > 0.5 ? -1 : 1
    var out: [DiscPoint] = []
    for i in 0...steps {
      let t = Double.pi * Double(i) / Double(steps)
      out.append(DiscPoint(x: side * r * sin(t), y: -r * cos(t)))
    }
    for i in stride(from: steps, through: 0, by: -1) {
      let t = Double.pi * Double(i) / Double(steps)
      out.append(DiscPoint(x: side * r * squash * sin(t), y: -r * cos(t)))
    }
    return out
  }

  // ---- clipping to the disc

  /// Where a segment crosses the horizon, by bisection.
  public static func limbCrossing(_ a: LatLon, _ b: LatLon, spin: Double, viewLat: Double, r: Double) -> Projected? {
    // Segments spanning the antimeridian cannot be interpolated in lat/lon.
    if abs(b.lon - a.lon) > 180 { return nil }
    var lo = 0.0, hi = 1.0
    for _ in 0..<8 {
      let m = (lo + hi) / 2
      let p = project(a.lat + (b.lat - a.lat) * m, a.lon + (b.lon - a.lon) * m, spin: spin, viewLat: viewLat, r: r)
      if p.visible { lo = m } else { hi = m }
    }
    return project(a.lat + (b.lat - a.lat) * lo, a.lon + (b.lon - a.lon) * lo, spin: spin, viewLat: viewLat, r: r)
  }

  /// The near-side runs of a polyline, each ending exactly on the horizon.
  public static func visibleSegments(_ pts: [LatLon], spin: Double, viewLat: Double, r: Double) -> [[DiscPoint]] {
    var out: [[DiscPoint]] = []
    var run: [DiscPoint] = []
    var prev: LatLon?
    var prevVisible = false
    for pt in pts {
      let p = project(pt.lat, pt.lon, spin: spin, viewLat: viewLat, r: r)
      if p.visible {
        if run.isEmpty, let prev, !prevVisible, let enter = limbCrossing(pt, prev, spin: spin, viewLat: viewLat, r: r) {
          run.append(enter.point)
        }
        run.append(p.point)
      } else {
        if !run.isEmpty, let prev, let exit = limbCrossing(prev, pt, spin: spin, viewLat: viewLat, r: r) {
          run.append(exit.point)
        }
        if run.count > 1 { out.append(run) }
        run = []
      }
      prev = pt
      prevVisible = p.visible
    }
    if run.count > 1 { out.append(run) }
    return out
  }

  /// A ring clipped to the visible hemisphere as one polygon that follows the
  /// limb, so its area changes smoothly as the globe turns.
  public static func clipRingToDisc(_ ring: Ring, spin: Double, viewLat: Double, r: Double) -> [DiscPoint] {
    var pts: [LatLon] = []
    pts.reserveCapacity(ring.count / 2)
    var k = 0
    while k + 1 < ring.count {
      pts.append(LatLon(lat: ring[k + 1], lon: ring[k]))
      k += 2
    }
    if pts.isEmpty { return [] }
    let projected = pts.map { project($0.lat, $0.lon, spin: spin, viewLat: viewLat, r: r) }
    var out: [(p: DiscPoint, limb: Bool)] = []
    for i in 0..<pts.count {
      let j = (i + 1) % pts.count
      let pa = projected[i], pb = projected[j]
      if pa.visible && pb.visible {
        out.append((pb.point, false))
      } else if pa.visible {
        if let ex = limbCrossing(pts[i], pts[j], spin: spin, viewLat: viewLat, r: r) { out.append((ex.point, true)) }
      } else if pb.visible {
        if let en = limbCrossing(pts[j], pts[i], spin: spin, viewLat: viewLat, r: r) { out.append((en.point, true)) }
        out.append((pb.point, false))
      }
    }
    if out.count < 3 { return [] }

    var res: [DiscPoint] = []
    for j in 0..<out.count {
      res.append(out[j].p)
      let next = out[(j + 1) % out.count]
      if !out[j].limb || !next.limb { continue }
      let a0 = atan2(out[j].p.y, out[j].p.x)
      let a1 = atan2(next.p.y, next.p.x)
      var d = a1 - a0
      while d > Double.pi { d -= 2 * Double.pi }
      while d < -Double.pi { d += 2 * Double.pi }
      let steps = max(1, Int((abs(d) / 0.15).rounded()))
      if steps > 1 {
        for t in 1..<steps {
          let a = a0 + d * Double(t) / Double(steps)
          res.append(DiscPoint(x: r * cos(a), y: r * sin(a)))
        }
      }
    }
    return res
  }

  /// A label candidate and, once placed, its box.
  public struct LabelCandidate: Sendable {
    public var index: Int
    public var width: Double
    public var x: Double
    public var y: Double
    public var rank: Int
    public var cosc: Double

    public init(index: Int, width: Double, x: Double, y: Double, rank: Int, cosc: Double) {
      self.index = index
      self.width = width
      self.x = x
      self.y = y
      self.rank = rank
      self.cosc = cosc
    }
  }

  public struct Box: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public func contains(_ px: Double, _ py: Double, pad: Double) -> Bool {
      px >= x - pad && px <= x + w + pad && py >= y - pad && py <= y + h + pad
    }
  }

  public struct PlacedLabel: Sendable {
    public var index: Int
    public var box: Box
  }

  /// Greedy label placement by rank, then nearest the disc centre; a label that
  /// would pass `maxX` flips to the left of its dot. `gap` is dot to name.
  public static func layoutLabels(_ candidates: [LabelCandidate], lineHeight: Double, limit: Int, maxX: Double?, gap: Double = 6) -> [PlacedLabel] {
    var placed: [PlacedLabel] = []
    let sorted = candidates.sorted { p, q in p.rank != q.rank ? p.rank < q.rank : q.cosc < p.cosc }
    for c in sorted {
      var x = c.x + gap
      if let maxX, x + c.width > maxX { x = c.x - gap - c.width }
      let box = Box(x: x, y: c.y - lineHeight / 2, w: c.width, h: lineHeight)
      let clash = placed.contains { o in
        box.x < o.box.x + o.box.w && box.x + box.w > o.box.x && box.y < o.box.y + o.box.h && box.y + box.h > o.box.y
      }
      if clash { continue }
      placed.append(PlacedLabel(index: c.index, box: box))
      if limit > 0 && placed.count >= limit { break }
    }
    return placed
  }

  /// Signed degrees in (-180, 180] to turn from one longitude to another.
  public static func shortestTurn(_ from: Double, _ to: Double) -> Double {
    let d = ((to - from).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    return d > 180 ? d - 360 : d
  }
}
