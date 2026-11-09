import Foundation

/// A wall clock's calendar fields. `month` runs 1...12, `weekday` 0 (Sunday)...6.
public struct ZoneParts: Equatable, Sendable {
  public var year: Int
  public var month: Int
  public var day: Int
  public var weekday: Int
  public var hour: Int
  public var minute: Int

  public init(year: Int = 2000, month: Int = 1, day: Int = 1, weekday: Int = 0, hour: Int, minute: Int) {
    self.year = year
    self.month = month
    self.day = day
    self.weekday = weekday
    self.hour = hour
    self.minute = minute
  }
}

/// What the clock knows of a zone at an instant: its abbreviation and UTC offset.
public struct ZoneInfo: Equatable, Sendable {
  public var abbr: String
  public var offsetMinutes: Int

  public init(abbr: String, offsetMinutes: Int) {
    self.abbr = abbr
    self.offsetMinutes = offsetMinutes
  }

  /// Read from the system's tz database. macOS has Intl where QML had none,
  /// so this needs no `date` probe, and it is right on either side of a DST change.
  public static func of(_ zone: String, atMs ms: Double) -> ZoneInfo? {
    guard let tz = TimeZone(identifier: zone) else { return nil }
    let date = Date(timeIntervalSince1970: ms / 1000)
    let offset = tz.secondsFromGMT(for: date) / 60
    return ZoneInfo(abbr: tz.abbreviation(for: date) ?? Model.utcOffsetLabel(offset, words: .english), offsetMinutes: offset)
  }
}

/// Everything a row shows; `ready` is false while the zone is unknown.
public struct ClockRow: Equatable, Sendable {
  public enum Phase: String, Sendable { case night, dawn, day, dusk }

  public var label: String
  public var id: String
  public var people: [String]
  public var ready: Bool
  public var abbr = ""
  public var offsetMinutes = 0
  public var time = ""
  public var hour = 0
  public var meridiem = ""
  public var date = ""
  public var dayLabel = ""
  public var phase: Phase = .day
  public var lit = false
  public var progress = 0.0
  public var relative = ""
}

extension Model {
  static let utc: TimeZone = TimeZone(identifier: "UTC")!

  static let gregorianUTC: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = utc
    return c
  }()

  /// Shifting the instant by the offset and reading UTC fields gives the zone's wall clock.
  public static func zoneParts(_ ms: Double, offsetMinutes: Int) -> ZoneParts {
    let date = Date(timeIntervalSince1970: (ms + Double(offsetMinutes) * 60000) / 1000)
    let c = gregorianUTC.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
    return ZoneParts(year: c.year!, month: c.month!, day: c.day!, weekday: c.weekday! - 1, hour: c.hour!, minute: c.minute!)
  }

  /// The wall clock of this Mac's own zone.
  public static func localParts(_ ms: Double, zone: TimeZone = .current) -> ZoneParts {
    zoneParts(ms, offsetMinutes: zone.secondsFromGMT(for: Date(timeIntervalSince1970: ms / 1000)) / 60)
  }

  /// Calendar fields only, so DST cannot skew the count.
  public static func dayDelta(_ parts: ZoneParts, _ reference: ZoneParts) -> Int {
    func days(_ p: ZoneParts) -> Int {
      let d = gregorianUTC.date(from: DateComponents(year: p.year, month: p.month, day: p.day))!
      return Int((d.timeIntervalSince1970 / 86400).rounded())
    }
    return days(parts) - days(reference)
  }

  public static func dayLabel(_ delta: Int, words: Words) -> String {
    switch delta {
    case 0: return ""
    case 1: return words.t("elsewhen.tomorrow", "Tomorrow")
    case -1: return words.t("elsewhen.yesterday", "Yesterday")
    default:
      return delta > 0
        ? Words.fill(words.tn("elsewhen.daysAhead", delta, "+%1 day", "+%1 days"), words.fmt(Double(delta), nil))
        : Words.fill(words.tn("elsewhen.daysBehind", -delta, "-%1 day", "-%1 days"), words.fmt(Double(-delta), nil))
    }
  }

  static func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

  public static func formatTime(_ parts: ZoneParts, hour24: Bool, words: Words) -> String {
    if hour24 { return words.digits(pad2(parts.hour) + ":" + pad2(parts.minute)) }
    var h = parts.hour % 12
    if h == 0 { h = 12 }
    return words.digits("\(h):" + pad2(parts.minute))
  }

  public static func meridiem(_ parts: ZoneParts, words: Words) -> String {
    parts.hour < 12 ? words.am : words.pm
  }

  /// "14:05" or "2:05 PM" at a zone offset; "" before the offset is known.
  public static func formatClock(_ ms: Double, offsetMinutes: Int?, hour24: Bool, words: Words) -> String {
    guard let offsetMinutes else { return "" }
    let parts = zoneParts(ms, offsetMinutes: offsetMinutes)
    return formatTime(parts, hour24: hour24, words: words) + (hour24 ? "" : " " + meridiem(parts, words: words))
  }

  // Fixed civil hours, used until a city's real sunrise is known.
  static let dayStart = 6, dayEnd = 18, dawnEnd = 8, duskStart = 17

  public static func phaseFor(_ parts: ZoneParts) -> ClockRow.Phase {
    let h = parts.hour
    if h < dayStart || h >= dayEnd + 2 { return .night }
    if h < dawnEnd { return .dawn }
    if h < duskStart { return .day }
    return .dusk
  }

  public static func dayProgress(_ parts: ZoneParts) -> Double {
    Double(parts.hour * 60 + parts.minute) / 1440
  }

  public static var daylightStart: Double { Double(dayStart) / 24 }
  public static var daylightEnd: Double { Double(dayEnd) / 24 }

  public static func inDaylight(_ progress: Double) -> Bool {
    progress >= daylightStart && progress < daylightEnd
  }

  /// Absolute offset: "UTC+2", "UTC-3:30", "UTC".
  public static func utcOffsetLabel(_ minutes: Int?, words: Words) -> String {
    guard let total = minutes else { return "" }
    if total == 0 { return "UTC" }
    let a = abs(total), hours = a / 60, mins = a % 60
    return "UTC" + (total < 0 ? "-" : "+") + words.digits("\(hours)" + (mins == 0 ? "" : ":" + pad2(mins)))
  }

  /// "+9h" or "-3.5h" from the viewer's clock; "" on the viewer's own offset.
  public static func relativeOffsetLabel(_ zoneOffset: Int, _ localOffset: Int, words: Words) -> String {
    let diff = zoneOffset - localOffset
    if diff == 0 { return "" }
    let hours = (Double(diff) / 60 * 10).rounded() / 10
    return (diff > 0 ? "+" : "") + Words.fill(words.t("elsewhen.hoursShort", "%1h"), words.fmt(hours, nil))
  }

  /// Everything a row needs at `ms`. The zone's offset is read at that same
  /// instant, so a scrub across a DST change shows the clock as it will be.
  public static func rowFor(_ zone: City, info: ZoneInfo?, ms: Double, localZone: TimeZone, hour24: Bool, words: Words) -> ClockRow {
    guard let info else { return ClockRow(label: zone.label, id: zone.id, people: zone.people, ready: false) }
    let parts = zoneParts(ms, offsetMinutes: info.offsetMinutes)
    let here = localParts(ms, zone: localZone)
    let localOffset = localZone.secondsFromGMT(for: Date(timeIntervalSince1970: ms / 1000)) / 60
    let phase = phaseFor(parts)
    var row = ClockRow(label: zone.label, id: zone.id, people: zone.people, ready: true)
    row.abbr = info.abbr
    row.offsetMinutes = info.offsetMinutes
    row.time = formatTime(parts, hour24: hour24, words: words)
    row.hour = parts.hour
    row.meridiem = hour24 ? "" : meridiem(parts, words: words)
    row.date = words.date(parts)
    row.dayLabel = dayLabel(dayDelta(parts, here), words: words)
    row.phase = phase
    row.progress = dayProgress(parts)
    row.lit = inDaylight(row.progress)
    row.relative = relativeOffsetLabel(info.offsetMinutes, localOffset, words: words)
    return row
  }

  // ---- notation

  /// Only a 12-hour pattern has an AM/PM designator once quoted literals are stripped.
  public static func usesTwentyFourHour(_ pattern: String) -> Bool {
    var stripped = ""
    var quoted = false
    for ch in pattern {
      if ch == "'" { quoted.toggle(); continue }
      if !quoted { stripped.append(ch) }
    }
    return !stripped.contains("a") && !stripped.contains("A")
  }

  /// An explicit "C" or "F" wins; anything else follows the system.
  public static func resolveUnits(_ setting: String?, auto: String) -> String {
    let explicit = (setting ?? "").trimmingCharacters(in: .whitespaces).uppercased()
    if explicit == "C" || explicit == "F" { return explicit }
    return auto.uppercased() == "F" ? "F" : "C"
  }

  public static func formatTemp(_ celsius: Double?, units: String, words: Words) -> String {
    guard let celsius else { return "" }
    if units.uppercased() == "C" { return words.fmt(celsius.rounded(), nil) + "°C" }
    return words.fmt((celsius * 9 / 5 + 32).rounded(), nil) + "°F"
  }

  // ---- scrubbing

  /// The nearest occurrence of the local time under the pointer, in (-720, 720].
  public static func scrubDeltaMinutes(_ fraction: Double, cityLocalMinutes: Double) -> Double {
    let target = max(0, min(1, fraction)) * 1440
    var delta = target - cityLocalMinutes
    while delta > 720 { delta -= 1440 }
    while delta <= -720 { delta += 1440 }
    return delta
  }

  /// Round before splitting into hour and minute, and wrap after, so 419.8 is "7:00".
  public static func formatMinuteOfDay(_ minute: Double, hour24: Bool, words: Words) -> String {
    var m = Int(minute.rounded())
    m = ((m % 1440) + 1440) % 1440
    let parts = ZoneParts(hour: m / 60, minute: m % 60)
    return formatTime(parts, hour24: hour24, words: words) + (hour24 ? "" : " " + meridiem(parts, words: words))
  }

  /// "+3h", "-45m", "" for now.
  public static func formatScrubDelta(_ minutes: Double, words: Words) -> String {
    let m = Int(minutes.rounded())
    if m == 0 { return "" }
    let a = abs(m)
    let d = a / 1440, h = a % 1440 / 60, rem = a % 60
    var parts: [String] = []
    if d > 0 { parts.append(Words.fill(words.t("elsewhen.daysShort", "%1d"), words.fmt(Double(d), nil))) }
    if h > 0 { parts.append(Words.fill(words.t("elsewhen.hoursShort", "%1h"), words.fmt(Double(h), nil))) }
    if rem > 0 { parts.append(Words.fill(words.t("elsewhen.minutesShort", "%1m"), words.fmt(Double(rem), nil))) }
    return (m > 0 ? "+" : "-") + parts.joined(separator: " ")
  }
}
