import AppKit
import ElsewhenCore
import QuartzCore
import SwiftUI

/// The big globe's own state: where it faces, what is selected, and the
/// cities it draws. Kept apart from the panel so dragging the globe repaints
/// the globe and nothing else.
final class GlobeState: ObservableObject {
  @Published var spin: Double = 20
  /// Latitude under the viewer. Not "tilt": the hero globe uses that for the axial lean.
  @Published var viewLat: Double = 20
  /// A "label|zone" key, not an index: the city list is rebuilt as its inputs land.
  @Published var selectedKey = ""
  @Published var dragging = false
  @Published private(set) var flying = false
  @Published private(set) var coasting = false
  @Published private(set) var allCities: [GlobeCity] = GlobeData.cities
  /// The instant the terminator and the dots' daylight are drawn for, moved
  /// on a minute at a time: the line creeps a quarter of a degree a minute.
  @Published var sunMs: Double = (Date().timeIntervalSince1970 * 1000 / 60000).rounded(.down) * 60000
  let geometry = GlobeGeometry()

  private(set) var homeName = ""
  private(set) var trackedNames = Set<String>()
  private var homeRow: GlobeCity?
  private var pendingJump = ""
  private var homePending = false

  var velocity: Double = 0
  let dragSpinRate = 0.45
  let dragTiltRate = 0.35
  let dragLatLimit = 80.0
  let flyLatLimit = 70.0
  let throwDecay = 0.96

  private let flight = Tween()
  private var coast: Int?
  private var lastFrame: CFTimeInterval = 0

  /// A city not on the globe yet was picked; the panel geocodes it for the session.
  var onJump: (String, String, Place?) -> Void = { _, _, _ in }
  /// A real selection, for the list's focus.
  var onSelect: (String, String) -> Void = { _, _ in }
  /// A tap on a city, which may make it here.
  var onTap: (String, String) -> Void = { _, _ in }

  var moving: Bool { dragging || flying || coasting }

  var selected: Int {
    selectedKey.isEmpty ? -1 : (allCities.firstIndex { $0.key == selectedKey } ?? -1)
  }

  var selectedCity: GlobeCity? {
    let i = selected
    return i >= 0 ? allCities[i] : nil
  }

  func select(_ index: Int) {
    let key = index >= 0 && index < allCities.count ? allCities[index].key : ""
    if key == selectedKey { return }
    selectedKey = key
    if index >= 0 && index < allCities.count { onSelect(allCities[index].name, allCities[index].zone) }
  }

  func isHome(_ i: Int) -> Bool {
    i >= 0 && i < allCities.count && !homeName.isEmpty && allCities[i].name.lowercased() == homeName
  }

  func isTracked(_ i: Int) -> Bool {
    i >= 0 && i < allCities.count && trackedNames.contains(allCities[i].name.lowercased())
  }

  // ---- inputs

  /// Home first, then the built-ins, the tracked cities and the session's, first name wins.
  func update(home: GlobeCity?, tracked: [GlobeCity], session: [GlobeCity], trackedNames: Set<String>) {
    homeRow = home
    homeName = home?.name.lowercased() ?? ""
    self.trackedNames = trackedNames
    let next = Model.mergeCities(home: home, builtIn: GlobeData.cities, tracked: tracked, session: session)
    if next != allCities { allCities = next }
    if homePending { showHome() }
    if !pendingJump.isEmpty {
      let parts = pendingJump.components(separatedBy: "|")
      if parts.count == 2, indexOf(parts[0], parts[1]) >= 0 { goTo(parts[0], parts[1], nil) }
    }
  }

  func indexOf(_ label: String, _ zone: String) -> Int {
    allCities.firstIndex { $0.name == label && $0.zone == zone } ?? -1
  }

  func nameTaken(_ label: String) -> Bool {
    let name = label.lowercased()
    return allCities.contains { $0.name.lowercased() == name }
  }

  // ---- motion

  /// Centring a city is setting spin and viewLat to its own coordinates, the short way round.
  func flyTo(_ lat: Double, _ lon: Double) {
    stopCoasting()
    let fromSpin = spin, toSpin = spin + Solar.shortestTurn(spin, lon)
    let fromLat = viewLat, toLat = max(-flyLatLimit, min(flyLatLimit, lat))
    flying = true
    flight.run(from: 0, to: 1, duration: 0.8, easing: .outCubic, onFrame: { [weak self] t in
      self?.spin = fromSpin + (toSpin - fromSpin) * t
      self?.viewLat = fromLat + (toLat - fromLat) * t
    }, onDone: { [weak self] in self?.flying = false })
  }

  /// Opening lands on home and selects it, so the footer names it. Held until home's coordinates land.
  func showHome() {
    guard let home = homeRow else {
      homePending = true
      return
    }
    homePending = false
    select(indexOf(home.name, home.zone))
    flyTo(home.lat, home.lon)
  }

  /// A search result may be one of several towns of one name, and the globe
  /// holds one city per name, so the picked place is found by where it is.
  func goTo(_ label: String, _ zone: String, _ place: Place?) {
    var label = label
    let pinned = place?.lat != nil && place?.lon != nil
    var i = indexOf(label, zone)
    if i >= 0, pinned, !Model.nearPlace(allCities[i].lat, allCities[i].lon, place?.lat, place?.lon) { i = -1 }
    if i < 0, pinned, nameTaken(label) {
      let named = Model.regionalName(label, place?.region)
      if named == label {
        flyTo(place!.lat!, place!.lon!)
        pendingJump = ""
        return
      }
      label = named
      i = indexOf(label, zone)
    }
    if i >= 0 {
      select(i)
      flyTo(allCities[i].lat, allCities[i].lon)
      pendingJump = ""
      return
    }
    // Not on the globe yet: ask for it, and select it once it lands.
    if pinned { flyTo(place!.lat!, place!.lon!) }
    pendingJump = label + "|" + zone
    onJump(label, zone, place)
  }

  // ---- the pointer

  func beginDrag() {
    flight.stop()
    flying = false
    stopCoasting()
    dragging = true
    velocity = 0
  }

  func drag(dx: Double, dy: Double) {
    spin -= dx * dragSpinRate
    viewLat = max(-dragLatLimit, min(dragLatLimit, viewLat + dy * dragTiltRate))
    velocity = -dx * dragSpinRate
  }

  /// The throw: spin keeps going after the drag and eases to a stop. The
  /// velocity is degrees per 60th of a second, so each frame is scaled by
  /// how long it really took: the same throw on a 60 or a 120 Hz screen.
  func endDrag(moved: Bool) {
    dragging = false
    if !moved {
      velocity = 0
      return
    }
    if abs(velocity) <= 0.01 { return }
    coasting = true
    lastFrame = CACurrentMediaTime()
    coast = FrameClock.shared.subscribe { [weak self] now in
      guard let self else { return }
      let ticks = max(0, min(4, (now - self.lastFrame) * 60))
      self.lastFrame = now
      self.spin += self.velocity * ticks
      self.velocity *= pow(self.throwDecay, ticks)
      if abs(self.velocity) <= 0.01 { self.stopCoasting() }
    }
  }

  func stopCoasting() {
    if let coast { FrameClock.shared.unsubscribe(coast) }
    coast = nil
    velocity = 0
    if coasting { coasting = false }
  }

  /// A click at disc-centred coordinates: select the hit and turn it to face you. A miss only clears.
  @discardableResult
  func pick(at x: Double, _ y: Double, scene: GlobeScene) -> Int {
    let hit = scene.hit(x, y)
    if hit < 0 {
      selectedKey = ""
      return hit
    }
    select(hit)
    flyTo(allCities[hit].lat, allCities[hit].lon)
    onTap(allCities[hit].name, allCities[hit].zone)
    return hit
  }

  // ---- what gets drawn

  func scene(radius: Double, width: Double, reduced: Bool) -> GlobeScene {
    GlobeScene.make(self, radius: radius, width: width, reduced: reduced)
  }
}

/// The dots and labels of one frame.
struct GlobeScene {
  var plotted: [Solar.Plot] = []
  var labels: [Solar.PlacedLabel] = []

  static let labelFont = Style.nsFont(Style.caption)
  static let strongFont = Style.nsFont(Style.caption, .bold)

  static func make(_ globe: GlobeState, radius: Double, width: Double, reduced: Bool) -> GlobeScene {
    var scene = GlobeScene()
    let cities = globe.allCities
    guard !cities.isEmpty, radius > 0 else { return scene }
    let selected = globe.selected
    var candidates: [Solar.Plot] = []
    for (i, c) in cities.enumerated() {
      let p = Solar.project(c.lat, c.lon, spin: globe.spin, viewLat: globe.viewLat, r: radius)
      if !p.visible { continue }
      let must = globe.isHome(i) || globe.isTracked(i) || i == selected
      candidates.append(Solar.Plot(index: i, x: p.x, y: p.y, cosc: p.cosc, rank: c.rank, keep: must))
    }
    candidates.sort { a, b in
      if a.keep != b.keep { return a.keep }
      if a.rank != b.rank { return a.rank < b.rank }
      return a.cosc > b.cosc
    }
    scene.plotted = Solar.declutter(candidates, minDist: 19)
    // Names on a moving globe are a smear; they come back the moment it settles.
    if reduced { return scene }
    let labelCandidates: [Solar.LabelCandidate] = scene.plotted.compactMap { p in
      if p.cosc < 0.12 { return nil }
      let strong = globe.isHome(p.index) || globe.isTracked(p.index)
      let w = Double(Style.width(cities[p.index].name, strong ? strongFont : labelFont))
      return Solar.LabelCandidate(index: p.index, width: w, x: p.x, y: p.y, rank: p.keep ? 0 : p.rank, cosc: p.cosc)
    }
    scene.labels = Solar.layoutLabels(labelCandidates, lineHeight: Double(Style.caption) + 3, limit: 14,
                                      maxX: width / 2 - 4, gap: 6)
    return scene
  }

  /// Labels count as part of their city and win over a neighbouring dot.
  func hit(_ x: Double, _ y: Double) -> Int {
    if let label = labels.first(where: { $0.box.contains(x, y, pad: 3) }) { return label.index }
    var best = -1
    var bestD = 13.0
    for p in plotted {
      let d = hypot(x - p.x, y - p.y)
      if d < bestD {
        bestD = d
        best = p.index
      }
    }
    return best
  }
}

/// The globe's paths for one view of it - coastlines, graticule and
/// terminator, centred on the origin - kept until the view changes. While the
/// globe grows out of the header it is redrawn every frame at one spin and
/// one radius (the zoom is a scale on top), so this is built once, not 60 times a second.
final class GlobeGeometry {
  struct Key: Equatable {
    var spin: Double
    var viewLat: Double
    var radius: Double
    var coarse: Bool
    var gridStep: Double
    var sunMs: Double
  }

  struct Paths {
    var land = Path()
    var grid = Path()
    var terminator = Path()
  }

  private var key: Key?
  private var cached = Paths()

  func paths(_ key: Key) -> Paths {
    if key == self.key { return cached }
    let r = key.radius, spin = key.spin, viewLat = key.viewLat, origin = CGPoint.zero
    var paths = Paths()
    for lon in stride(from: -180.0, to: 180, by: key.gridStep) {
      let pts = stride(from: -90.0, through: 90, by: 3).map { LatLon(lat: $0, lon: lon) }
      paths.grid.addRuns(Solar.visibleSegments(pts, spin: spin, viewLat: viewLat, r: r), center: origin)
    }
    for lat in stride(from: -60.0, through: 60, by: key.gridStep) {
      let pts = stride(from: -180.0, through: 180, by: 3).map { LatLon(lat: lat, lon: $0) }
      paths.grid.addRuns(Solar.visibleSegments(pts, spin: spin, viewLat: viewLat, r: r), center: origin)
    }
    for ring in key.coarse ? GlobeData.landCoarse : GlobeData.land {
      let poly = Solar.clipRingToDisc(ring, spin: spin, viewLat: viewLat, r: r)
      if poly.count >= 3 { paths.land.addPath(Path(poly, center: origin, close: true)) }
    }
    let line = Solar.terminator(Solar.subsolarPoint(key.sunMs), steps: 180)
    paths.terminator.addRuns(Solar.visibleSegments(line, spin: spin, viewLat: viewLat, r: r), center: origin)
    self.key = key
    cached = paths
    return paths
  }
}
