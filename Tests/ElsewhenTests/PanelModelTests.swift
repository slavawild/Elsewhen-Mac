import AppKit
import XCTest
@testable import Elsewhen
@testable import ElsewhenCore

/// The panel's behaviour, driven the way the views and keys drive it.
@MainActor
final class PanelModelTests: XCTestCase {
  let escape: UInt16 = 53, space: UInt16 = 49, right: UInt16 = 124, down: UInt16 = 125, returnKey: UInt16 = 36
  var closes = 0

  func makeModel(_ cities: [City]? = nil) -> PanelModel {
    let model = Snapshots.model(defaults: UserDefaults(suiteName: "io.github.slavawild.Elsewhen.tests.\(UUID())")!)
    if let cities { model.setZonesForPreview(cities) }
    return model
  }

  func key(_ model: PanelModel, _ code: UInt16, _ chars: String = "", editing: Bool = false,
           _ modifiers: NSEvent.ModifierFlags = []) -> Bool {
    model.handleKey(code: code, characters: chars, modifiers: modifiers, editing: editing)
  }

  // MARK: search

  func testAddSearchFindsAndAddsACity() {
    let model = makeModel()
    model.startSearch(.add)
    model.setQuery(.add, "reyk")
    XCTAssertEqual(model.matches(.add).first?.label, "Reykjavik")
    model.pickSelected(.add)
    XCTAssertEqual(model.zones.last?.id, "Atlantic/Reykjavik")
    XCTAssertFalse(model.addSearch.active, "picking closes the search")
  }

  func testTheAddSearchLeavesOutCitiesAlreadyListed() {
    let model = makeModel()
    model.startSearch(.add)
    model.setQuery(.add, "tokyo")
    XCTAssertFalse(model.matches(.add).contains { $0.label == "Tokyo" && $0.value == "Asia/Tokyo" })
  }

  func testOnlyOneListSearchIsOpenAtATime() {
    let model = makeModel()
    model.startSearch(.add)
    model.startChoosingHere()
    XCTAssertTrue(model.hereSearch.active)
    XCTAssertFalse(model.addSearch.active)
  }

  func testTheKeysDriveAnOpenSearch() {
    let model = makeModel()
    model.startSearch(.add)
    model.setQuery(.add, "san")
    XCTAssertGreaterThan(model.matches(.add).count, 1)
    XCTAssertTrue(key(model, down, editing: true))
    XCTAssertEqual(model.addSearch.selectedIndex, 1)
    XCTAssertFalse(key(model, 0, "x", editing: true), "typing goes to the field")
    XCTAssertTrue(key(model, escape, editing: true))
    XCTAssertFalse(model.addSearch.active)
  }

  // MARK: focus

  func testFocusFollowsItsCityThroughAReorder() {
    let model = makeModel()
    model.focusOn(3)
    XCTAssertEqual(model.focusZone.label, "Tokyo")
    model.setZones(Model.moveZone(model.zones, from: 3, to: 0))
    XCTAssertEqual(model.focusIndex, 0)
    XCTAssertEqual(model.focusZone.label, "Tokyo")
  }

  func testTheArrowsWalkHomeEachCityAndAddACity() {
    let model = makeModel([Snapshots.cities[0], Snapshots.cities[3]])
    XCTAssertEqual(model.focusIndex, -1, "home first")
    model.moveFocus(1)
    XCTAssertEqual(model.focusIndex, 0)
    model.moveFocus(1)
    XCTAssertEqual(model.focusIndex, 1)
    model.moveFocus(1)
    XCTAssertTrue(model.addSelected)
    model.moveFocus(1)
    XCTAssertEqual(model.focusIndex, -1, "and round again")
    XCTAssertFalse(model.addSelected)
  }

  func testDeletingThePickedCityPicksTheNext() {
    let model = makeModel()
    model.focusOn(1)
    XCTAssertTrue(key(model, 51))
    XCTAssertEqual(model.zones.map(\.label), ["Kyiv", "Tbilisi", "Tokyo", "Sydney"])
    XCTAssertEqual(model.focusZone.label, "Tbilisi")

    let one = makeModel([Snapshots.cities[0]])
    one.focusOn(0)
    one.deleteFocused()
    XCTAssertEqual(one.zones.count, 1, "the last city stays")
  }

  // MARK: here

  func testHereOnThisZoneRenamesItsRowAndKeepsItsPeople() {
    var kyiv = Snapshots.cities[0]
    kyiv.people = ["Emir"]
    let model = makeModel([kyiv, Snapshots.cities[3]])
    XCTAssertEqual(model.homeCity, "Kyiv")
    model.setHere(City(label: "Lviv", id: "Europe/Kyiv", lat: 49.84, lon: 24.03, region: "Lviv Oblast, UA"))
    XCTAssertEqual(model.homeCity, "Lviv")
    XCTAssertEqual(model.zones[0].label, "Lviv")
    XCTAssertEqual(model.zones[0].people, ["Emir"])
    XCTAssertTrue(model.hereLine.hasSuffix("here in Lviv"))
  }

  func testHereOnAnotherZoneWaitsForThisMacsClock() async {
    let model = makeModel()
    let asked = expectation(description: "asked to move the clock")
    model.onMoveClock = { city, zone in
      XCTAssertEqual(city, "Tokyo")
      XCTAssertEqual(zone, "Asia/Tokyo")
      asked.fulfill()
    }
    model.setHere(City(label: "Tokyo", id: "Asia/Tokyo"))
    await fulfillment(of: [asked], timeout: 2)
    XCTAssertEqual(model.homeCity, "Kyiv", "here moves only once the clock has")
    XCTAssertEqual(model.pendingHere?.id, "Asia/Tokyo")
  }

  // MARK: keys and time

  func testEscapeUnwindsOneLayerAtATime() {
    let model = makeModel()
    model.onClose = { [unowned self] in self.closes += 1 }

    XCTAssertTrue(key(model, right))
    XCTAssertEqual(model.scrubMinutes, 60)
    XCTAssertTrue(model.hereLine.hasSuffix("+1h"))
    XCTAssertTrue(key(model, space))
    XCTAssertTrue(model.globeMode)

    XCTAssertTrue(key(model, escape))
    XCTAssertEqual(model.scrubMinutes, 0, "first the shifted time")
    XCTAssertTrue(model.globeMode)
    XCTAssertTrue(key(model, escape))
    XCTAssertFalse(model.globeMode, "then the globe")
    XCTAssertEqual(closes, 0)
    XCTAssertTrue(key(model, escape))
    XCTAssertEqual(closes, 1, "then the panel")
  }

  func testTheLetterKeysFlipTheNotation() {
    let model = makeModel()
    XCTAssertEqual(model.clockRow(model.zones[0]).time, "1:40")
    XCTAssertTrue(key(model, 17, "t"))
    XCTAssertEqual(model.clockRow(model.zones[0]).time, "13:40")
    XCTAssertTrue(key(model, 17, "t", .option))
    XCTAssertEqual(model.units, "F")
    XCTAssertEqual(model.tempLabel(model.zones[0]), "65°F")
  }

  func testScrubbingLandsOnTheNearestOccurrenceOfATime() {
    let model = makeModel()
    let tokyo = model.clockRow(model.zones[3])
    XCTAssertEqual(tokyo.time, "7:40")
    model.beginScrub(tokyo, 0.5)
    XCTAssertEqual(model.scrubMinutes, -460, "noon in Tokyo is 7h40m back")
    XCTAssertEqual(model.clockRow(model.zones[3]).time, "12:00")
  }

  func testDraggingARowReordersOnDrop() async throws {
    let model = makeModel()
    model.beginRowDrag(0, pitch: 80, pitches: [80, 80, 80, 80, 80])
    model.moveRowDrag(170)
    XCTAssertEqual(model.dragTarget, 2)
    XCTAssertEqual(model.rowShift(1), -80, "the rows it passes step aside")
    XCTAssertEqual(model.zones[0].label, "Kyiv", "nothing moves until the drop")
    model.releaseRowDrag()
    try await Task.sleep(nanoseconds: 600_000_000)
    XCTAssertEqual(model.zones.map(\.label), ["Los Angeles", "Tbilisi", "Kyiv", "Tokyo", "Sydney"])
    XCTAssertEqual(model.dragIndex, -1)
  }

  // MARK: the menu bar and settings

  func testTheMenuBarClock() {
    let model = makeModel()
    XCTAssertNil(model.menuBarText())
    model.menuBarCity = model.zones[3].key
    XCTAssertEqual(model.menuBarText(), "Tokyo 7:40 PM")
    model.hour24Setting = true
    XCTAssertEqual(model.menuBarText(), "Tokyo 19:40")
    model.removeCityAt(3)
    XCTAssertNil(model.menuBarText(), "a removed city leaves the icon alone")
  }

  func testSettingsSurviveARestart() {
    let suite = "io.github.slavawild.Elsewhen.tests.\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    let first = PanelModel(defaults: defaults, persists: true, network: false, localZone: "Europe/Kyiv")
    XCTAssertEqual(first.zones.first?.id, "Europe/Kyiv", "a first run seeds around home")
    XCTAssertEqual(first.zones.count, 5)
    first.unitsSetting = "F"
    first.hour24Setting = true
    first.offsetMode = .utc
    first.menuBarCity = first.zones[1].key
    first.setZones(Model.moveZone(first.zones, from: 1, to: 0))

    let second = PanelModel(defaults: defaults, persists: true, network: false, localZone: "Europe/Kyiv")
    XCTAssertEqual(second.unitsSetting, "F")
    XCTAssertEqual(second.hour24Setting, true)
    XCTAssertEqual(second.offsetMode, .utc)
    XCTAssertEqual(second.menuBarCity, first.menuBarCity)
    XCTAssertEqual(second.zones, first.zones)
    defaults.removePersistentDomain(forName: suite)
  }
}
