import Foundation

/// The words the clocks, dates and offsets read in. The app passes words built
/// from its localized strings and the user's locale; without them, as in the
/// tests, everything reads in English.
/// Its closures may hold formatters; a Words value is built and read on one thread at a time.
public struct Words: @unchecked Sendable {
  /// A catalog string by key, with its English text as the fallback.
  public var t: (_ key: String, _ english: String) -> String
  /// A counted catalog string: key, count, English singular and plural.
  public var tn: (_ key: String, _ count: Int, _ one: String, _ other: String) -> String
  /// A number in the language's own digits and decimal separator.
  public var fmt: (_ value: Double, _ decimals: Int?) -> String
  public var am: String
  public var pm: String
  /// A short date: "Mon Nov 9".
  public var date: (_ parts: ZoneParts) -> String

  public init(
    t: @escaping (String, String) -> String,
    tn: @escaping (String, Int, String, String) -> String,
    fmt: @escaping (Double, Int?) -> String,
    am: String,
    pm: String,
    date: @escaping (ZoneParts) -> String
  ) {
    self.t = t
    self.tn = tn
    self.fmt = fmt
    self.am = am
    self.pm = pm
    self.date = date
  }

  public static let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
  public static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

  public static let english = Words(
    t: { _, english in english },
    tn: { _, count, one, other in (count == 1 ? one : other) },
    fmt: { value, decimals in Words.plainNumber(value, decimals) },
    am: "AM",
    pm: "PM",
    date: { parts in
      String(weekdays[parts.weekday].prefix(3)) + " " + months[parts.month - 1] + " " + String(parts.day)
    }
  )

  /// JavaScript's String(n) for the numbers this app prints: "9", "-3.5".
  public static func plainNumber(_ value: Double, _ decimals: Int?) -> String {
    if let decimals { return String(format: "%.\(decimals)f", value) }
    if value.rounded() == value, abs(value) < 1e15 { return String(Int(value)) }
    var text = String(value)
    if text.hasSuffix(".0") { text.removeLast(2) }
    return text
  }

  /// Fills a catalog string's %1 (and %2).
  public static func fill(_ text: String, _ first: String, _ second: String? = nil) -> String {
    var out = text.replacingOccurrences(of: "%1", with: first)
    if let second { out = out.replacingOccurrences(of: "%2", with: second) }
    return out
  }

  /// A string's ASCII digits in the language's own ("14:05" is "۱۴:۰۵" in Persian).
  public func digits(_ text: String) -> String {
    var out = ""
    for ch in text {
      if let d = ch.wholeNumberValue, ch.isASCII { out += fmt(Double(d), nil) } else { out.append(ch) }
    }
    return out
  }
}
