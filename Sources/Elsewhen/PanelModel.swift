import AppKit
import Combine
import ElsewhenCore
import Observation
import ServiceManagement
import SwiftUI

enum OffsetMode: String { case home, utc }

enum SearchKind { case add, here, jump }

struct ScrollRequest: Equatable {
  var id: String
  var nonce: Int
}

struct SearchState: Equatable {
  var active = false
  var query = ""
  var selectedIndex = 0
}

/// Everything the panel shows and does: the port of Elsewhen's Panel.qml.
/// One number, `zoom`, drives the list-to-globe transition; the list's focus
/// is held as a city's key so it follows the city through a reorder.
@MainActor
@Observable
final class PanelModel {
  private let defaults: UserDefaults
  /// Saves its settings to `defaults`.
  private let persists: Bool
  /// Fetches places, weather and profiles. Off for tests and snapshots.
  private let network: Bool
  private let locale: Locale
  let globe = GlobeState()

  // MARK: settings

  private(set) var zones: [City] = []
  /// nil follows the system's clock notation.
  var hour24Setting: Bool? = nil { didSet { save() } }
  var offsetMode: OffsetMode = .home { didSet { save() } }
  /// "", "C" or "F"; blank follows the system's measurement units.
  var unitsSetting = "" { didSet { save() } }
  var globeEnabled = true { didSet { save() } }
  /// Draw the globe with less in it while it moves.
  var smoothMotion = true { didSet { save() } }
  /// The city whose time sits beside the menu bar icon, by key; "" for the icon alone.
  var menuBarCity = "" { didSet { save() } }
  /// Where you are; it counts only while this Mac is on its zone.
  private(set) var hereSetting: City?
  /// A here on another zone, waiting for this Mac's clock to move there.
  private(set) var pendingHere: City?

  @ObservationIgnored private var loading = false

  var hour24: Bool { hour24Setting ?? L10n.systemUses24Hour }
  var units: String { Model.resolveUnits(unitsSetting, auto: L10n.systemUnits) }
  private(set) var words: Words

  // MARK: the clock

  /// The ticking time, observed only by the views that show it.
  let clock = Clock()
  var nowMs: Double { clock.nowMs }
  private(set) var localZone: String = TimeZone.current.identifier
  /// Set absolutely from the pointer, held briefly after release, then back to now.
  var scrubMinutes: Double = 0
  var opened = false

  var effectiveMs: Double { nowMs + scrubMinutes * 60000 }
  var localTimeZone: TimeZone { TimeZone(identifier: localZone) ?? .current }

  // MARK: places and weather

  private(set) var facts: [String: Facts] = [:]
  /// Cities jumped to on the globe; never saved.
  private(set) var sessionCities: [City] = []
  @ObservationIgnored private var geo: [String: Place] = [:]
  @ObservationIgnored private var fallbackGeo: [String: Place] = [:]
  @ObservationIgnored private var weather: [String: WeatherReading] = [:]
  @ObservationIgnored private var factsRunning = false
  @ObservationIgnored private var factsQueued = false

  // MARK: focus and the globe

  var focusKey = ""
  /// Past the last city the list's cursor rests on "Add a city".
  var addSelected = false
  private(set) var globeMode = false
  private(set) var zoom: Double = 0
  private(set) var heroSpinValue: Double = 0
  private(set) var heroSpinning = false
  /// Asks the scroll view to bring a row, "add" or "top" into view.
  var scrollRequest: ScrollRequest?

  private let zoomTween = Tween()
  private let heroTween = Tween()
  @ObservationIgnored private var openingSpin: (from: Double, to: Double) = (-1080, 0)
  @ObservationIgnored private var spinPending = false
  private let spinFallback = Ticker()

  // MARK: dragging rows

  private(set) var dragIndex = -1
  private(set) var dragOffset: Double = 0
  private(set) var dragTarget = -1
  private(set) var rowPitch: Double = 0
  @ObservationIgnored private var rowPitches: [Double] = []
  private let dropTween = Tween()

  // MARK: the moon

  private(set) var moonShowing = false
  private(set) var moonDemo: Double = -1
  private let moonStops: [Double] = [0, 0.12, 0.25, 0.38, 0.5, 0.62, 0.75, 0.88, 1]
  @ObservationIgnored private var moonStep = 0
  private let moonTimer = Ticker()
  private let moonTween = Tween()

  // MARK: search and people

  var addSearch = SearchState()
  var hereSearch = SearchState()
  var jumpSearch = SearchState()
  private(set) var placeCache: [String: [ZoneOption]] = [:]
  @ObservationIgnored private var placeWanted = ""
  @ObservationIgnored private var placeRunning = false
  private let placeDebounce = Ticker()

  private(set) var profiles: [String: Profile] = [:]
  private(set) var profileStamp: Double = 0
  @ObservationIgnored private var profilesTried = Set<String>()
  @ObservationIgnored private var profilesRunning = false
  @ObservationIgnored private var profilesQueued = false
  var peopleEditIndex = -1

  /// Set by the app: close the panel, and ask for this Mac's clock to move to a zone.
  @ObservationIgnored var onClose: @MainActor () -> Void = {}
  @ObservationIgnored var onMoveClock: @MainActor (_ city: String, _ zone: String) -> Void = { _, _ in }

  private let ticker = Ticker()
  private let factsTicker = Ticker()
  private let scrubHold = Ticker()
  @ObservationIgnored private var observers: Set<AnyCancellable> = []

  private static let catalog: [String] = TimeZone.knownTimeZoneIdentifiers
  @ObservationIgnored private lazy var allZoneOptions: [ZoneOption] = Model.zoneOptions(Self.catalog, existing: [])
  @ObservationIgnored private var zoneOptionsCache: (zones: [City], options: [ZoneOption])?

  // MARK: - life

  init(defaults: UserDefaults = .standard, persists: Bool = true, network: Bool = true,
       localZone: String? = nil, locale: Locale = .current) {
    self.defaults = defaults
    self.persists = persists
    self.network = network
    self.locale = locale
    self.words = L10n.words(locale: locale)
    if let localZone { self.localZone = localZone }
    load()
    globe.onJump = { [weak self] label, zone, place in self?.addSessionCity(label, zone, place) }
    globe.onSelect = { [weak self] label, zone in self?.focusFromGlobe(label, zone) }
    globe.onTap = { [weak self] label, zone in self?.claimHome(label, zone) }
    if zones.isEmpty && persists { seedFirstRun() }
    syncGlobe()

    let center = NotificationCenter.default
    center.publisher(for: .NSSystemTimeZoneDidChange)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in MainActor.assumeIsolated { self?.timeZoneChanged() } }
      .store(in: &observers)
    center.publisher(for: NSLocale.currentLocaleDidChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in MainActor.assumeIsolated { self?.words = L10n.words() } }
      .store(in: &observers)
    refreshFacts()
  }

  func setOpened(_ open: Bool) {
    if open == opened { return }
    opened = open
    if open {
      focusKey = ""
      addSelected = false
      tick()
      refreshFacts()
      fetchProfiles()
      startOpeningSpin()
      ticker.start(every: 1) { [weak self] in self?.tick() }
      factsTicker.start(every: 900) { [weak self] in self?.refreshFacts() }
    } else {
      ticker.stop()
      factsTicker.stop()
      stopSearch(.add)
      stopSearch(.here)
      stopSearch(.jump)
      peopleEditIndex = -1
      zoomTween.stop()
      globeMode = false
      zoom = 0
      scrubHold.stop()
      scrubMinutes = 0
      stopMoonShow()
      cancelRowDrag()
      spinPending = false
      spinFallback.stop()
    }
  }

  func tick() {
    let now = Date().timeIntervalSince1970 * 1000
    clock.nowMs = now
    let minute = (now / 60000).rounded(.down) * 60000
    if globe.sunMs != minute { globe.sunMs = minute }
  }

  private func timeZoneChanged() {
    NSTimeZone.resetSystemTimeZone()
    localZone = TimeZone.current.identifier
    if let pending = pendingHere, pending.id == localZone {
      pendingHere = nil
      hereSetting = pending
      save()
    }
    tick()
    syncGlobe()
    refreshFacts()
  }

  // MARK: - settings

  private enum Key {
    static let cities = "cities", hour24 = "hour24", offsetMode = "offsetMode", units = "units"
    static let globeEnabled = "globeEnabled", smoothMotion = "smoothMotion", here = "here", pendingHere = "pendingHere"
    static let menuBarCity = "menuBarCity"
  }

  private func load() {
    loading = true
    defer { loading = false }
    if let data = defaults.data(forKey: Key.cities), let cities = try? JSONDecoder().decode([City].self, from: data) {
      zones = Model.normalizeCities(cities)
    }
    hour24Setting = defaults.object(forKey: Key.hour24) as? Bool
    offsetMode = OffsetMode(rawValue: defaults.string(forKey: Key.offsetMode) ?? "") ?? .home
    unitsSetting = defaults.string(forKey: Key.units) ?? ""
    globeEnabled = defaults.object(forKey: Key.globeEnabled) as? Bool ?? true
    smoothMotion = defaults.object(forKey: Key.smoothMotion) as? Bool ?? true
    menuBarCity = defaults.string(forKey: Key.menuBarCity) ?? ""
    hereSetting = decodeCity(Key.here)
    pendingHere = decodeCity(Key.pendingHere)
  }

  private func decodeCity(_ key: String) -> City? {
    guard let data = defaults.data(forKey: key), let city = try? JSONDecoder().decode(City.self, from: data) else { return nil }
    return Model.normalizeCities([city]).first
  }

  private func save() {
    if loading || !persists { return }
    let encoder = JSONEncoder()
    defaults.set(try? encoder.encode(zones), forKey: Key.cities)
    if let hour24Setting { defaults.set(hour24Setting, forKey: Key.hour24) } else { defaults.removeObject(forKey: Key.hour24) }
    defaults.set(offsetMode.rawValue, forKey: Key.offsetMode)
    defaults.set(unitsSetting, forKey: Key.units)
    defaults.set(globeEnabled, forKey: Key.globeEnabled)
    defaults.set(smoothMotion, forKey: Key.smoothMotion)
    defaults.set(menuBarCity, forKey: Key.menuBarCity)
    for (key, city) in [(Key.here, hereSetting), (Key.pendingHere, pendingHere)] {
      if let city { defaults.set(try? encoder.encode(city), forKey: key) } else { defaults.removeObject(forKey: key) }
    }
  }

  func toggleHour24() { hour24Setting = !hour24 }
  func toggleOffsetMode() { offsetMode = offsetMode == .utc ? .home : .utc }
  func toggleUnits() { unitsSetting = units == "C" ? "F" : "C" }

  /// Bumped on a change, so a view reading the login item reads it again.
  private var loginChanges = 0

  var launchAtLogin: Bool {
    get {
      _ = loginChanges
      return SMAppService.mainApp.status == .enabled
    }
    set {
      do {
        if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
      } catch {
        // Outside an app bundle there is nothing to register.
      }
      loginChanges += 1
    }
  }

  // MARK: - the list

  /// Replaces the list, for the snapshot renderer and the tests.
  func setZonesForPreview(_ next: [City]) { zones = next }

  func setZones(_ next: [City]) {
    if next == zones { return }
    zones = next
    save()
    syncGlobe()
    refreshFacts()
    fetchProfiles()
  }

  /// The label matters as much as the zone: many cities share one.
  func addCity(_ id: String, _ label: String, _ place: Place?) {
    setZones(Model.addZone(zones, id: id, label: label, place: place))
  }

  func removeCityAt(_ index: Int) { setZones(Model.removeZoneAt(zones, index)) }

  /// Home plus four places spread round the clock from it.
  private func seedFirstRun() {
    var offsets: [String: Int] = [:]
    for id in Model.seedCandidateZones() + [localZone] {
      offsets[id] = ZoneInfo.of(id, atMs: nowMs)?.offsetMinutes
    }
    var seeded: [City] = []
    if let here = hereZone {
      seeded = Model.seedZones(home: City(label: here.city.label, id: localZone), offsets: offsets)
      if !seeded.isEmpty && here.city.lat != nil { seeded[0] = here.city }
    }
    if seeded.isEmpty { seeded = Model.parseZones(Model.defaultZones) }
    zones = seeded
    save()
  }

  /// A row's clock at the shown time (now, or scrubbed).
  func clockRow(_ city: City) -> ClockRow {
    let ms = effectiveMs
    return Model.rowFor(city, info: ZoneInfo.of(city.id, atMs: ms), ms: ms, localZone: localTimeZone, hour24: hour24, words: words)
  }

  func offsetText(_ row: ClockRow) -> String {
    guard row.ready else { return "" }
    return offsetMode == .utc ? Model.utcOffsetLabel(row.offsetMinutes, words: words) : row.relative
  }

  func tempLabel(_ city: City) -> String {
    Model.formatTemp(facts[city.key]?.celsius, units: units, words: words)
  }

  func weatherSymbol(_ city: City) -> String? {
    switch Model.weatherKind(facts[city.key]?.code) {
    case .sunny: return "sun.max.fill"
    case .partly: return "cloud.sun.fill"
    case .cloudy: return "cloud.fill"
    case .rain: return "cloud.rain.fill"
    case .snow: return "cloud.snow.fill"
    case nil: return nil
    }
  }

  func placeOf(_ city: City) -> Facts? {
    guard let f = facts[city.key], f.hasCoordinates else { return nil }
    return f
  }

  // MARK: - here

  var hereZone: Here? { Model.resolveHere(hereSetting, localZone: localZone) }
  var homeCity: String { hereZone?.city.label ?? "" }

  /// The menu bar's "Tokyo 19:40", at the real time, or nil for the icon alone.
  func menuBarText() -> String? {
    guard !menuBarCity.isEmpty, let city = zones.first(where: { $0.key == menuBarCity }),
          let info = ZoneInfo.of(city.id, atMs: nowMs) else { return nil }
    return city.label + " " + Model.formatClock(nowMs, offsetMinutes: info.offsetMinutes, hour24: hour24, words: words)
  }
  var homeZone: City { hereZone?.city ?? City(label: "", id: localZone) }

  var localTime: String {
    let parts = Model.localParts(effectiveMs, zone: localTimeZone)
    let text = Model.formatTime(parts, hour24: hour24, words: words)
    return hour24 ? text : text + " " + Model.meridiem(parts, words: words)
  }

  /// "It's 10:28 AM here in Kyiv", with the scrub's offset while time is shifted.
  var hereLine: String {
    let line = homeCity.isEmpty
      ? L10n.t("elsewhen.here", "It's %1 here", localTime)
      : L10n.t("elsewhen.hereIn", "It's %1 here in %2", localTime, homeCity)
    let shift = Model.formatScrubDelta(scrubMinutes, words: words)
    return shift.isEmpty ? line : line + "  " + shift
  }

  func startChoosingHere() {
    if localZone.isEmpty || globeMode { return }
    startSearch(.here)
  }

  /// A tap on the globe: a city on this Mac's zone becomes here, and the zone's
  /// own city goes back to being the default.
  func claimHome(_ label: String, _ zone: String) {
    guard let here = hereZone else { return }
    guard let stored = Model.homeCityAfterTap(label: label, zoneId: zone, homeOverride: here.chosen ? here.city.label : "",
                                              localZone: localZone) else { return }
    if stored.isEmpty {
      setHere(City(label: Model.labelForZoneId(localZone), id: localZone))
      return
    }
    var pick = City(label: stored, id: zone)
    let known = (zones + sessionCities).first { $0.label == label && $0.id == zone }
    if let known, known.hasCoordinates {
      pick.lat = known.lat
      pick.lon = known.lon
    } else if let f = placeOf(pick) {
      pick.lat = f.lat
      pick.lon = f.lon
    }
    pick.region = known?.region
    setHere(pick)
  }

  /// Here moves, and the row that stood for it follows. A place on another
  /// zone needs this Mac's clock moved first, which only System Settings can do.
  func setHere(_ pick: City) {
    guard let next = Model.hereAfterPick(zones, current: hereZone?.city, pick: pick, localZone: localZone) else { return }
    if !next.zoneChange.isEmpty {
      pendingHere = next.here ?? City(label: Model.labelForZoneId(next.zoneChange), id: next.zoneChange)
      save()
      let name = pendingHere?.label ?? next.zoneChange
      let zone = next.zoneChange
      Task { @MainActor [weak self] in self?.onMoveClock(name, zone) }
      return
    }
    pendingHere = nil
    hereSetting = next.here
    save()
    if next.zones != zones { setZones(next.zones) }
    syncGlobe()
    refreshFacts()
  }

  // MARK: - focus

  var focusIndex: Int { Model.indexOfZoneKey(zones, focusKey) }
  var focusZone: City { focusIndex >= 0 ? zones[focusIndex] : homeZone }
  var focusPlace: Facts? { placeOf(focusZone) }
  var focusLon: Double { focusPlace?.lon ?? 0 }

  /// The hero globe's meridian: the opening or focus spin while it runs, else the focus.
  var heroSpin: Double { heroSpinning ? heroSpinValue : focusLon }

  func focusOn(_ index: Int) {
    addSelected = false
    let from = heroSpin
    focusKey = index >= 0 && index < zones.count ? zones[index].key : ""
    if let lon = focusPlace?.lon { turnHero(from: from, to: lon) }
  }

  func focusFromGlobe(_ label: String, _ zone: String) {
    let i = Model.indexOfZone(zones, label: label, id: zone)
    if i >= 0 { focusOn(i) }
  }

  /// Up and down walk home, each city and then "Add a city", wrapping round.
  func moveFocus(_ step: Int) {
    let at = addSelected ? zones.count : focusIndex
    let next = Model.moveSelection(at + 1, step, zones.count + (globeMode ? 1 : 2)) - 1
    if next == zones.count {
      addSelected = true
      requestScroll("add")
      return
    }
    focusOn(next)
    if globeMode { showFocusOnGlobe() } else { requestScroll(next >= 0 ? zones[next].key : "top") }
  }

  func deleteFocused() {
    if globeMode || addSelected || focusIndex < 0 || zones.count < 2 { return }
    let at = focusIndex
    removeCityAt(at)
    focusOn(min(at, zones.count - 1))
  }

  @ObservationIgnored private var scrollNonce = 0
  func requestScroll(_ id: String) {
    scrollNonce += 1
    scrollRequest = ScrollRequest(id: id, nonce: scrollNonce)
  }

  // MARK: - the hero globe

  private func turnHero(from: Double, to lon: Double) {
    heroSpinValue = from
    heroSpinning = true
    let target = from + Solar.shortestTurn(from, lon)
    heroTween.run(from: from, to: target, duration: 0.7, easing: .outCubic, onFrame: { [weak self] v in
      self?.heroSpinValue = v
    }, onDone: { [weak self] in self?.heroSpinning = false })
  }

  /// Three turns that land on `lon`; nil replays the last endpoints.
  private func spinOpening(_ lon: Double?) {
    if let lon { openingSpin = (lon - 1080, lon) }
    heroSpinning = true
    heroSpinValue = openingSpin.from
    heroTween.run(from: openingSpin.from, to: openingSpin.to, duration: 1.25, easing: .outQuart, onFrame: { [weak self] v in
      self?.heroSpinValue = v
    }, onDone: { [weak self] in self?.heroSpinning = false })
  }

  /// It lands on the home meridian, so it waits for home's coordinates.
  private func startOpeningSpin() {
    guard let lon = facts[focusZone.key]?.lon else {
      spinPending = true
      spinFallback.once(after: 1.5) { [weak self] in
        guard let self, self.spinPending else { return }
        self.spinPending = false
        self.spinOpening(nil)
      }
      return
    }
    spinPending = false
    spinFallback.stop()
    spinOpening(lon)
  }

  // MARK: - the zoom

  var zoomIdle: Bool { zoom == 0 || zoom == 1 }
  var bigGlobeOpacity: Double { max(0, min(1, zoom / 0.12)) }
  /// The globe's footer and jump bar arrive once it has landed.
  var chromeOpacity: Double { max(0, min(1, (zoom - 0.74) / 0.26)) }

  /// Duration and easing are chosen here, before the mode flips, never derived from it.
  func setGlobeMode(_ on: Bool, slow: Bool = false) {
    if on && !globeEnabled { return }
    if on {
      addSelected = false
      stopSearch(.here)
      peopleEditIndex = -1
    } else {
      stopSearch(.jump)
    }
    let duration = (on ? 0.8 : 0.5) * (slow ? 3 : 1)
    globeMode = on
    zoomTween.run(from: zoom, to: on ? 1 : 0, duration: duration, easing: on ? .outQuart : .inOutCubic,
                  onFrame: { [weak self] v in self?.zoom = v })
    if on { showFocusOnGlobe() }
  }

  /// The globe opens on the list's focus, when its coordinates are known.
  func showFocusOnGlobe() {
    if focusIndex >= 0, focusPlace != nil {
      let z = focusZone
      globe.goTo(z.label, z.id, nil)
    } else {
      globe.showHome()
    }
  }

  /// The globe's cities: home, the tracked rows and the session's jumps, wherever their coordinates are known.
  func syncGlobe() {
    func rows(_ list: [City], rank: Int) -> [GlobeCity] {
      list.compactMap { c in
        guard let f = placeOf(c), let lat = f.lat, let lon = f.lon else { return nil }
        return GlobeCity(name: c.label, zone: c.id, lat: lat, lon: lon, rank: rank)
      }
    }
    var home: GlobeCity?
    if !homeCity.isEmpty, let f = placeOf(homeZone), let lat = f.lat, let lon = f.lon {
      home = GlobeCity(name: homeCity, zone: localZone, lat: lat, lon: lon, rank: 0)
    }
    globe.update(home: home, tracked: rows(zones, rank: 0), session: rows(sessionCities, rank: 1),
                 trackedNames: Set(zones.map { $0.label.lowercased() }))
  }

  func addSessionCity(_ label: String, _ id: String, _ place: Place?) {
    if sessionCities.contains(where: { $0.label == label && $0.id == id }) { return }
    guard let city = Model.addZone([], id: id, label: label, place: place).first else { return }
    sessionCities.append(city)
    refreshFacts()
  }

  // MARK: - dragging rows

  func beginRowDrag(_ index: Int, pitch: Double, pitches: [Double]) {
    dropTween.stop()
    dragIndex = index
    dragTarget = index
    rowPitch = pitch
    rowPitches = pitches
  }

  func moveRowDrag(_ offset: Double) {
    guard dragIndex >= 0 else { return }
    dragOffset = offset
    dragTarget = Model.dragTargetFor(dragIndex, offset, rowPitch, dragTarget, zones.count, rowPitches)
  }

  /// Glide into the slot, then commit.
  func releaseRowDrag() {
    guard dragIndex >= 0 else {
      cancelRowDrag()
      return
    }
    let to = Model.dropOffset(dragIndex, dragTarget, rowPitch, rowPitches)
    dropTween.run(from: dragOffset, to: to, duration: 0.15, easing: .outCubic, onFrame: { [weak self] v in
      self?.dragOffset = v
    }, onDone: { [weak self] in self?.commitRowDrag() })
  }

  private func commitRowDrag() {
    if dragIndex >= 0 && dragTarget >= 0 && dragTarget != dragIndex {
      let moved = Model.moveZone(zones, from: dragIndex, to: dragTarget)
      cancelRowDrag()
      setZones(moved)
    } else {
      cancelRowDrag()
    }
  }

  func cancelRowDrag() {
    dropTween.stop()
    dragIndex = -1
    dragTarget = -1
    dragOffset = 0
  }

  func rowShift(_ index: Int) -> Double {
    Model.rowShift(index, dragIndex, dragTarget, dragOffset, rowPitch)
  }

  // MARK: - scrubbing

  /// Measured against the unscrubbed present, so a drag cannot drift.
  func scrubTo(_ row: ClockRow, _ fraction: Double) {
    guard row.ready else { return }
    let info = ZoneInfo.of(row.id, atMs: nowMs)
    let parts = Model.zoneParts(nowMs, offsetMinutes: info?.offsetMinutes ?? row.offsetMinutes)
    scrubMinutes = Model.scrubDeltaMinutes(fraction, cityLocalMinutes: Double(parts.hour * 60 + parts.minute))
  }

  func beginScrub(_ row: ClockRow, _ fraction: Double) {
    scrubHold.stop()
    scrubTo(row, fraction)
  }

  func endScrub() {
    scrubHold.once(after: 2.5) { [weak self] in self?.scrubMinutes = 0 }
  }

  /// Held until Escape or close: a key press has no release to time from.
  func shiftHour(_ step: Int) {
    scrubHold.stop()
    scrubMinutes = scrubMinutes.rounded() + Double(step * 60)
  }

  // MARK: - the moon

  var moonPhase: Double { moonShowing && moonDemo >= 0 ? moonDemo : Solar.moonPhase(effectiveMs) }

  /// Shift-click a moon to walk it through a lunation.
  func startMoonShow() {
    moonStep = 0
    moonShowing = true
    moonDemo = moonStops[0]
    moonTimer.start(every: 0.62) { [weak self] in
      guard let self else { return }
      self.moonStep += 1
      if self.moonStep >= self.moonStops.count {
        self.stopMoonShow()
        return
      }
      let from = self.moonDemo, to = self.moonStops[self.moonStep]
      self.moonTween.run(from: from, to: to, duration: 0.46, easing: .inOutSine, onFrame: { [weak self] v in
        self?.moonDemo = v
      })
    }
  }

  func stopMoonShow() {
    moonTimer.stop()
    moonTween.stop()
    moonShowing = false
    moonDemo = -1
  }

  // MARK: - search

  func search(_ kind: SearchKind) -> SearchState {
    switch kind {
    case .add: return addSearch
    case .here: return hereSearch
    case .jump: return jumpSearch
    }
  }

  private func setSearch(_ kind: SearchKind, _ state: SearchState) {
    switch kind {
    case .add: addSearch = state
    case .here: hereSearch = state
    case .jump: jumpSearch = state
    }
  }

  var anySearchActive: Bool { addSearch.active || hereSearch.active || jumpSearch.active }

  func startSearch(_ kind: SearchKind) {
    if kind == .add { stopSearch(.here) }
    if kind == .here { stopSearch(.add) }
    if kind != .jump { peopleEditIndex = -1 }
    setSearch(kind, SearchState(active: true, query: "", selectedIndex: 0))
    if kind == .add { requestScroll("add") }
  }

  func stopSearch(_ kind: SearchKind) {
    guard search(kind).active else { return }
    setSearch(kind, SearchState())
    if kind == .add { requestScroll("top") }
  }

  func setQuery(_ kind: SearchKind, _ text: String) {
    var s = search(kind)
    guard s.active, s.query != text else { return }
    s.query = text
    s.selectedIndex = 0
    setSearch(kind, s)
    requestPlaces(text)
  }

  func matches(_ kind: SearchKind) -> [ZoneOption] {
    let s = search(kind)
    guard s.active else { return [] }
    let places = placesFor(s.query)
    switch kind {
    case .add:
      let offline = Model.searchZones(zoneOptions(), query: s.query, limit: 6)
      return Model.mergePlaces(offline, places, existing: zones, limit: 10)
    case .here:
      return Model.mergePlaces(Model.searchZones(allZoneOptions, query: s.query, limit: 6), places, existing: [], limit: 10)
    case .jump:
      return Model.mergePlaces(Model.searchZones(allZoneOptions, query: s.query, limit: 5), places, existing: [], limit: 7)
    }
  }

  private func zoneOptions() -> [ZoneOption] {
    if let cache = zoneOptionsCache, cache.zones == zones { return cache.options }
    let options = Model.zoneOptions(Self.catalog, existing: zones)
    zoneOptionsCache = (zones, options)
    return options
  }

  func searching(_ kind: SearchKind) -> Bool {
    let s = search(kind)
    let q = Model.placeQuery(s.query)
    return s.active && !q.isEmpty && placeCache[q] == nil
  }

  func utcLabel(_ zone: String) -> String {
    Model.utcOffsetLabel(ZoneInfo.of(zone, atMs: nowMs)?.offsetMinutes, words: words)
  }

  func moveSearchSelection(_ kind: SearchKind, _ delta: Int) {
    var s = search(kind)
    s.selectedIndex = Model.moveSelection(s.selectedIndex, delta, matches(kind).count)
    setSearch(kind, s)
  }

  func hoverSearch(_ kind: SearchKind, _ index: Int) {
    var s = search(kind)
    if s.selectedIndex == index { return }
    s.selectedIndex = index
    setSearch(kind, s)
  }

  func pickSelected(_ kind: SearchKind) {
    let list = matches(kind)
    guard !list.isEmpty else { return }
    pick(kind, list[max(0, min(list.count - 1, search(kind).selectedIndex))])
  }

  func pick(_ kind: SearchKind, _ option: ZoneOption) {
    stopSearch(kind)
    switch kind {
    case .add: addCity(option.value, option.label, option.place)
    case .here: setHere(City(label: option.label, id: option.value, lat: option.lat, lon: option.lon, region: option.region))
    case .jump: globe.goTo(option.label, option.value, option.place)
    }
  }

  // MARK: - place search
  // The geocoder's places for each query, kept for the session; looked up once
  // the typing pauses, one request at a time, latest wins.

  private func requestPlaces(_ text: String) {
    let q = Model.placeQuery(text)
    if q.isEmpty || placeCache[q] != nil { return }
    placeWanted = q
    placeDebounce.once(after: 0.3) { [weak self] in self?.lookupPlaces() }
  }

  private func lookupPlaces() {
    let q = placeWanted
    if q.isEmpty || placeCache[q] != nil || placeRunning || !network { return }
    placeRunning = true
    let url = Model.geocodeURL(q)
    Task { [weak self] in
      let data = await Network.get(url)
      guard let self else { return }
      self.placeRunning = false
      // A failed lookup is remembered as no places, so the list stops saying it is searching.
      self.placeCache[q] = data.map(Model.placeOptions) ?? []
      self.lookupPlaces()
    }
  }

  private func placesFor(_ text: String) -> [ZoneOption] {
    let q = Model.placeQuery(text)
    return q.isEmpty ? [] : (placeCache[q] ?? [])
  }

  // MARK: - facts

  /// Tracked cities, the city you are in (for the globe's home) and session cities.
  private var factsRequest: [City] {
    var out = zones
    if let here = hereZone { out.append(here.city) }
    return out + sessionCities
  }

  func refreshFacts() {
    if zones.isEmpty || !network { return }
    if factsRunning {
      factsQueued = true
      return
    }
    let request = factsRequest
    // Coordinates a city came with, from a place search: never geocoded by name.
    var pinned: [String: Place] = [:]
    for row in request where row.hasCoordinates { pinned[row.key] = Place(lat: row.lat, lon: row.lon) }
    var seen = Set<String>()
    let missing = request.filter { row in
      let key = row.key
      if geo[key] != nil || pinned[key] != nil || seen.contains(key) { return false }
      seen.insert(key)
      return true
    }
    factsRunning = true
    let urls = missing.map { Model.geocodeURL($0.label) }
    Task { [weak self] in
      let answers = await Network.getAll(urls)
      guard let self else { return }
      for (i, row) in missing.enumerated() {
        let found = Model.pickGeocode(answers[i], zone: row.id)
        guard let place = found.place ?? Model.zoneTabCoords(ZoneTab.text, zone: row.id) else { continue }
        if found.answered { self.geo[row.key] = place } else { self.fallbackGeo[row.key] = place }
      }
      self.fetchWeather(request, pinned: pinned)
    }
  }

  private func coords(_ key: String, _ pinned: [String: Place]) -> Place? {
    pinned[key] ?? geo[key] ?? fallbackGeo[key]
  }

  private func fetchWeather(_ request: [City], pinned: [String: Place]) {
    let now = Date().timeIntervalSince1970 * 1000
    var keys: [String] = []
    for row in request where !keys.contains(row.key) {
      if let c = coords(row.key, pinned), Model.weatherStale(weather[row.key], nowMs: now, coords: c) { keys.append(row.key) }
    }
    if keys.isEmpty {
      publishFacts(request, pinned: pinned)
      return
    }
    let points = keys.compactMap { coords($0, pinned) }
    let url = Model.forecastURL(points)
    Task { [weak self] in
      let data = await Network.get(url)
      guard let self else { return }
      if let data {
        self.weather.merge(Model.parseForecast(data, keys: keys, nowMs: now, points: points)) { $1 }
      }
      self.publishFacts(request, pinned: pinned)
    }
  }

  private func publishFacts(_ request: [City], pinned: [String: Place]) {
    var next: [String: Facts] = [:]
    for row in request {
      var f = Facts()
      if let c = coords(row.key, pinned) {
        f.lat = c.lat
        f.lon = c.lon
      }
      if let w = weather[row.key] {
        f.celsius = w.celsius
        f.code = w.code
      }
      next[row.key] = f
    }
    facts = next
    factsRunning = false
    syncGlobe()
    if spinPending { startOpeningSpin() }
    if factsQueued {
      factsQueued = false
      Task { @MainActor [weak self] in self?.refreshFacts() }
    }
  }

  /// For the snapshot renderer: the globe fully open and facing home, or the list.
  func setZoomForPreview(_ value: Double) {
    zoomTween.stop()
    globeMode = value > 0
    zoom = value
    if let home = globe.allCities.first {
      globe.spin = home.lon
      globe.viewLat = max(-70, min(70, home.lat))
      globe.selectedKey = home.key
    }
  }

  /// For the snapshot renderer: facts as if they had been fetched.
  func setFactsForPreview(_ next: [String: Facts]) {
    facts = next
    syncGlobe()
  }

  // MARK: - people

  func fetchProfiles() {
    let wanted = Model.handlesIn(zones).filter { !profilesTried.contains($0) }
    if wanted.isEmpty || !network { return }
    if profilesRunning {
      profilesQueued = true
      return
    }
    profilesTried.formUnion(wanted)
    profilesRunning = true
    Task { [weak self] in
      let loaded = await Profiles.load(wanted)
      guard let self else { return }
      self.profiles.merge(loaded) { $1 }
      self.profileStamp = Date().timeIntervalSince1970
      self.profilesRunning = false
      if self.profilesQueued {
        self.profilesQueued = false
        self.fetchProfiles()
      }
    }
  }

  func startPeopleEdit(_ index: Int) {
    stopSearch(.add)
    stopSearch(.here)
    peopleEditIndex = index
  }

  func finishPeopleEdit(_ index: Int, _ text: String) {
    peopleEditIndex = -1
    setZones(Model.setPeopleAt(zones, index, Model.parsePeople(text)))
  }

  func cancelPeopleEdit() { peopleEditIndex = -1 }

  // MARK: - keys

  /// The panel's keys; true when the key was used. While a field has the
  /// keyboard only the keys that drive its search or edit come here.
  func handleKey(code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags, editing: Bool) -> Bool {
    let escape: UInt16 = 53, up: UInt16 = 126, down: UInt16 = 125, left: UInt16 = 123, right: UInt16 = 124
    let returnKey: UInt16 = 36, enter: UInt16 = 76, delete: UInt16 = 51, forwardDelete: UInt16 = 117, space: UInt16 = 49

    if let kind: SearchKind = jumpSearch.active ? .jump : addSearch.active ? .add : hereSearch.active ? .here : nil {
      switch code {
      case escape: stopSearch(kind); return true
      case up: moveSearchSelection(kind, -1); return true
      case down: moveSearchSelection(kind, 1); return true
      case returnKey, enter: pickSelected(kind); return true
      default: return false
      }
    }
    if peopleEditIndex >= 0 {
      if code == escape {
        cancelPeopleEdit()
        return true
      }
      return false
    }
    if editing { return false }
    if modifiers.contains(.command) { return false }

    switch code {
    case escape:
      // Escape unwinds one layer: a shifted time, the globe, then the panel.
      if scrubMinutes != 0 {
        scrubHold.stop()
        scrubMinutes = 0
      } else if globeMode {
        setGlobeMode(false)
      } else {
        onClose()
      }
      return true
    case up: moveFocus(-1); return true
    case down: moveFocus(1); return true
    case left: shiftHour(-1); return true
    case right: shiftHour(1); return true
    case delete, forwardDelete: deleteFocused(); return true
    case returnKey, enter:
      if addSelected { startSearch(.add) }
      return true
    case space:
      if addSelected { startSearch(.add) } else if globeEnabled { setGlobeMode(!globeMode) }
      return true
    default: break
    }

    switch characters.lowercased() {
    case "r": refreshFacts()
    case "t" where modifiers.contains(.option): toggleUnits()
    case "t": toggleHour24()
    case "+", "=":
      startSearch(globeMode ? .jump : .add)
    case "j" where globeMode: startSearch(.jump)
    case "a" where !globeMode: startSearch(.add)
    case "w" where !globeMode: startChoosingHere()
    case "p" where !globeMode && focusIndex >= 0: startPeopleEdit(focusIndex)
    default: return false
    }
    return true
  }
}
