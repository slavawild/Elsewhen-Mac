import AppKit
import ElsewhenCore
import SwiftUI

/// A spinnable orthographic globe: coastlines, the day/night terminator and
/// the major city of every zone, the selected city's time underneath, and a
/// box to jump anywhere.
struct GlobeView: View {
  @ObservedObject var model: PanelModel
  @ObservedObject var globe: GlobeState
  var theme: Theme

  static let footerHeight: CGFloat = 34
  static let jumpHeight: CGFloat = 4 + CitySearchView.fieldHeight

  @State private var last: CGSize = .zero
  @State private var moved = false
  @State private var pressed = false

  static func radius(width: CGFloat, height: CGFloat) -> CGFloat {
    max(40, min(width, height - footerHeight - jumpHeight) / 2 - 6)
  }

  /// A moving globe is drawn with less in it: no names, a coarser graticule.
  var reduced: Bool {
    model.smoothMotion && (globe.moving || !model.zoomIdle)
  }

  var body: some View {
    GeometryReader { geo in
      let width = geo.size.width
      let canvasHeight = geo.size.height - Self.footerHeight - Self.jumpHeight
      let r = Double(Self.radius(width: width, height: geo.size.height))
      let reduced = self.reduced
      let scene = globe.scene(radius: r, width: Double(width), reduced: reduced)

      VStack(spacing: 0) {
        canvas(scene: scene, r: r, reduced: reduced)
          .frame(width: width, height: canvasHeight)
          .contentShape(Rectangle())
          .gesture(pointer(width: width, height: canvasHeight, r: r))

        footer
          .frame(height: Self.footerHeight)
          .opacity(model.chromeOpacity)
          .padding(.bottom, 4)

        CitySearchView(model: model, kind: .jump, theme: theme, inlineResults: false,
                       buttonText: L10n.t("elsewhen.jumpToCity", "Jump to a city"))
          .opacity(model.chromeOpacity)
      }
      // Results overlay the globe so it never resizes under the pointer mid-search.
      .overlay(alignment: .bottom) {
        if model.jumpSearch.active {
          CityMatchesView(model: model, kind: .jump, theme: theme)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: Style.cornerRadius).fill(theme.background.color))
            .padding(.bottom, Self.jumpHeight + 4)
        }
      }
    }
  }

  // MARK: the drawing

  private func canvas(scene: GlobeScene, r: Double, reduced: Bool) -> some View {
    let fg = theme.foreground
    let sub = Solar.subsolarPoint(model.nowMs)
    let spin = globe.spin, viewLat = globe.viewLat
    let cities = globe.allCities
    let selected = globe.selected
    let coarse = reduced && model.zoom < 0.5
    let night = theme.background.color(0.92)

    return Canvas { ctx, size in
      let c = CGPoint(x: size.width / 2, y: size.height / 2)

      // Ocean, mixed opaque against the background so the rows behind never show through.
      ctx.fill(.disc(c, r), with: .color(theme.background.mix(fg, 0.05).color))
      ctx.stroke(.disc(c, r), with: .color(fg.color(0.22)), lineWidth: 1)

      // Graticule every 30 degrees, or 60 while moving.
      let step = reduced ? 60.0 : 30.0
      var grid = Path()
      for lon in stride(from: -180.0, to: 180, by: step) {
        let pts = stride(from: -90.0, through: 90, by: 3).map { LatLon(lat: $0, lon: lon) }
        grid.addRuns(Solar.visibleSegments(pts, spin: spin, viewLat: viewLat, r: r), center: c)
      }
      for lat in stride(from: -60.0, through: 60, by: step) {
        let pts = stride(from: -180.0, through: 180, by: 3).map { LatLon(lat: lat, lon: $0) }
        grid.addRuns(Solar.visibleSegments(pts, spin: spin, viewLat: viewLat, r: r), center: c)
      }
      ctx.stroke(grid, with: .color(fg.color(0.10)), lineWidth: 1)

      // Land, filled bright with no coastline stroke: the fill's own edge is the coast.
      var land = Path()
      for ring in coarse ? GlobeData.landCoarse : GlobeData.land {
        let poly = Solar.clipRingToDisc(ring, spin: spin, viewLat: viewLat, r: r)
        if poly.count >= 3 { land.addPath(Path(poly, center: c, close: true)) }
      }
      ctx.fill(land, with: .color(theme.background.mix(fg, 0.92).color))

      // Day/night line.
      var term = Path()
      term.addRuns(Solar.visibleSegments(Solar.terminator(sub, steps: 180), spin: spin, viewLat: viewLat, r: r), center: c)
      ctx.stroke(term, with: .color(theme.daylight.color(0.55)), lineWidth: 1)

      // Cities: gold in daylight, dark at night, each edged in the opposite tone.
      for p in scene.plotted {
        let i = p.index
        guard i < cities.count else { continue }
        let at = CGPoint(x: c.x + p.x, y: c.y + p.y)
        let day = Solar.isDaylight(cities[i].lat, cities[i].lon, sub)
        let isSelected = i == selected
        let dot = Path.disc(at, isSelected ? 3.6 : 2.2)
        ctx.fill(dot, with: day ? .color(theme.daylight.color) : .color(night))
        ctx.stroke(dot, with: .color(day ? theme.background.color(0.7) : fg.color(0.85)), lineWidth: 1.2)
        if globe.isHome(i) {
          ctx.fill(.disc(at, 3.4), with: .color(theme.accent.color))
          ctx.stroke(.disc(at, 3.4), with: .color(theme.background.color(0.5)), lineWidth: 1.2)
          ctx.stroke(.disc(at, 6.4), with: .color(theme.accent.color(0.65)), lineWidth: 1.4)
        } else if globe.isTracked(i) {
          ctx.stroke(.disc(at, 4.6), with: .color(theme.accent.color), lineWidth: 1.3)
        }
        if isSelected {
          ctx.stroke(.disc(at, 7.5), with: .color(day ? theme.daylight.color : fg.color), lineWidth: 1.4)
        }
      }

      // City names in two tones: light over the sea, then dark through a clip of the land.
      func names(_ ink: RGB, _ layer: inout GraphicsContext) {
        for label in scene.labels where label.index < cities.count {
          let strong = globe.isHome(label.index) || globe.isTracked(label.index)
          let text = Text(cities[label.index].name)
            .font(Style.font(Style.caption, strong ? .bold : .regular))
            .foregroundColor(ink.color)
          layer.draw(text, at: CGPoint(x: c.x + label.box.x, y: c.y + label.box.y + label.box.h / 2), anchor: .leading)
        }
      }
      if !scene.labels.isEmpty {
        ctx.drawLayer { layer in names(fg, &layer) }
        ctx.drawLayer { layer in
          layer.clip(to: land)
          names(theme.background, &layer)
        }
      }
    }
  }

  // MARK: the pointer

  private func pointer(width: CGFloat, height: CGFloat, r: Double) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        if !pressed {
          pressed = true
          moved = false
          last = .zero
          globe.beginDrag()
        }
        let dx = value.translation.width - last.width, dy = value.translation.height - last.height
        if abs(value.translation.width) + abs(value.translation.height) > 2 { moved = true }
        globe.drag(dx: Double(dx), dy: Double(dy))
        last = value.translation
      }
      .onEnded { value in
        pressed = false
        globe.endDrag(moved: moved)
        if !moved {
          let x = Double(value.location.x - width / 2), y = Double(value.location.y - height / 2)
          globe.pick(at: x, y, scene: globe.scene(radius: r, width: Double(width), reduced: false))
        }
      }
  }

  // MARK: the footer
  // The selected city under the globe: name, local time and badge, then its zone and offset.

  @ViewBuilder
  private var footer: some View {
    if let city = globe.selectedCity {
      let i = globe.selected
      let daylight = Solar.isDaylight(city.lat, city.lon, Solar.subsolarPoint(model.nowMs))
      let offset = ZoneInfo.of(city.zone, atMs: model.nowMs)?.offsetMinutes
      VStack(spacing: 1) {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            SunOrMoon(lit: daylight, phase: model.moonPhase, theme: theme)
              .frame(width: 8, height: 8)
            Text(city.name).font(Style.font(Style.caption, .semibold)).foregroundColor(theme.foreground.color)
          }
          Text(Model.formatClock(model.nowMs, offsetMinutes: offset, hour24: model.hour24, words: model.words))
            .font(Style.font(Style.caption)).foregroundColor(theme.dim.color)
          let badge = globe.isHome(i) ? L10n.t("elsewhen.badgeHome", "home")
            : globe.isTracked(i) ? L10n.t("elsewhen.badgeTracked", "tracked") : ""
          if !badge.isEmpty {
            Text(badge).font(Style.font(Style.caption)).foregroundColor(theme.accent.color)
          }
        }
        // Zone and offset together are the toggle.
        HoverRow(action: { model.toggleOffsetMode() }) { hot in
          HStack(spacing: 6) {
            Text(city.zone).font(Style.font(Style.caption)).foregroundColor((hot ? theme.dim : theme.fainter).color)
            let label = model.offsetMode == .utc
              ? Model.utcOffsetLabel(offset, words: model.words)
              : offset.map { Model.relativeOffsetLabel($0, model.localTimeZone.secondsFromGMT() / 60, words: model.words) } ?? ""
            if !label.isEmpty {
              Text(label).font(Style.font(Style.caption)).foregroundColor((hot ? theme.foreground : theme.dim).color)
            }
          }
        }
      }
      .frame(maxWidth: .infinity)
    } else {
      Color.clear
    }
  }
}
