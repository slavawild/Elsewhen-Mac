import AppKit
import ElsewhenCore
import SwiftUI

/// A spinnable orthographic globe: coastlines, the day/night terminator and
/// the major city of every zone, the selected city's time underneath, and a
/// box to jump anywhere.
struct GlobeView: View {
  var model: PanelModel
  var globe: GlobeState
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

        GlobeFooter(model: model, globe: globe, clock: model.clock, theme: theme)
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

  /// One city's dot, decided before drawing so the renderer reads plain values.
  struct Dot {
    var at: CGPoint
    var day: Bool
    var selected: Bool
    var home: Bool
    var tracked: Bool
  }

  struct Name {
    var text: String
    var at: CGPoint
    var strong: Bool
  }

  private func canvas(scene: GlobeScene, r: Double, reduced: Bool) -> some View {
    let fg = theme.foreground
    let theme = self.theme
    let sub = Solar.subsolarPoint(globe.sunMs)
    let cities = globe.allCities
    let selected = globe.selected
    let night = theme.background.color(0.92)
    // Coarse coastlines only while moving and small; the zoom's slow tail is near full size.
    let key = GlobeGeometry.Key(spin: globe.spin, viewLat: globe.viewLat, radius: r,
                                coarse: reduced && model.zoom < 0.5, gridStep: reduced ? 60 : 30, sunMs: globe.sunMs)
    let paths = globe.geometry.paths(key)
    let dots: [Dot] = scene.plotted.compactMap { p in
      guard p.index < cities.count else { return nil }
      return Dot(at: CGPoint(x: p.x, y: p.y), day: Solar.isDaylight(cities[p.index].lat, cities[p.index].lon, sub),
                 selected: p.index == selected, home: globe.isHome(p.index), tracked: globe.isTracked(p.index))
    }
    let names: [Name] = scene.labels.compactMap { label in
      guard label.index < cities.count else { return nil }
      return Name(text: cities[label.index].name, at: CGPoint(x: label.box.x, y: label.box.y + label.box.h / 2),
                  strong: globe.isHome(label.index) || globe.isTracked(label.index))
    }

    return Canvas { ctx, size in
      // Everything below is drawn about the disc's centre.
      ctx.translateBy(x: size.width / 2, y: size.height / 2)
      let o = CGPoint.zero

      // Ocean, mixed opaque against the background so the rows behind never show through.
      ctx.fill(.disc(o, r), with: .color(theme.background.mix(fg, 0.05).color))
      ctx.stroke(.disc(o, r), with: .color(fg.color(0.22)), lineWidth: 1)
      ctx.stroke(paths.grid, with: .color(fg.color(0.10)), lineWidth: 1)
      // Land, filled bright with no coastline stroke: the fill's own edge is the coast.
      ctx.fill(paths.land, with: .color(theme.background.mix(fg, 0.92).color))
      ctx.stroke(paths.terminator, with: .color(theme.daylight.color(0.55)), lineWidth: 1)

      // Cities: gold in daylight, dark at night, each edged in the opposite tone.
      for d in dots {
        let dot = Path.disc(d.at, d.selected ? 3.6 : 2.2)
        ctx.fill(dot, with: d.day ? .color(theme.daylight.color) : .color(night))
        ctx.stroke(dot, with: .color(d.day ? theme.background.color(0.7) : fg.color(0.85)), lineWidth: 1.2)
        if d.home {
          ctx.fill(.disc(d.at, 3.4), with: .color(theme.accent.color))
          ctx.stroke(.disc(d.at, 3.4), with: .color(theme.background.color(0.5)), lineWidth: 1.2)
          ctx.stroke(.disc(d.at, 6.4), with: .color(theme.accent.color(0.65)), lineWidth: 1.4)
        } else if d.tracked {
          ctx.stroke(.disc(d.at, 4.6), with: .color(theme.accent.color), lineWidth: 1.3)
        }
        if d.selected {
          ctx.stroke(.disc(d.at, 7.5), with: .color(d.day ? theme.daylight.color : fg.color), lineWidth: 1.4)
        }
      }

      // City names in two tones: light over the sea, then dark through a clip of the land.
      func draw(_ ink: RGB, _ layer: inout GraphicsContext) {
        for name in names {
          let text = Text(name.text)
            .font(Style.font(Style.caption, name.strong ? .bold : .regular))
            .foregroundColor(ink.color)
          layer.draw(text, at: name.at, anchor: .leading)
        }
      }
      if !names.isEmpty {
        ctx.drawLayer { layer in draw(fg, &layer) }
        ctx.drawLayer { layer in
          layer.clip(to: paths.land)
          draw(theme.background, &layer)
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
}

/// The selected city under the globe: name, local time and badge, then its
/// zone and offset. The one part of the globe that ticks every second.
struct GlobeFooter: View {
  var model: PanelModel
  var globe: GlobeState
  var clock: Clock
  var theme: Theme

  var body: some View {
    if let city = globe.selectedCity {
      let i = globe.selected
      let daylight = Solar.isDaylight(city.lat, city.lon, Solar.subsolarPoint(globe.sunMs))
      let offset = ZoneInfo.of(city.zone, atMs: clock.nowMs)?.offsetMinutes
      // Both offsets at the same instant, or a DST change between now and then reads as an hour apart.
      let home = model.localTimeZone.secondsFromGMT(for: Date(timeIntervalSince1970: clock.nowMs / 1000)) / 60
      VStack(spacing: 1) {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
          HStack(alignment: .firstTextBaseline, spacing: 4) {
            SunOrMoon(lit: daylight, phase: model.moonPhase, theme: theme)
              .frame(width: 8, height: 8)
            Text(city.name).font(Style.font(Style.caption, .semibold)).foregroundColor(theme.foreground.color)
          }
          Text(Model.formatClock(clock.nowMs, offsetMinutes: offset, hour24: model.hour24, words: model.words))
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
              : offset.map { Model.relativeOffsetLabel($0, home, words: model.words) } ?? ""
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
