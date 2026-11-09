import AppKit
import ElsewhenCore
import SwiftUI

extension Path {
  /// A polyline of disc points around `center`, closed when asked.
  init(_ points: [DiscPoint], center: CGPoint, close: Bool = false) {
    self.init()
    guard let first = points.first else { return }
    move(to: CGPoint(x: center.x + first.x, y: center.y + first.y))
    for p in points.dropFirst() { addLine(to: CGPoint(x: center.x + p.x, y: center.y + p.y)) }
    if close { closeSubpath() }
  }

  mutating func addRuns(_ runs: [[DiscPoint]], center: CGPoint) {
    for run in runs { addPath(Path(run, center: center)) }
  }

  static func disc(_ center: CGPoint, _ r: CGFloat) -> Path {
    Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
  }
}

/// The night marker drawn as the moon's current phase. The faint full disc
/// keeps it findable at new moon; the lit part is filled solid on top.
struct MoonDot: View {
  var phase: Double
  var color: RGB

  var body: some View {
    Canvas { ctx, size in
      let r = min(size.width, size.height) / 2
      guard r > 0 else { return }
      let c = CGPoint(x: size.width / 2, y: size.height / 2)
      ctx.fill(.disc(c, r), with: .color(color.color(0.22)))
      let lit = Solar.moonLitOutline(phase, r: Double(r), steps: 28)
      if lit.count > 2 { ctx.fill(Path(lit, center: c, close: true), with: .color(color.color)) }
    }
  }
}

/// The sun by day, tonight's moon by night: one marker meaning one thing.
struct SunOrMoon: View {
  var lit: Bool
  var phase: Double
  var theme: Theme

  var body: some View {
    if lit {
      Circle().fill(theme.daylight.color)
    } else {
      MoonDot(phase: phase, color: theme.foreground)
    }
  }
}

/// A small drawn globe for where an icon would go. Drawn, not glyphed, so it
/// can spin: `spin` is the longitude facing the viewer; the view leans it.
struct MiniGlobe: View, Equatable {
  var spin: Double
  var theme: Theme
  var showMarker: Bool
  var markerLat: Double
  var markerLon: Double

  /// Major landmasses only; islands read as dirt on the lens.
  static let rings: [Ring] = GlobeData.land.filter { $0.count >= 40 }

  var body: some View {
    Canvas { ctx, size in
      let r = Double(min(size.width, size.height) / 2 - 1)
      guard r > 0 else { return }
      let c = CGPoint(x: size.width / 2, y: size.height / 2)
      let fg = theme.foreground
      let showLand = size.width >= 22

      // The ocean, opaque like the large globe.
      ctx.fill(.disc(c, r), with: .color(theme.background.mix(fg, 0.16).color))

      ctx.drawLayer { inner in
        inner.clip(to: .disc(c, r))

        // Graticule first, so the land sits on top of it.
        var grid = Path()
        for lon in [-90.0, 0] {
          let pts = stride(from: -90.0, through: 90, by: 6).map { LatLon(lat: $0, lon: lon) }
          grid.addRuns(Solar.visibleSegments(pts, spin: spin, viewLat: 0, r: r), center: c)
        }
        let equator = stride(from: -180.0, through: 180, by: 6).map { LatLon(lat: 0, lon: $0) }
        grid.addRuns(Solar.visibleSegments(equator, spin: spin, viewLat: 0, r: r), center: c)
        inner.stroke(grid, with: .color(fg.color(showLand ? 0.42 : 0.85)), lineWidth: max(1, r * 0.055))

        if showLand {
          var land = Path()
          for ring in Self.rings {
            let poly = Solar.clipRingToDisc(ring, spin: spin, viewLat: 0, r: r)
            if poly.count >= 3 { land.addPath(Path(poly, center: c, close: true)) }
          }
          inner.fill(land, with: .color(fg.color))
        }

        // "You are here", only while on the near side; edged so it does not dissolve into a continent.
        if showMarker {
          let mp = Solar.project(markerLat, markerLon, spin: spin, viewLat: 0, r: r)
          if mp.visible {
            let p = CGPoint(x: c.x + mp.x, y: c.y + mp.y)
            let mr = max(1.6, r * 0.13)
            inner.fill(.disc(p, mr), with: .color(theme.accent.color))
            inner.stroke(.disc(p, mr), with: .color(theme.background.color(0.5)), lineWidth: max(1, r * 0.04))
            inner.stroke(.disc(p, mr * 1.9), with: .color(theme.accent.color(0.65)), lineWidth: max(1, r * 0.045))
          }
        }
      }

      // The rim last, so nothing spills over it.
      ctx.stroke(.disc(c, r), with: .color(fg.color), lineWidth: max(1, r * 0.095))
    }
  }
}

/// One line of text arched over what sits below it, each character turned to
/// follow the curve. Scripts whose letters join, stack or run right to left
/// cannot be set a character at a time, so those lines are set flat.
struct ArcText: View {
  var text: String
  var rise: Double = 6
  var size: CGFloat = Style.caption
  var color: Color

  private static let complex = try! NSRegularExpression(
    pattern: "[\\u0300-\\u036F\\u0590-\\u08FF\\u0900-\\u0DFF\\u0E00-\\u0EFF\\u1000-\\u109F\\u1780-\\u17FF\\uFB1D-\\uFDFF\\uFE70-\\uFEFF]")

  var flat: Bool {
    Self.complex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  var body: some View {
    if flat {
      Text(text).font(Style.font(size)).foregroundColor(color).lineLimit(1).frame(maxWidth: .infinity)
    } else {
      let font = Style.nsFont(size)
      let glyphs = text.map(String.init)
      let widths = glyphs.map { Double(($0 as NSString).size(withAttributes: [.font: font]).width) }
      let placed = Arc.layout(widths, rise: rise)
      let line = ceil(font.ascender - font.descender + font.leading)
      GeometryReader { geo in
        let originX = (geo.size.width - CGFloat(placed.width)) / 2
        ZStack(alignment: .topLeading) {
          ForEach(Array(glyphs.enumerated()), id: \.offset) { i, glyph in
            let spot = placed.chars[i]
            Text(glyph)
              .font(Style.font(size))
              .foregroundColor(color)
              .fixedSize()
              .frame(width: CGFloat(widths[i]), height: line)
              .rotationEffect(.degrees(spot.rotation))
              .offset(x: originX + CGFloat(spot.x), y: CGFloat(spot.y))
          }
        }
        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
      }
      .frame(height: ceil(CGFloat(placed.height) + line))
    }
  }
}

/// One person on a row: their GitHub avatar when there is one, otherwise the
/// first letter of their name on a disc, edged in the row's own fill.
struct Avatar: View {
  var name: String
  var path: String
  var stamp: Double
  var size: CGFloat
  var theme: Theme
  var ground: RGB

  var body: some View {
    let edge = max(1, (size / 12).rounded())
    ZStack {
      Circle().fill(ground.color).frame(width: size + 2 * edge, height: size + 2 * edge)
      if let image = Self.image(path, stamp) {
        Image(nsImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
      } else {
        Circle().fill(ground.mix(theme.foreground, 0.28).color).frame(width: size, height: size)
        Text(Model.initialOf(name))
          .font(Style.font((size * 0.55).rounded(), .semibold))
          .foregroundColor(theme.foreground.color)
      }
    }
    .frame(width: size, height: size)
  }

  @MainActor private static var cache: [String: NSImage] = [:]

  @MainActor
  static func image(_ path: String, _ stamp: Double) -> NSImage? {
    if path.isEmpty { return nil }
    let key = path + "@\(stamp)"
    if let hit = cache[key] { return hit }
    guard let image = NSImage(contentsOfFile: path) else { return nil }
    cache[key] = image
    return image
  }
}
