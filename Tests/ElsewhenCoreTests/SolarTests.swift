import XCTest
@testable import ElsewhenCore

final class SolarTests: XCTestCase {
  func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Double {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!.timeIntervalSince1970 * 1000
  }

  func testProjection() {
    let center = Solar.project(10, 20, spin: 20, viewLat: 10, r: 100)
    XCTAssertEqual(center.x, 0, accuracy: 1e-9)
    XCTAssertEqual(center.y, 0, accuracy: 1e-9)
    XCTAssertTrue(center.visible)
    XCTAssertFalse(Solar.project(0, 180, spin: 0, viewLat: 0, r: 100).visible)
    XCTAssertLessThan(Solar.project(90, 0, spin: 0, viewLat: 0, r: 100).y, -99)
    XCTAssertGreaterThan(Solar.project(0, 45, spin: 0, viewLat: 0, r: 100).x, 0)
  }

  func testSubsolarPoint() {
    let jun = Solar.subsolarPoint(utc(2026, 6, 21, 12))
    XCTAssertEqual(jun.lat, 23.44, accuracy: 0.5)
    XCTAssertEqual(jun.lon, 0, accuracy: 5)
    XCTAssertEqual(Solar.subsolarPoint(utc(2026, 12, 21, 12)).lat, -23.44, accuracy: 0.5)
    XCTAssertEqual(Solar.subsolarPoint(utc(2026, 6, 21, 18)).lon, -90, accuracy: 5)
    XCTAssertEqual(Solar.solarElevation(jun.lat, jun.lon, jun), 90, accuracy: 0.01)
    XCTAssertFalse(Solar.isDaylight(-jun.lat, jun.lon + 180, jun))
    let term = Solar.terminator(jun, steps: 60)
    XCTAssertEqual(term.count, 61)
    XCTAssertTrue(term.allSatisfy { abs(Solar.solarElevation($0.lat, $0.lon, jun)) < 0.01 })
  }

  func testShortestTurn() {
    let turns = [(0.0, 90.0), (0, -90), (170, -170), (-170, 170), (0, 180), (10, 190)].map { Solar.shortestTurn($0.0, $0.1) }
    XCTAssertEqual(turns, [90, -90, 20, -20, 180, 180])
    XCTAssertEqual(Solar.shortestTurn(1080 + 5, 10), 5, accuracy: 1e-9)
  }

  func testLabelsFlipAtTheEdge() {
    let candidates = [
      Solar.LabelCandidate(index: 0, width: 42, x: 0, y: 0, rank: 1, cosc: 1),
      Solar.LabelCandidate(index: 1, width: 42, x: 2, y: 2, rank: 2, cosc: 1),
      Solar.LabelCandidate(index: 2, width: 42, x: 0, y: 40, rank: 2, cosc: 1)
    ]
    XCTAssertEqual(Solar.layoutLabels(candidates, lineHeight: 12, limit: 10, maxX: nil).map(\.index), [0, 2])
    let edge = [Solar.LabelCandidate(index: 0, width: 42, x: 120, y: 0, rank: 1, cosc: 1)]
    let box = Solar.layoutLabels(edge, lineHeight: 12, limit: 10, maxX: 150)[0].box
    XCTAssertLessThanOrEqual(box.x + box.w, 150)
  }

  func testClippedLandStaysInsideTheDiscAndChangesSmoothly() {
    let r = 28.0
    XCTAssertFalse(GlobeData.land.isEmpty)
    for ring in GlobeData.land {
      XCTAssertTrue(Solar.clipRingToDisc(ring, spin: 137, viewLat: 0, r: r).allSatisfy { hypot($0.x, $0.y) <= r + 0.01 })
    }
    XCTAssertEqual(Solar.clipRingToDisc([0, 0, 1, 0, 1, 1], spin: 180, viewLat: 0, r: r).count, 0)

    func area(_ spin: Double) -> Double {
      GlobeData.land.reduce(0) { total, ring in
        let p = Solar.clipRingToDisc(ring, spin: spin, viewLat: 0, r: r)
        guard p.count > 2 else { return total }
        var a = 0.0
        for i in p.indices {
          let j = (i + 1) % p.count
          a += p[i].x * p[j].y - p[j].x * p[i].y
        }
        return total + abs(a) / 2
      }
    }
    var worst = 0.0
    var previous = area(0)
    var spin = 0.25
    while spin <= 360 {
      let next = area(spin)
      worst = max(worst, abs(next - previous))
      previous = next
      spin += 0.25
    }
    XCTAssertLessThan(worst, Double.pi * r * r * 0.01)
  }

  func testDecimation() {
    let ring = GlobeData.land.max { $0.count < $1.count }!
    let half = Solar.decimateRing(ring)
    XCTAssertEqual(half.count % 2, 0)
    XCTAssertLessThanOrEqual(half.count / 2, ring.count / 4 + 1)
    XCTAssertEqual(Array(half.prefix(2)), Array(ring.prefix(2)))
    XCTAssertEqual(Array(half.suffix(2)), Array(ring.suffix(2)))
  }

  func testMoonPhaseAgainstEclipses() {
    // A solar eclipse falls at new moon, a lunar one at full.
    XCTAssertLessThan(min(Solar.moonPhase(utc(2024, 4, 8, 18, 17)), 1 - Solar.moonPhase(utc(2024, 4, 8, 18, 17))), 0.03)
    XCTAssertEqual(Solar.moonPhase(utc(2025, 3, 14, 6, 58)), 0.5, accuracy: 0.03)
    XCTAssertEqual(Solar.moonLitOutline(0.25, r: 10).count, 50)
  }

  func testSunriseAndSunset() {
    func noon(_ y: Int, _ mo: Int, _ d: Int, _ offset: Int) -> Double { utc(y, mo, d, 12) - Double(offset) * 60000 }
    func parse(_ text: String) -> Double {
      let f = ISO8601DateFormatter()
      return f.date(from: text + ":00Z")!.timeIntervalSince1970 * 1000
    }
    let reference: [(String, Double, Double, (Int, Int, Int), Int, String, String)] = [
      ("Chicago", 41.85, -87.65, (2026, 8, 31), -300, "2026-08-31T11:15", "2026-09-01T00:26"),
      ("Auckland", -36.85, 174.76, (2026, 8, 31), 720, "2026-08-30T18:43", "2026-08-31T05:59"),
      ("Tokyo", 35.69, 139.69, (2026, 8, 31), 540, "2026-08-30T20:12", "2026-08-31T09:11"),
      ("Reykjavik", 64.15, -21.94, (2025, 12, 21), 0, "2025-12-21T11:21", "2025-12-21T15:30"),
      ("Nairobi", -1.29, 36.82, (2026, 3, 20), 180, "2026-03-20T03:36", "2026-03-20T15:43")
    ]
    for (name, lat, lon, date, offset, rise, set) in reference {
      let t = Sun.sunTimes(lat: lat, lon: lon, ms: noon(date.0, date.1, date.2, offset), offsetMinutes: offset)
      XCTAssertEqual(t.kind, .normal, name)
      XCTAssertEqual(t.riseMs ?? 0, parse(rise), accuracy: 2 * 60000, name)
      XCTAssertEqual(t.setMs ?? 0, parse(set), accuracy: 2 * 60000, name)
    }

    let midnightSun = Sun.sunTimes(lat: 78.22, lon: 15.63, ms: noon(2026, 6, 21, 120), offsetMinutes: 120)
    let polarNight = Sun.sunTimes(lat: 78.22, lon: 15.63, ms: noon(2025, 12, 21, 60), offsetMinutes: 60)
    XCTAssertEqual(midnightSun.kind, .midnightSun)
    XCTAssertEqual(polarNight.kind, .polarNight)
    XCTAssertEqual(Sun.litSpans(midnightSun), [Sun.Span(x0: 0, x1: 1)])
    XCTAssertEqual(Sun.litSpans(polarNight), [])

    let solstice = Sun.sunTimes(lat: 64.15, lon: -21.94, ms: noon(2026, 6, 21, 0), offsetMinutes: 0)
    XCTAssertGreaterThan(solstice.setMinutes ?? 0, 1440)
    XCTAssertEqual(Sun.litSpans(solstice).count, 2, "a sunset past midnight lights both ends of the bar")
    XCTAssertEqual([0.0, 60, 180].map { Sun.litAt(solstice, minutes: $0) }, [true, false, true])
    XCTAssertEqual([-30.0, 1500, 0, 1440].map { Sun.eventMark($0) }, [nil, nil, 0, 1])
  }

  func testArcText() {
    let flat = Arc.layout([10, 10], rise: 0)
    XCTAssertEqual(flat.chars.map(\.x), [0, 10])
    let arched = Arc.layout(Array(repeating: 8, count: 20), rise: 6)
    XCTAssertEqual(arched.height, 6, accuracy: 0.05)
    XCTAssertEqual(arched.chars.first!.y, arched.chars.last!.y, accuracy: 1e-9)
    XCTAssertLessThan(arched.chars[10].y, arched.chars[0].y, "the middle sits highest")
    XCTAssertLessThan(arched.chars.first!.rotation, 0)
  }

  func testGreetings() {
    XCTAssertEqual(Greetings.greeting("Etc/GMT+5", hour: 9).text, "Good morning")
    XCTAssertEqual(Greetings.greeting("Asia/Jerusalem", hour: 7).language, "Hebrew")
    XCTAssertEqual(Greetings.greeting("Asia/Jerusalem", hour: 7).roman, "boker tov")
    XCTAssertEqual(Greetings.greeting("Asia/Singapore", hour: 14).text, "Selamat tengah hari")
    XCTAssertEqual(["Pacific/Honolulu", "America/Denver", "America/Montreal", "America/Toronto"].map { Greetings.greeting($0, hour: 9).language },
                   ["Hawaiian", "English", "French", "English"])
    let catalogue = Set(GlobeData.cities.map(\.zone))
    XCTAssertFalse(catalogue.isEmpty)
    XCTAssertEqual(catalogue.filter { Greetings.countryFor($0).isEmpty }, [])
  }
}
