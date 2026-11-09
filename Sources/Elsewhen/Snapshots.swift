import AppKit
import ElsewhenCore
import SwiftUI

/// Renders the panel to PNGs without a screen, for CI: a list and a globe, in
/// dark and light. Nothing is fetched; the facts are filled in as if they had been.
enum Snapshots {
  @MainActor
  static func render(to dir: URL) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let model = PanelModel(defaults: UserDefaults(suiteName: "io.github.slavawild.Elsewhen.snapshots") ?? .standard, persists: false)
    let cities = [
      City(label: model.homeCity.isEmpty ? "New York" : model.homeCity, id: model.localZone),
      City(label: "Los Angeles", id: "America/Los_Angeles", lat: 34.05, lon: -118.24, people: ["Emir", "@octocat"]),
      City(label: "Kyiv", id: "Europe/Kyiv", lat: 50.45, lon: 30.52),
      City(label: "Tokyo", id: "Asia/Tokyo", lat: 35.69, lon: 139.69),
      City(label: "Sydney", id: "Australia/Sydney", lat: -33.87, lon: 151.21)
    ]
    model.setZonesForPreview(cities)
    var facts: [String: Facts] = [:]
    let weather: [(Double, Int)] = [(18.4, 2), (24.1, 0), (6.3, 61), (12.0, 3), (21.7, 1)]
    let home = GlobeData.cities.first { $0.zone == model.localZone }
    for (i, city) in cities.enumerated() {
      facts[city.key] = Facts(lat: city.lat ?? home?.lat ?? 40.71, lon: city.lon ?? home?.lon ?? -74.0,
                              celsius: weather[i].0, code: weather[i].1)
    }
    if let here = model.hereZone { facts[here.city.key] = facts[cities[0].key] }
    model.setFactsForPreview(facts)

    for scheme in [ColorScheme.dark, .light] {
      for globe in [false, true] {
        model.setZoomForPreview(globe ? 1 : 0)
        let view = PanelView(model: model, scrollable: false).environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
        let name = "\(globe ? "globe" : "list")-\(scheme == .dark ? "dark" : "light").png"
        try? png.write(to: dir.appendingPathComponent(name))
      }
    }
  }
}
