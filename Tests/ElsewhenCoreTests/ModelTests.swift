import XCTest
@testable import ElsewhenCore

final class ModelTests: XCTestCase {
  let ny = "America/New_York"
  let chi = "America/Chicago"

  func testParsesTheLegacyZonesString() {
    let zones = Model.parseZones("Los Angeles|America/Los_Angeles, Asia/Tokyo, , Bad|$(rm -rf)")
    XCTAssertEqual(zones.map(\.label), ["Los Angeles", "Tokyo"])
    XCTAssertEqual(zones.map(\.id), ["America/Los_Angeles", "Asia/Tokyo"])
    XCTAssertEqual(Model.parseZones(""), [])
  }

  func testStoredCitiesRoundTripInOmarchysShape() throws {
    let json = #"[{"name":"Fort Lauderdale","zone":"America/New_York","lat":26.12,"lon":-80.14,"region":"Florida, US","people":["Emir","@SarahDev"]},{"name":"x","zone":"$(nope)"},{"zone":"Asia/Tokyo"}]"#
    let decoded = try JSONDecoder().decode([City].self, from: Data(json.utf8))
    let cities = Model.normalizeCities(decoded)
    XCTAssertEqual(cities.count, 2)
    XCTAssertEqual(cities[0].lat, 26.12)
    XCTAssertEqual(cities[0].people, ["Emir", "@SarahDev"])
    XCTAssertEqual(cities[1].label, "Tokyo")
    let again = try JSONDecoder().decode([City].self, from: JSONEncoder().encode(cities))
    XCTAssertEqual(again, cities)
  }

  func testAddsRemovesAndMovesCities() {
    let base = [City(label: "New York", id: ny), City(label: "Paris", id: "Europe/Paris")]
    let added = Model.addZone(base, id: ny, label: "Miami")
    XCTAssertEqual(added.map(\.label), ["New York", "Paris", "Miami"])
    XCTAssertEqual(Model.addZone(added, id: ny, label: "Miami"), added, "the same city twice is one row")
    XCTAssertEqual(Model.addZone(base, id: "not a zone", label: "X"), base)

    // A second Springfield in the same zone is a different place when the coordinates say so.
    let il = Model.addZone([], id: chi, label: "Springfield", place: Place(lat: 39.8, lon: -89.65, region: "Illinois, US"))
    let mo = Model.addZone(il, id: chi, label: "Springfield", place: Place(lat: 37.2, lon: -93.3, region: "Missouri, US"))
    XCTAssertEqual(mo.map(\.label), ["Springfield", "Springfield (Missouri)"])

    XCTAssertEqual(Model.removeZoneAt(base, 0).map(\.label), ["Paris"])
    XCTAssertEqual(Model.removeZoneAt([base[0]], 0), [base[0]], "the last city stays")
    XCTAssertEqual(Model.moveZone(added, from: 2, to: 0).map(\.label), ["Miami", "New York", "Paris"])
  }

  func testPeople() {
    XCTAssertEqual(Model.parsePeople("Emir, @sarahdev, emir, @-bad-, , Ana"), ["Emir", "@sarahdev", "-bad-", "Ana"])
    XCTAssertEqual(Model.personHandle("@SarahDev"), "sarahdev")
    XCTAssertEqual(Model.personHandle("Sarah"), "")
    let profiles = ["sarahdev": Profile(login: "SarahDev", name: "Sarah Dev", avatar: "")]
    XCTAssertEqual(Model.personName("@sarahdev", profiles: profiles), "Sarah Dev")
    XCTAssertEqual(Model.personName("@other", profiles: profiles), "other")
    XCTAssertEqual(Model.initialOf("émir"), "É")
    let zones = [City(label: "A", id: ny, people: ["@a", "B"]), City(label: "C", id: chi, people: ["@A", "@c"])]
    XCTAssertEqual(Model.handlesIn(zones), ["a", "c"])
    XCTAssertEqual(Model.setPeopleAt(zones, 0, ["@a", "B"]), zones)
    XCTAssertEqual(Model.setPeopleAt(zones, 0, [])[0].people, [])
  }

  func testWhereHereIs() {
    XCTAssertNil(Model.resolveHere(nil, localZone: ""))
    XCTAssertEqual(Model.resolveHere(nil, localZone: ny)?.city.label, "New York")
    XCTAssertEqual(Model.resolveHere(nil, localZone: ny)?.chosen, false)
    let stored = City(label: "Fort Lauderdale", id: ny, lat: 26.12, lon: -80.14)
    XCTAssertEqual(Model.resolveHere(stored, localZone: ny)?.city.label, "Fort Lauderdale")
    XCTAssertEqual(Model.resolveHere(stored, localZone: chi)?.city.label, "Chicago", "a trip resets here on its own")

    let seeded = [City(label: "New York", id: ny), City(label: "Amsterdam", id: "Europe/Amsterdam", people: ["Emir"])]
    let guess = Model.resolveHere(nil, localZone: ny)!.city
    let moved = Model.hereAfterPick(seeded, current: guess, pick: City(label: "Fort Lauderdale", id: ny, lat: 26.12, lon: -80.14, region: "Florida, US"), localZone: ny)!
    XCTAssertEqual(moved.zones[0].label, "Fort Lauderdale")
    XCTAssertEqual(moved.zones[1], seeded[1])
    XCTAssertEqual(moved.zoneChange, "")
    let away = Model.hereAfterPick(seeded, current: guess, pick: City(label: "Nashville", id: chi, lat: 36.17, lon: -86.78), localZone: ny)!
    XCTAssertEqual(away.zoneChange, chi)
    XCTAssertEqual(away.zones, seeded)
    XCTAssertNil(Model.hereAfterPick(seeded, current: guess, pick: City(label: "Chicago", id: chi), localZone: ny)!.here)
    XCTAssertNil(Model.hereAfterPick(seeded, current: guess, pick: City(label: "X", id: "$(rm -rf)"), localZone: ny))

    XCTAssertEqual(Model.homeCityAfterTap(label: "Miami", zoneId: ny, homeOverride: "", localZone: ny), "Miami")
    XCTAssertEqual(Model.homeCityAfterTap(label: "New York", zoneId: ny, homeOverride: "Miami", localZone: ny), "")
    XCTAssertNil(Model.homeCityAfterTap(label: "Chicago", zoneId: chi, homeOverride: "", localZone: ny))
  }

  func testSeedsFourWellSpreadCities() {
    let now = Date().timeIntervalSince1970 * 1000
    var offsets: [String: Int] = [:]
    for id in Model.seedCandidateZones() + ["Europe/Kyiv", "America/Denver", "Asia/Kolkata"] {
      offsets[id] = ZoneInfo.of(id, atMs: now)?.offsetMinutes
    }
    for home in ["Europe/Kyiv", "America/Denver", "Asia/Kolkata", "Asia/Tokyo"] {
      let list = Model.seedZones(home: City(label: Model.labelForZoneId(home), id: home), offsets: offsets)
      XCTAssertEqual(list.count, 5, home)
      XCTAssertEqual(list[0].id, home)
      XCTAssertEqual(Set(list.map(\.id)).count, 5, home)
    }
    XCTAssertEqual(Model.seedZones(home: City(label: "Nowhere", id: "Not/AZone"), offsets: offsets).count, 1)
  }

  func testClockFaces() {
    let ms = 1_788_000_000_000.0 // 2026-08-29T10:40:00Z
    let parts = Model.zoneParts(ms, offsetMinutes: 540)
    XCTAssertEqual([parts.hour, parts.minute, parts.month, parts.day, parts.weekday], [19, 40, 8, 29, 6])
    XCTAssertEqual(Model.formatClock(ms, offsetMinutes: 540, hour24: false, words: .english), "7:40 PM")
    XCTAssertEqual(Model.formatClock(ms, offsetMinutes: -420, hour24: true, words: .english), "03:40")
    XCTAssertEqual(Model.formatClock(ms, offsetMinutes: nil, hour24: true, words: .english), "")
    XCTAssertEqual(Words.english.date(parts), "Sat Aug 29")
    XCTAssertEqual(Model.utcOffsetLabel(-210, words: .english), "UTC-3:30")
    XCTAssertEqual(Model.utcOffsetLabel(0, words: .english), "UTC")
    XCTAssertEqual(Model.relativeOffsetLabel(540, -420, words: .english), "+16h")
    XCTAssertEqual(Model.relativeOffsetLabel(-210, 0, words: .english), "-3.5h")
    XCTAssertEqual(Model.relativeOffsetLabel(60, 60, words: .english), "")
    XCTAssertEqual(Model.dayLabel(1, words: .english), "Tomorrow")
    XCTAssertEqual(Model.dayLabel(-2, words: .english), "-2 days")
  }

  func testRowsReadTheSystemTimeZoneDatabase() {
    let ms = 1_788_000_000_000.0
    let tokyo = City(label: "Tokyo", id: "Asia/Tokyo")
    let row = Model.rowFor(tokyo, info: ZoneInfo.of("Asia/Tokyo", atMs: ms), ms: ms,
                           localZone: TimeZone(identifier: "America/Los_Angeles")!, hour24: true, words: .english)
    XCTAssertTrue(row.ready)
    XCTAssertEqual(row.time, "19:40")
    XCTAssertEqual(row.relative, "+16h")
    XCTAssertEqual(row.dayLabel, "", "03:40 in Los Angeles is the same Saturday as 19:40 in Tokyo")
    XCTAssertFalse(Model.rowFor(tokyo, info: nil, ms: ms, localZone: .current, hour24: true, words: .english).ready)
  }

  func testNotation() {
    XCTAssertTrue(Model.usesTwentyFourHour("HH:mm"))
    XCTAssertFalse(Model.usesTwentyFourHour("h:mm a"))
    XCTAssertTrue(Model.usesTwentyFourHour("H 'h' mm 'Uhr'"))
    XCTAssertEqual(Model.resolveUnits("", auto: "F"), "F")
    XCTAssertEqual(Model.resolveUnits("c", auto: "F"), "C")
    XCTAssertEqual(Model.formatTemp(21.6, units: "C", words: .english), "22°C")
    XCTAssertEqual(Model.formatTemp(21.6, units: "F", words: .english), "71°F")
    XCTAssertEqual(Model.weatherKind(0), .sunny)
    XCTAssertEqual(Model.weatherKind(63), .rain)
    XCTAssertEqual(Model.weatherKind(75), .snow)
    XCTAssertNil(Model.weatherKind(nil))
  }

  func testScrubbing() {
    XCTAssertEqual(Model.scrubDeltaMinutes(0.5, cityLocalMinutes: 600), 120)
    XCTAssertEqual(Model.scrubDeltaMinutes(0, cityLocalMinutes: 1380), 60)
    XCTAssertEqual(Model.formatScrubDelta(0, words: .english), "")
    XCTAssertEqual(Model.formatScrubDelta(180, words: .english), "+3h")
    XCTAssertEqual(Model.formatScrubDelta(-45, words: .english), "-45m")
    XCTAssertEqual(Model.formatScrubDelta(1500, words: .english), "+1d 1h")
    XCTAssertEqual(Model.formatMinuteOfDay(419.8, hour24: false, words: .english), "7:00 AM")
  }

  func testDragToReorder() {
    // Hysteresis: half a row is not enough to move, 0.6 is.
    XCTAssertEqual(Model.dragTargetFor(1, 25, 50, 1, 4, nil), 1)
    XCTAssertEqual(Model.dragTargetFor(1, 31, 50, 1, 4, nil), 2)
    XCTAssertEqual(Model.dragTargetFor(1, 500, 50, 1, 4, nil), 3)
    XCTAssertEqual(Model.rowShift(2, 1, 2, 31, 50), -50)
    XCTAssertEqual(Model.rowShift(1, 1, 2, 31, 50), 31)
    XCTAssertEqual(Model.dropOffset(0, 2, 50, [50, 70, 50]), 120)
    XCTAssertEqual(Model.rowsPassed(0, 95, 50, [50, 70, 50]), 1.5, accuracy: 1e-9)
  }

  func testKnockingRowsAside() {
    XCTAssertEqual(Model.knockAt(0, 0), 0)
    XCTAssertEqual(Model.knockAt(3, 1), 1)
    XCTAssertEqual(Model.knockX(0, 1, throwX: 95), -95)
    XCTAssertEqual(Model.knockX(1, 1, throwX: 95), 95)
    XCTAssertLessThan(Model.knockAt(4, 0.3), Model.knockAt(0, 0.3), "rows go one after another")
  }

  func testSearch() {
    let options = Model.zoneOptions(["America/New_York", "Europe/Paris", "UTC", "Asia/Tokyo"], existing: [City(label: "Paris", id: "Europe/Paris")])
    XCTAssertFalse(options.contains { $0.label == "Paris" })
    XCTAssertTrue(options.contains { $0.label == "Miami" && $0.value == ny })
    XCTAssertFalse(options.contains { $0.value == "UTC" })
    let found = Model.searchZones(options, query: "to")
    XCTAssertEqual(found.first?.label, "Tokyo", "name prefixes first")
    XCTAssertEqual(Model.moveSelection(0, -1, 3), 2)
    XCTAssertEqual(Model.placeQuery("  Po  "), "")
    XCTAssertEqual(Model.placeQuery("Port  land"), "port land")
  }

  func testPlaces() {
    let json = #"{"results":[{"name":"Portland","latitude":45.52,"longitude":-122.68,"timezone":"America/Los_Angeles","admin1":"Oregon","country_code":"US"},{"name":"Portland","latitude":43.66,"longitude":-70.26,"timezone":"America/New_York","admin1":"Maine","country_code":"us"},{"name":"Nowhere","timezone":"Bad Zone"}]}"#
    let places = Model.placeOptions(Data(json.utf8))
    XCTAssertEqual(places.map(\.region), ["Oregon, US", "Maine, US"])
    XCTAssertEqual(Model.placeOptions(Data("not json".utf8)), [])

    let offline = [ZoneOption(value: "America/Los_Angeles", label: "Portland")]
    let merged = Model.mergePlaces(offline, places, existing: [])
    XCTAssertEqual(merged.count, 2, "the offline twin borrows the place rather than being listed twice")
    XCTAssertEqual(merged[0].lat, 45.52)
    let tracked = Model.mergePlaces([], places, existing: [City(label: "Portland", id: ny, lat: 43.66, lon: -70.26)])
    XCTAssertEqual(tracked.map(\.region), ["Oregon, US"])

    let pick = Model.pickGeocode(Data(json.utf8), zone: ny)
    XCTAssertEqual(pick.place?.lat, 43.66)
    XCTAssertFalse(Model.pickGeocode(nil, zone: ny).answered)
  }

  func testZoneTabFallback() {
    let tab = "# comment\nJP\t+353916+1394441\tAsia/Tokyo\nUS\t+404251-0740023\tAmerica/New_York\tEastern\n"
    let tokyo = Model.zoneTabCoords(tab, zone: "Asia/Tokyo")
    XCTAssertEqual(tokyo?.lat ?? 0, 35.6544, accuracy: 1e-3)
    XCTAssertEqual(tokyo?.lon ?? 0, 139.7447, accuracy: 1e-3)
    XCTAssertEqual(Model.zoneTabCoords(tab, zone: ny)?.lon ?? 0, -74.0064, accuracy: 1e-3)
    XCTAssertNil(Model.zoneTabCoords(tab, zone: "Europe/Paris"))
  }

  func testForecast() {
    let two = #"[{"current":{"temperature_2m":21.04,"weather_code":2}},{"current":{"temperature_2m":null}}]"#
    let readings = Model.parseForecast(Data(two.utf8), keys: ["a", "b"], nowMs: 5, points: [Place(lat: 1, lon: 2), Place(lat: 3, lon: 4)])
    XCTAssertEqual(readings["a"]?.celsius, 21)
    XCTAssertEqual(readings["a"]?.code, 2)
    XCTAssertNil(readings["b"])
    let one = #"{"current":{"temperature_2m":-3.26,"weather_code":71}}"#
    XCTAssertEqual(Model.parseForecast(Data(one.utf8), keys: ["x"], nowMs: 0)["x"]?.celsius, -3.3)
    let r = readings["a"]!
    XCTAssertFalse(Model.weatherStale(r, nowMs: 1000, coords: Place(lat: 1, lon: 2)))
    XCTAssertTrue(Model.weatherStale(r, nowMs: 1000, coords: Place(lat: 9, lon: 9)))
    XCTAssertTrue(Model.weatherStale(r, nowMs: Model.weatherTTLms + 5, coords: nil))
  }
}
