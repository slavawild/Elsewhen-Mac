import AppKit
import ElsewhenCore
import SwiftUI

/// The panel drawn without a screen, from a fixed scene: one instant, one zone,
/// one locale and made-up weather, so two renders of the same code match
/// pixel for pixel. The snapshot tests compare these with reference images.
enum Snapshots {
  /// Saturday 29 August 2026, 10:40 UTC: 13:40 in Kyiv, night in Los Angeles, evening in Tokyo.
  static let nowMs = 1_788_000_000_000.0
  static let localZone = "Europe/Kyiv"

  static let cities = [
    City(label: "Kyiv", id: "Europe/Kyiv", lat: 50.45, lon: 30.52),
    City(label: "Los Angeles", id: "America/Los_Angeles", lat: 34.05, lon: -118.24, people: ["Emir", "@octocat"]),
    City(label: "Tbilisi", id: "Asia/Tbilisi", lat: 41.72, lon: 44.79),
    City(label: "Tokyo", id: "Asia/Tokyo", lat: 35.69, lon: 139.69),
    City(label: "Sydney", id: "Australia/Sydney", lat: -33.87, lon: 151.21)
  ]

  /// A model for the fixed scene: nothing saved, nothing fetched.
  @MainActor
  static func model(defaults: UserDefaults = UserDefaults(suiteName: "io.github.slavawild.Elsewhen.snapshots") ?? .standard) -> PanelModel {
    let model = PanelModel(defaults: defaults, persists: false, network: false,
                           localZone: localZone, locale: Locale(identifier: "en_US"))
    model.hour24Setting = false
    model.unitsSetting = "C"
    model.setZonesForPreview(cities)
    model.clock.nowMs = nowMs
    model.globe.sunMs = nowMs
    let weather: [(Double, Int)] = [(18.4, 2), (24.1, 0), (21.0, 1), (12.0, 3), (6.3, 61)]
    var facts: [String: Facts] = [:]
    for (i, city) in cities.enumerated() {
      facts[city.key] = Facts(lat: city.lat, lon: city.lon, celsius: weather[i].0, code: weather[i].1)
    }
    model.setFactsForPreview(facts)
    return model
  }

  /// The panel as a PNG: the list, or the globe fully open, in a light or dark appearance.
  @MainActor
  static func png(_ model: PanelModel, dark: Bool, globe: Bool, scale: CGFloat = 1) -> Data? {
    model.setZoomForPreview(globe ? 1 : 0)
    let view = PanelView(model: model, scrollable: false).environment(\.colorScheme, dark ? .dark : .light)
    let renderer = ImageRenderer(content: view)
    renderer.scale = scale
    guard let image = renderer.cgImage else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  }

  static let names: [(name: String, dark: Bool, globe: Bool)] = [
    ("list-light", false, false), ("list-dark", true, false), ("globe-light", false, true), ("globe-dark", true, true)
  ]

  /// `ELSEWHEN_SNAPSHOT_DIR=… Elsewhen.app/Contents/MacOS/Elsewhen` writes all four and quits.
  @MainActor
  static func render(to dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let model = model()
    for shot in names {
      try? png(model, dark: shot.dark, globe: shot.globe)?.write(to: dir.appendingPathComponent(shot.name + ".png"))
    }
  }
}
