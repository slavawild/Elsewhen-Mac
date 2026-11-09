import AppKit
import ElsewhenCore
import QuartzCore
import SwiftUI

// MARK: - Strings

/// The app's strings: Omarchy's own catalog for the panel, plus the macOS-only ones.
enum L10n {
  static let bundle: Bundle = CoreResources.locate("Elsewhen_Elsewhen") ?? Bundle.module

  static func t(_ key: String, _ english: String) -> String {
    bundle.localizedString(forKey: key, value: english, table: nil)
  }

  static func t(_ key: String, _ english: String, _ first: String, _ second: String? = nil) -> String {
    Words.fill(t(key, english), first, second)
  }

  /// A counted string from the stringsdict, in the language's plural rules.
  static func plural(_ key: String, _ count: Int, one: String, other: String) -> String {
    let format = bundle.localizedString(forKey: key, value: "", table: nil)
    if format.isEmpty || format == key {
      return Words.fill(count == 1 ? one : other, String(count))
    }
    return String.localizedStringWithFormat(format, count)
  }

  /// The words the clocks and dates read in, in this Mac's language and region.
  static func words(locale: Locale = .current) -> Words {
    let number = NumberFormatter()
    number.locale = locale
    number.usesGroupingSeparator = false
    let symbols = DateFormatter()
    symbols.locale = locale
    let date = DateFormatter()
    date.locale = locale
    date.timeZone = TimeZone(identifier: "UTC")
    date.setLocalizedDateFormatFromTemplate("EEEMMMd")
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!

    func fmt(_ value: Double, _ decimals: Int?) -> String {
      number.minimumFractionDigits = decimals ?? 0
      number.maximumFractionDigits = decimals ?? 1
      return number.string(from: NSNumber(value: value)) ?? Words.plainNumber(value, decimals)
    }

    var words = Words(
      t: { key, english in L10n.t(key, english) },
      tn: { _, _, one, _ in one },
      fmt: fmt,
      am: symbols.amSymbol ?? "AM",
      pm: symbols.pmSymbol ?? "PM",
      date: { parts in
        let day = utc.date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day, hour: 12)) ?? Date()
        return date.string(from: day)
      }
    )
    let digits = words
    words.tn = { key, count, one, other in digits.digits(L10n.plural(key, count, one: one, other: other)) }
    return words
  }

  /// The system's own clock notation, which an explicit setting overrides.
  static var systemUses24Hour: Bool {
    let pattern = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? "h a"
    return Model.usesTwentyFourHour(pattern)
  }

  /// Only the US measurement system means Fahrenheit.
  static var systemUnits: String {
    if #available(macOS 13, *) { return Locale.current.measurementSystem == .us ? "F" : "C" }
    return Locale.current.usesMetricSystem ? "C" : "F"
  }
}

// MARK: - Colour

/// An opaque colour that can be mixed: the panel's surfaces blend foreground
/// into background rather than laying translucent ink over it, so knocked rows
/// and the arriving globe stay solid as they pass over one another.
struct RGB: Equatable {
  var r: Double
  var g: Double
  var b: Double

  init(_ r: Double, _ g: Double, _ b: Double) {
    self.r = r
    self.g = g
    self.b = b
  }

  init(hex: UInt32) {
    self.init(Double((hex >> 16) & 0xff) / 255, Double((hex >> 8) & 0xff) / 255, Double(hex & 0xff) / 255)
  }

  init(_ color: NSColor) {
    let c = color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0.48, blue: 1, alpha: 1)
    self.init(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
  }

  func mix(_ to: RGB, _ t: Double) -> RGB {
    RGB(r + (to.r - r) * t, g + (to.g - g) * t, b + (to.b - b) * t)
  }

  var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }
  func color(_ alpha: Double) -> Color { Color(.sRGB, red: r, green: g, blue: b, opacity: alpha) }
}

struct Theme: Equatable {
  var foreground: RGB
  var background: RGB
  var accent: RGB
  /// A literal gold: the sun on the strips and the lit cities on the globe.
  var daylight = RGB(hex: 0xE5C736)

  var dim: RGB { background.mix(foreground, 0.64) }
  var fainter: RGB { background.mix(foreground, 0.42) }

  static func current(_ scheme: ColorScheme) -> Theme {
    let accent = RGB(NSColor.controlAccentColor)
    return scheme == .dark
      ? Theme(foreground: RGB(0.93, 0.93, 0.94), background: RGB(0.135, 0.135, 0.145), accent: accent)
      : Theme(foreground: RGB(0.11, 0.11, 0.12), background: RGB(0.965, 0.965, 0.97), accent: accent)
  }
}

/// The type and spacing scale the panel is drawn to.
enum Style {
  static let caption: CGFloat = 11.5
  static let bodySmall: CGFloat = 13
  static let subtitle: CGFloat = 15
  static let heading: CGFloat = 20
  static let title: CGFloat = 23
  static let display: CGFloat = 27

  static let panelWidth: CGFloat = 340
  static let panelMaxHeight: CGFloat = 680
  static let panelPadding: CGFloat = 16
  static let panelGap: CGFloat = 12
  static let rowGap: CGFloat = 8
  static let rowPaddingX: CGFloat = 14
  static let cornerRadius: CGFloat = 10
  static let globeStageHeight: CGFloat = 378

  static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: size, weight: weight)
  }

  static func nsFont(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    .systemFont(ofSize: size, weight: weight)
  }

  static func width(_ text: String, _ font: NSFont) -> CGFloat {
    ceil((text as NSString).size(withAttributes: [.font: font]).width)
  }
}

// MARK: - Motion

/// A frame-driven tween. SwiftUI's own animations interpolate views, not the
/// one number - `zoom`, a spin - that a whole transition is a function of.
final class Tween {
  private var timer: Timer?
  private var start: CFTimeInterval = 0
  private var duration: Double = 0
  private var from: Double = 0
  private var to: Double = 0
  private var easing: Easing = .linear
  private var onFrame: (Double) -> Void = { _ in }
  private var onDone: () -> Void = {}

  var running: Bool { timer != nil }

  func run(from: Double, to: Double, duration: Double, easing: Easing,
           onFrame: @escaping (Double) -> Void, onDone: @escaping () -> Void = {}) {
    stop()
    self.from = from
    self.to = to
    self.duration = max(0.001, duration)
    self.easing = easing
    self.onFrame = onFrame
    self.onDone = onDone
    start = CACurrentMediaTime()
    let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
      self?.step()
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    step()
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func step() {
    let t = min(1, (CACurrentMediaTime() - start) / duration)
    onFrame(from + (to - from) * easing(t))
    if t >= 1 {
      stop()
      onDone()
    }
  }
}

/// A repeating timer on the main run loop, in every mode.
final class Ticker {
  private var timer: Timer?

  func start(every interval: TimeInterval, _ action: @escaping () -> Void) {
    stop()
    let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func once(after interval: TimeInterval, _ action: @escaping () -> Void) {
    stop()
    let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
      self?.timer = nil
      action()
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  var running: Bool { timer != nil }
}
