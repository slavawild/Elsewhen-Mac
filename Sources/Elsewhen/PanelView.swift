import AppKit
import ElsewhenCore
import SwiftUI

struct HeroFrameKey: PreferenceKey {
  static let defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if next != .zero { value = next }
  }
}

struct StageFrameKey: PreferenceKey {
  static let defaultValue: CGRect = .zero
  static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
    let next = nextValue()
    if next != .zero { value = next }
  }
}

struct HeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ListHeightKey: PreferenceKey {
  static let defaultValue: CGFloat = 0
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct RowHeightsKey: PreferenceKey {
  static let defaultValue: [Int: CGFloat] = [:]
  static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) { value.merge(nextValue()) { $1 } }
}

extension View {
  func reportFrame<K: PreferenceKey>(_ key: K.Type, in space: String) -> some View where K.Value == CGRect {
    background(GeometryReader { Color.clear.preference(key: key, value: $0.frame(in: .named(space))) })
  }
}

/// "World [globe] Clock" under an arched caption. The little globe is the door
/// into globe mode and, once the big globe has left it, the cross back out.
struct HeroView: View {
  var model: PanelModel
  var theme: Theme
  @State private var iconHovered = false

  static var iconSize: CGFloat { (Style.display * 1.3).rounded() }

  var body: some View {
    let zoom = model.zoom
    let focus = model.focusPlace
    VStack(spacing: 2) {
      HereCaption(model: model, clock: model.clock, theme: theme)

      HStack(spacing: 9) {
        titleWord(L10n.t("elsewhen.world", "World"))
        ZStack {
          MiniGlobe(spin: model.heroSpin, theme: theme, showMarker: focus != nil,
                    markerLat: focus?.lat ?? 0, markerLon: focus?.lon ?? 0)
            .equatable()
            .opacity(1 - model.bigGlobeOpacity)
          // The globe leans with the earth; the cross stays upright.
          Text("\u{00d7}")
            .font(Style.font((Self.iconSize * 0.8).rounded()))
            .foregroundColor((iconHovered ? theme.foreground : theme.dim).color)
            .rotationEffect(.degrees(-Solar.axialTilt))
            .opacity(max(0, min(1, (zoom - 0.2) / 0.35)))
        }
        .frame(width: Self.iconSize, height: Self.iconSize)
        .rotationEffect(.degrees(Solar.axialTilt))
        .reportFrame(HeroFrameKey.self, in: "panel")
        .contentShape(Circle())
        .onHover { inside in
          iconHovered = inside
          if inside && model.globeEnabled { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .onTapGesture {
          // Shift runs the whole transition at a third of the speed.
          model.setGlobeMode(!model.globeMode, slow: NSEvent.modifierFlags.contains(.shift))
        }
        titleWord(L10n.t("elsewhen.clock", "Clock"))
      }
    }
  }

  private func titleWord(_ text: String) -> some View {
    Text(text).font(Style.font(Style.title, .semibold)).foregroundColor(theme.foreground.color)
  }
}

/// "It's 10:28 AM here in Kyiv" on its arc: the one part of the hero that ticks.
struct HereCaption: View {
  var model: PanelModel
  var clock: Clock
  var theme: Theme

  var body: some View {
    // Away from home it brings the globe back; at home it asks where here is.
    let clickable = model.focusIndex >= 0 || (!model.localZone.isEmpty && !model.globeMode)
    ArcText(text: model.hereLine, rise: 6, size: Style.caption,
            color: (model.scrubMinutes != 0 ? theme.accent : theme.dim).color)
      .contentShape(Rectangle())
      .onTapGesture {
        guard clickable else { return }
        if model.focusIndex >= 0 { model.focusOn(-1) }
        else if model.hereSearch.active { model.stopSearch(.here) }
        else { model.startChoosingHere() }
      }
      .onHover { inside in if inside && clickable { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() } }
  }
}

/// The panel: the hero, then a stage shared by the list and the globe that
/// grows out of the little one.
struct PanelView: View {
  var model: PanelModel
  /// The snapshot renderer has no scroll view to draw.
  var scrollable = true
  @Environment(\.colorScheme) private var scheme

  @State private var contentHeight: CGFloat = 400
  @State private var listHeight: CGFloat = 0
  @State private var heroFrame: CGRect = .zero
  @State private var stageFrame: CGRect = .zero
  @State private var rowHeights: [Int: CGFloat] = [:]

  var body: some View {
    let theme = Theme.current(scheme)
    Group {
      if scrollable {
        ScrollViewReader { proxy in
          ScrollView(.vertical, showsIndicators: false) { content(theme) }
            .frame(height: min(max(contentHeight, 120), Style.panelMaxHeight))
            .onChange(of: model.scrollRequest) { _, request in
              guard let request else { return }
              withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(request.id, anchor: request.id == "top" ? .top : .bottom)
              }
            }
        }
      } else {
        content(theme)
      }
    }
    .frame(width: Style.panelWidth + 2 * Style.panelPadding)
    .background(theme.background.color)
    .onPreferenceChange(HeightKey.self) { contentHeight = $0 }
  }

  private func content(_ theme: Theme) -> some View {
    VStack(spacing: Style.panelGap) {
      HeroView(model: model, theme: theme).id("top")
      if model.hereSearch.active && model.zoom < 1 {
        CitySearchView(model: model, kind: .here, theme: theme, showButton: false,
                       placeholder: L10n.t("elsewhen.whereAreYou", "Where are you?"))
      }
      stage(theme)
    }
    .padding(Style.panelPadding)
    .coordinateSpace(name: "panel")
    .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
    .onPreferenceChange(HeroFrameKey.self) { heroFrame = $0 }
    .onPreferenceChange(StageFrameKey.self) { stageFrame = $0 }
  }

  // MARK: the stage

  private func stage(_ theme: Theme) -> some View {
    let zoom = model.zoom
    let width = Style.panelWidth
    // At rest the stage is just the list, at its own height.
    let stageHeight: CGFloat? = zoom == 0 ? nil : max(1, listHeight + (Style.globeStageHeight - listHeight) * zoom)
    return ZStack(alignment: .top) {
      list(theme, width: width, stageHeight: stageHeight)
      if model.globeEnabled && (model.globeMode || zoom > 0) { globe(theme, width: width) }
    }
    .frame(width: width, height: stageHeight, alignment: .top)
    .reportFrame(StageFrameKey.self, in: "panel")
  }

  /// Clipped, so knocked rows fall out of the panel; with room above and to
  /// the right for the round buttons that straddle each row's corner.
  private func list(_ theme: Theme, width: CGFloat, stageHeight: CGFloat?) -> some View {
    let knockFall = Double(listHeight) + 220
    let timeColumn = timeColumnWidth
    return VStack(spacing: Style.panelGap) {
      VStack(spacing: Style.rowGap) {
        ForEach(Array(model.zones.enumerated()), id: \.offset) { i, city in
          CityRowView(model: model, clock: model.clock, index: i, city: city, theme: theme,
                      timeColumnWidth: timeColumn, rowHeights: rowHeights, knockFall: knockFall)
            .background(GeometryReader { Color.clear.preference(key: RowHeightsKey.self, value: [i: $0.size.height]) })
            .id(city.key)
        }
      }
      .coordinateSpace(name: "list")
      .opacity(model.zoom < 1 ? 1 : 0)

      CitySearchView(model: model, kind: .add, theme: theme, hasCursor: model.addSelected)
        .id("add")
        .opacity(model.zoom < 1 ? 1 : 0)
        // Knocked aside last, after every row.
        .offset(x: Model.knockX(model.zones.count, model.zoom, throwX: 95),
                y: Model.knockY(model.zones.count, model.zoom, fall: knockFall))
    }
    .frame(width: width)
    .fixedSize(horizontal: false, vertical: true)
    .background(GeometryReader { Color.clear.preference(key: ListHeightKey.self, value: $0.size.height) })
    .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
    .onPreferenceChange(RowHeightsKey.self) { rowHeights = $0 }
    .padding(.top, 12)
    .padding(.trailing, 12)
    .frame(width: width + 12, height: stageHeight.map { $0 + 12 }, alignment: .topLeading)
    .clipped()
    .padding(.top, -12)
    .padding(.trailing, -12)
  }

  /// Scaled about the centre of its own disc, then carried from the little globe.
  private func globe(_ theme: Theme, width: CGFloat) -> some View {
    let zoom = model.zoom
    let height = Style.globeStageHeight
    let discCX = width / 2
    let discCY = (height - GlobeView.footerHeight - GlobeView.jumpHeight) / 2
    let discR = GlobeView.radius(width: width, height: height)
    let heroR = max(1, HeroView.iconSize / 2 - 1)
    let startScale = heroR / discR
    let scale = startScale + (1 - startScale) * zoom
    let heroX = heroFrame == .zero ? discCX : heroFrame.midX - stageFrame.minX
    let heroY = heroFrame == .zero ? 0 : heroFrame.midY - stageFrame.minY
    return GlobeView(model: model, globe: model.globe, theme: theme)
      .frame(width: width, height: height)
      .scaleEffect(scale, anchor: UnitPoint(x: discCX / width, y: discCY / height))
      .offset(x: (heroX - discCX) * (1 - zoom), y: (heroY - discCY) * (1 - zoom))
      .opacity(model.bigGlobeOpacity)
      .allowsHitTesting(zoom > 0.9)
  }

  /// The widest a row's time gets, so every row's weather lines up against one column.
  private var timeColumnWidth: CGFloat {
    let time = Style.width(Model.formatTime(ZoneParts(hour: 0, minute: 0), hour24: true, words: model.words),
                           NSFont.monospacedDigitSystemFont(ofSize: Style.heading, weight: .semibold))
    if model.hour24 { return time }
    let words = model.words
    let meridiem = words.pm.count > words.am.count ? words.pm : words.am
    return time + 4 + Style.width(meridiem, Style.nsFont(Style.caption))
  }
}
