import AppKit
import ElsewhenCore
import SwiftUI

/// A button that opens into a city search: a field, then the matching cities
/// with their zone and offset - the zone catalogue first, then the places the
/// geocoder knows. Arrows move the selection, Return picks it, Escape backs
/// out (the panel's key handler drives those while the field has the keyboard).
struct CitySearchView: View {
  @ObservedObject var model: PanelModel
  var kind: SearchKind
  var theme: Theme
  var showButton = true
  var inlineResults = true
  var buttonText = L10n.t("elsewhen.addCity", "+  Add a city")
  var placeholder = L10n.t("elsewhen.searchCities", "Search cities…")
  /// The panel's keyboard cursor is on the button.
  var hasCursor = false

  @FocusState private var focused: Bool

  static let fieldHeight: CGFloat = 28

  var body: some View {
    let state = model.search(kind)
    VStack(spacing: 8) {
      if state.active {
        TextField(placeholder, text: Binding(get: { model.search(kind).query }, set: { model.setQuery(kind, $0) }))
          .textFieldStyle(.plain)
          .font(Style.font(Style.bodySmall))
          .foregroundColor(theme.foreground.color)
          .padding(.horizontal, 10)
          .frame(height: Self.fieldHeight)
          .background(RoundedRectangle(cornerRadius: 7).fill(theme.background.mix(theme.foreground, 0.08).color))
          .overlay(RoundedRectangle(cornerRadius: 7).stroke(theme.accent.color(0.8), lineWidth: 1))
          .focused($focused)
          .onAppear { Task { @MainActor in focused = true } }
        if inlineResults { CityMatchesView(model: model, kind: kind, theme: theme) }
      } else if showButton {
        Button { model.startSearch(kind) } label: {
          Text(buttonText)
            .font(Style.font(Style.bodySmall))
            .foregroundColor(theme.foreground.color)
            .frame(maxWidth: .infinity)
            .frame(height: Self.fieldHeight)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 7).fill(hasCursor ? theme.background.mix(theme.foreground, 0.12).color : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7)
              .stroke((hasCursor ? theme.accent : theme.background.mix(theme.foreground, 0.25)).color, lineWidth: 1))
        }
        .buttonStyle(.plain)
      }
    }
  }
}

/// The matches for a search; hosts that overlay results place this themselves.
struct CityMatchesView: View {
  @ObservedObject var model: PanelModel
  var kind: SearchKind
  var theme: Theme

  var body: some View {
    let matches = model.matches(kind)
    let selected = model.search(kind).selectedIndex
    VStack(spacing: 2) {
      ForEach(Array(matches.enumerated()), id: \.element.id) { i, match in
        HStack(spacing: 8) {
          // The region is what tells Portland, Oregon from Portland, Maine.
          HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(match.label)
              .font(Style.font(Style.bodySmall))
              .foregroundColor(theme.foreground.color)
              .lineLimit(1)
              .layoutPriority(1)
            if let region = match.region, !region.isEmpty {
              Text(region).font(Style.font(Style.caption)).foregroundColor(theme.fainter.color).lineLimit(1)
            }
          }
          Spacer(minLength: 8)
          // Two cities in one zone differ by name, two zones with one name by offset.
          if match.region?.isEmpty ?? true {
            Text(match.value).font(Style.font(Style.caption)).foregroundColor(theme.fainter.color).lineLimit(1)
          }
          let offset = model.utcLabel(match.value)
          if !offset.isEmpty {
            Text(offset).font(Style.font(Style.caption)).foregroundColor(theme.dim.color).fixedSize()
          }
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6)
          .fill(i == selected ? theme.background.mix(theme.foreground, 0.12).color : .clear))
        .contentShape(Rectangle())
        // Only movement moves the selection, so a resting pointer cannot steal it from the arrows.
        .onContinuousHover { phase in
          if case .active = phase { model.hoverSearch(kind, i) }
        }
        .onTapGesture { model.pick(kind, match) }
      }
      if matches.isEmpty {
        Text(model.searching(kind) ? L10n.t("elsewhen.searchingPlaces", "Searching places…")
                                   : L10n.t("common.noMatches", "No matches"))
          .font(Style.font(Style.caption))
          .foregroundColor(theme.fainter.color)
          .frame(maxWidth: .infinity)
          .padding(.top, 8)
      }
    }
  }
}
