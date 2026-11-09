import AppKit
import ElsewhenCore
import SwiftUI

/// One city: name, weather, the people there, date (or a local greeting on
/// hover) and the time, over its daylight strip. Drag the body to reorder,
/// click it to turn the globe there. Every toggle on the row flips the setting
/// for the whole list.
struct CityRowView: View {
  var model: PanelModel
  /// The second-by-second time: a tick redraws the rows, not the panel around them.
  var clock: Clock
  var index: Int
  var city: City
  var theme: Theme
  var timeColumnWidth: CGFloat
  /// Every row's height, for a drag across rows that are not all one height.
  var rowHeights: [Int: CGFloat]
  /// Far enough for the top row to fall past the whole list.
  var knockFall: Double

  @State private var hovered = false
  @State private var armed = false
  @State private var peopleText = ""
  @FocusState private var peopleFocused: Bool

  static let pad: CGFloat = 13
  static let stripGap: CGFloat = 9
  static let captionLine: CGFloat = {
    let font = Style.nsFont(Style.caption)
    return ceil(font.ascender - font.descender + font.leading)
  }()

  var dragged: Bool { model.dragIndex == index }
  var picked: Bool { model.focusIndex == index && !model.addSelected }
  var editingPeople: Bool { model.peopleEditIndex == index }
  var removable: Bool { model.zones.count > 1 }

  /// Lightest at midday, darkest at night, so the list dims into the small hours.
  func fill(_ row: ClockRow) -> Double {
    let phase: Double
    switch row.ready ? row.phase : .day {
    case .day: phase = 0.10
    case .night: phase = 0.035
    default: phase = 0.07
    }
    return picked ? 0.15 : hovered ? phase + 0.05 : phase
  }

  func ground(_ row: ClockRow) -> RGB { theme.background.mix(theme.foreground, fill(row)) }

  var body: some View {
    let zoom = model.zoom
    let row = model.clockRow(city)
    VStack(alignment: .leading, spacing: Self.stripGap) {
      HStack(alignment: .center, spacing: 16) {
        labels(row)
        Spacer(minLength: 0)
        timeBlock(row)
      }
      .contentShape(Rectangle())
      .gesture(reorder)
      .onHover { inside in
        if inside { (dragged ? NSCursor.closedHand : NSCursor.openHand).set() } else { NSCursor.arrow.set() }
      }

      DaylightStrip(model: model, row: row, city: city, hovered: hovered, theme: theme)
    }
    .padding(.horizontal, Style.rowPaddingX)
    .padding(.top, Self.pad - 2)
    .padding(.bottom, Self.pad)
    .background(RoundedRectangle(cornerRadius: Style.cornerRadius).fill(ground(row).color))
    .overlay(alignment: .topTrailing) { cornerButtons }
    .onHover { hovered = $0 }
    .scaleEffect(Model.knockShrink(index, zoom))
    .rotationEffect(.degrees(Model.knockTilt(index, zoom)))
    .offset(x: Model.knockX(index, zoom, throwX: 95),
            y: Model.knockY(index, zoom, fall: knockFall) + model.rowShift(index))
    // The dragged row follows the pointer one-to-one; the others ease aside.
    .animation(dragged || model.dragIndex < 0 ? nil : .easeOut(duration: 0.13), value: model.rowShift(index))
    .opacity(dragged ? 0.9 : 1)
    .zIndex(dragged ? 2 : (hovered || picked) ? 1 : 0)
  }

  // MARK: parts

  private func labels(_ row: ClockRow) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 7) {
        Text(city.label)
          .font(Style.font(Style.subtitle, .semibold))
          .foregroundColor(theme.foreground.color)
          .lineLimit(1)
          .truncationMode(.tail)
          .layoutPriority(0)
        Spacer(minLength: 0)
        let temp = model.tempLabel(city)
        if !temp.isEmpty {
          LinkText(text: temp, color: theme.dim, hover: theme.foreground) {
            model.toggleUnits()
          }
          .layoutPriority(1)
        }
        if let symbol = model.weatherSymbol(city) {
          Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: Style.caption))
            .foregroundColor(theme.dim.color)
            .layoutPriority(1)
        }
      }

      if !city.people.isEmpty && !editingPeople { people(ground(row)) }

      if editingPeople {
        TextField(L10n.t("elsewhen.peoplePlaceholder", "Names or @github handles, comma separated"), text: $peopleText)
          .textFieldStyle(.plain)
          .font(Style.font(Style.caption))
          .padding(.vertical, 3)
          .padding(.horizontal, 6)
          .background(RoundedRectangle(cornerRadius: 5).fill(theme.background.color))
          .focused($peopleFocused)
          .onSubmit { model.finishPeopleEdit(index, peopleText) }
          .onAppear {
            peopleText = Model.peopleText(city.people)
            Task { @MainActor in peopleFocused = true }
          }
          // Leaving the field keeps what was typed, the way Return does.
          .onChange(of: peopleFocused) { focused in
            if !focused && model.peopleEditIndex == index { model.finishPeopleEdit(index, peopleText) }
          }
      }

      // The date, and the greeting in its place while hovered, in one slot so
      // the row never changes size under the pointer.
      let greeting = Greetings.greeting(city.id, hour: row.ready ? row.hour : 0)
      let greet = row.ready && hovered
      ZStack(alignment: .leading) {
        HStack(spacing: 6) {
          caption(row.ready ? row.date : "\u{2026}", row.ready && !row.dayLabel.isEmpty ? theme.dim : theme.fainter)
            .lineLimit(1)
          if row.ready && !row.dayLabel.isEmpty {
            caption("\u{00b7}", theme.fainter)
            caption(row.dayLabel, theme.dim)
          }
        }
        .opacity(greet ? 0 : 1)
        HStack(spacing: 5) {
          // One line: the pronunciation gives way first, then the greeting itself.
          caption(greeting.text, theme.foreground)
            .lineLimit(1)
            .layoutPriority(1)
          if !greeting.roman.isEmpty {
            caption(greeting.roman, theme.fainter).lineLimit(1)
          }
        }
        .opacity(greet ? 1 : 0)
      }
      // One caption line tall whatever the script: Georgian or Thai would otherwise grow the row.
      .frame(height: Self.captionLine, alignment: .leading)
      .animation(.easeInOut(duration: 0.11), value: greet)
    }
  }

  private func people(_ ground: RGB) -> some View {
    let size = (Style.caption * 1.45).rounded()
    return HStack(spacing: 6) {
      // Overlapping, the way a group photo stands.
      HStack(spacing: -(Style.caption * 0.3).rounded()) {
        ForEach(Array(city.people.prefix(4).enumerated()), id: \.offset) { _, person in
          Avatar(name: Model.personName(person, profiles: model.profiles),
                 path: model.profiles[Model.personHandle(person)]?.avatar ?? "",
                 stamp: model.profileStamp, size: size, theme: theme, ground: ground)
        }
      }
      caption(city.people.map { Model.personName($0, profiles: model.profiles) }.joined(separator: ", "), theme.dim)
        .lineLimit(1)
        .truncationMode(.tail)
    }
  }

  private func timeBlock(_ row: ClockRow) -> some View {
    VStack(alignment: .trailing, spacing: 1) {
      // The hour is already the brightest thing on the row, so hover lifts the meridiem.
      HoverRow(action: { model.toggleHour24() }) { hot in
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          Text(row.ready ? row.time : "--:--")
            .font(Style.font(Style.heading, .semibold).monospacedDigit())
            .foregroundColor(theme.foreground.color)
          if !row.meridiem.isEmpty { caption(row.meridiem, hot ? theme.foreground : theme.dim) }
        }
      }
      if row.ready {
        HoverRow(action: { model.toggleOffsetMode() }) { hot in
          HStack(spacing: 5) {
            caption(row.abbr, hot ? theme.dim : theme.fainter)
            let offset = model.offsetText(row)
            if !offset.isEmpty { caption(offset, hot ? theme.foreground : theme.fainter) }
          }
        }
      }
    }
    .frame(minWidth: timeColumnWidth, alignment: .trailing)
    .fixedSize()
  }

  @ViewBuilder
  private var cornerButtons: some View {
    let size: CGFloat = 20
    let showPeople = !editingPeople && hovered
    HStack(spacing: 5) {
      if showPeople {
        CornerButton(symbol: "person.badge.plus", size: size, theme: theme, help: L10n.t("elsewhen.editPeople", "Who's here")) {
          model.startPeopleEdit(index)
        }
      }
      // The last city stays; removing it would leave no way back.
      if removable && hovered {
        CornerButton(symbol: "xmark", size: size, theme: theme, help: L10n.t("elsewhen.remove", "Remove")) {
          model.removeCityAt(index)
        }
      }
    }
    .offset(x: 4, y: -size / 2)
    .transition(.opacity)
    .animation(.easeInOut(duration: 0.12), value: hovered)
  }

  private func caption(_ text: String, _ color: RGB) -> Text {
    Text(text).font(Style.font(Style.caption)).foregroundColor(color.color)
  }

  // MARK: reorder
  // Measured in the list, which does not move: the row's own frame slides with
  // the drag and would feed the offset back into itself.

  private var reorder: some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named("list"))
      .onChanged { value in
        let dy = Double(value.translation.height)
        if !armed {
          // A few pixels of slack, so a click is never a reorder.
          if abs(dy) < 4 { return }
          armed = true
          let gap = Double(Style.rowGap)
          let pitches = model.zones.indices.map { Double(rowHeights[$0] ?? 60) + gap }
          model.beginRowDrag(index, pitch: pitches[index], pitches: pitches)
        }
        model.moveRowDrag(dy)
      }
      .onEnded { _ in
        if armed { model.releaseRowDrag() } else { model.focusOn(index) }
        armed = false
      }
  }
}

/// Text that flips a setting when clicked, brightening under the pointer.
struct LinkText: View {
  var text: String
  var color: RGB
  var hover: RGB
  var action: () -> Void
  @State private var hot = false

  var body: some View {
    Text(text)
      .font(Style.font(Style.caption))
      .foregroundColor((hot ? hover : color).color)
      .onHover { inside in
        hot = inside
        if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
      }
      .onTapGesture(perform: action)
  }
}

/// A row of text that is one click target, telling its content when it is hovered.
struct HoverRow<Content: View>: View {
  var action: () -> Void
  @ViewBuilder var content: (Bool) -> Content
  @State private var hot = false

  var body: some View {
    content(hot)
      .contentShape(Rectangle())
      .onHover { inside in
        hot = inside
        if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
      }
      .onTapGesture(perform: action)
  }
}

/// The small round buttons that straddle a row's top-right corner.
struct CornerButton: View {
  var symbol: String
  var size: CGFloat
  var theme: Theme
  var help: String
  var action: () -> Void
  @State private var hot = false

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: size * 0.48, weight: .semibold))
        .foregroundColor((hot ? theme.foreground : theme.dim).color)
        .frame(width: size, height: size)
        .background(Circle().fill(theme.background.mix(theme.foreground, hot ? 0.24 : 0.14).color))
        .overlay(Circle().stroke(theme.background.mix(theme.foreground, hot ? 0.65 : 0.35).color, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .help(help)
    .onHover { hot = $0 }
  }
}
