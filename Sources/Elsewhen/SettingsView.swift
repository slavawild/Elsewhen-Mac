import ElsewhenCore
import SwiftUI

/// What Omarchy keeps on the widget's shell.json entry, as a window.
struct SettingsView: View {
  @ObservedObject var model: PanelModel

  private var timeFormat: Binding<Int> {
    Binding(
      get: { model.hour24Setting.map { $0 ? 24 : 12 } ?? 0 },
      set: { model.hour24Setting = $0 == 0 ? nil : $0 == 24 }
    )
  }

  private var launchAtLogin: Binding<Bool> {
    Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 })
  }

  var body: some View {
    Form {
      Picker(L10n.t("mac.timeFormat", "Time format"), selection: timeFormat) {
        Text(L10n.t("mac.followSystem", "Follow the system")).tag(0)
        Text(L10n.t("mac.hour12", "12-hour")).tag(12)
        Text(L10n.t("mac.hour24", "24-hour")).tag(24)
      }
      Picker(L10n.t("mac.offsets", "Row offsets"), selection: $model.offsetMode) {
        Text(L10n.t("mac.offsetHome", "Distance from here (+2h)")).tag(OffsetMode.home)
        Text(L10n.t("mac.offsetUTC", "From UTC (UTC-5)")).tag(OffsetMode.utc)
      }
      Picker(L10n.t("mac.units", "Temperature"), selection: $model.unitsSetting) {
        Text(L10n.t("mac.followSystem", "Follow the system")).tag("")
        Text("°C").tag("C")
        Text("°F").tag("F")
      }
      Toggle(L10n.t("mac.globeEnabled", "Globe mode (click the hero globe)"), isOn: $model.globeEnabled)
      Toggle(L10n.t("mac.smoothMotion", "Drop labels and detail while the globe moves"), isOn: $model.smoothMotion)
      Toggle(L10n.t("mac.launchAtLogin", "Open at login"), isOn: launchAtLogin)

      Section(L10n.t("mac.keysTitle", "Keys")) {
        Text(L10n.t("mac.keys", "Space: globe · ↑↓: pick a city · ←→: move the clocks an hour · +: add or jump · W: where you are · P: who's here · T: 12/24h · ⌥T: °C/°F · ⌫: remove · R: refresh · Esc: back"))
          .font(.callout)
          .foregroundColor(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .formStyle(.grouped)
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
  }
}
