import AppKit
import ElsewhenCore
import SwiftUI

/// A city's 24 hours, midnight to midnight: its real daylight lit, a marker at
/// now (the sun by day, tonight's moon by night), and sunrise and sunset arrows
/// while the row is hovered. Dragging along it scrubs every clock.
struct DaylightStrip: View {
  @ObservedObject var model: PanelModel
  var row: ClockRow
  var city: City
  var hovered: Bool
  var theme: Theme

  @State private var shownChip = -1
  @State private var showing = false
  @State private var scrubbing = false

  static let height: CGFloat = 18
  static let track: CGFloat = 3
  static let marker: CGFloat = 10

  struct Mark {
    var x: Double
    var minutes: Double
    var rising: Bool
    var label: String
  }

  /// Keyed to local midnight, so the sun is worked out once a day.
  var sun: Sun.Times? {
    guard row.ready, let place = model.placeOf(city), let lat = place.lat, let lon = place.lon else { return nil }
    let midnight = Sun.localMidnightMs(model.effectiveMs, offsetMinutes: row.offsetMinutes)
    return Sun.sunTimes(lat: lat, lon: lon, ms: midnight + 43_200_000, offsetMinutes: row.offsetMinutes)
  }

  var body: some View {
    let sun = self.sun
    let spans = sun.map { Sun.litSpans($0) } ?? [Sun.Span(x0: Model.daylightStart, x1: Model.daylightEnd)]
    // Read from the band that is drawn, so the sun never sits in the dark.
    let litNow = sun.map { Sun.litAt($0, minutes: row.progress * 1440) } ?? (row.ready && row.lit)
    let marks = Self.marks(sun)

    GeometryReader { geo in
      let w = geo.size.width
      let markerX = (w * CGFloat(row.ready ? row.progress : 0)).rounded()
      ZStack(alignment: .topLeading) {
        if row.ready {
          Capsule().fill(theme.foreground.color(0.10))
            .frame(width: w, height: Self.track)
            .offset(y: (Self.height - Self.track) / 2)
          ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
            Capsule().fill(theme.foreground.color(0.28))
              .frame(width: max(1, w * CGFloat(span.x1 - span.x0)), height: Self.track)
              .offset(x: w * CGFloat(span.x0), y: (Self.height - Self.track) / 2)
          }
          SunOrMoon(lit: litNow, phase: model.moonPhase, theme: theme)
            .frame(width: Self.marker, height: Self.marker)
            .offset(x: markerX - Self.marker / 2, y: (Self.height - Self.marker) / 2)
            .animation(scrubbing ? nil : .easeOut(duration: 0.4), value: markerX)
        }
      }
      .frame(width: w, height: Self.height, alignment: .topLeading)
      .contentShape(Rectangle())
      .gesture(scrub(width: w, markerX: markerX, litNow: litNow))
      .onHover { inside in if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() } }
      .overlay(alignment: .topLeading) {
        ForEach(Array(marks.enumerated()), id: \.offset) { i, mark in
          arrow(i, mark, width: w, markerX: markerX)
        }
      }
    }
    .frame(height: Self.height)
    .onChange(of: hovered) { if !$0 { shownChip = -1 } }
  }

  // Scrub, or Shift-click the moon to run its phase show.
  private func scrub(width: CGFloat, markerX: CGFloat, litNow: Bool) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard row.ready, width > 0 else { return }
        let fraction = Double(value.location.x / width)
        if !scrubbing && !showing {
          shownChip = -1
          let onMoon = !litNow && abs(value.startLocation.x - markerX) <= Self.marker
          if NSEvent.modifierFlags.contains(.shift) && onMoon {
            showing = true
            model.startMoonShow()
            return
          }
          scrubbing = true
          model.beginScrub(row, fraction)
        } else if scrubbing {
          model.scrubTo(row, fraction)
        }
      }
      .onEnded { _ in
        if scrubbing { model.endScrub() }
        scrubbing = false
        showing = false
      }
  }

  // Sunrise and sunset, just outside the lit band they point at.
  @ViewBuilder
  private func arrow(_ i: Int, _ mark: Mark, width: CGFloat, markerX: CGFloat) -> some View {
    let boxW: CGFloat = 14, boxH: CGFloat = 16
    let x = CGFloat(Model.arrowBox(mark.x, barWidth: Double(width), boxWidth: Double(boxW), tuck: 3, rising: mark.rising))
    // Hidden while the now marker stands on it.
    let covered = row.ready && Model.arrowCovered(Double(x), boxWidth: Double(boxW), markerCenter: Double(markerX),
                                                   markerWidth: Double(Self.marker), slack: 4)
    let visible = hovered && !covered
    Text(mark.rising ? "\u{2191}" : "\u{2193}")
      .font(Style.font(Style.caption))
      .foregroundColor(shownChip == i ? theme.foreground.color : theme.fainter.color)
      .frame(width: boxW, height: boxH)
      .contentShape(Rectangle())
      .offset(x: x, y: (Self.height - boxH) / 2 + (mark.rising ? -2 : 2))
      .opacity(visible ? 1 : 0)
      .allowsHitTesting(visible)
      .animation(.easeInOut(duration: 0.16), value: visible)
      .onTapGesture { shownChip = shownChip == i ? -1 : i }
      .overlay(alignment: .topLeading) {
        if shownChip == i && visible {
          Text(Words.fill(mark.label, Model.formatMinuteOfDay(mark.minutes, hour24: model.hour24, words: model.words)))
            .font(Style.font(Style.caption))
            .foregroundColor(theme.foreground.color)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(theme.background.mix(theme.foreground, 0.18).color))
            .offset(x: min(max(0, x - 30), max(0, width - 110)), y: -22)
            .allowsHitTesting(false)
        }
      }
  }

  /// Empty in polar day and night, when the sun does not cross the horizon.
  static func marks(_ sun: Sun.Times?) -> [Mark] {
    guard let sun, sun.kind == .normal else { return [] }
    var out: [Mark] = []
    if let up = Sun.eventMark(sun.riseMinutes) {
      out.append(Mark(x: up, minutes: sun.riseMinutes!, rising: true, label: L10n.t("elsewhen.sunriseAt", "Sunrise %1")))
    }
    if let down = Sun.eventMark(sun.setMinutes) {
      out.append(Mark(x: down, minutes: sun.setMinutes!, rising: false, label: L10n.t("elsewhen.sunsetAt", "Sunset %1")))
    }
    return out
  }
}
