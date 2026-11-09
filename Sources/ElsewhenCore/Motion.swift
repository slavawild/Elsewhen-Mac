import Foundation

extension Model {
  // ---- the globe transition
  // Rows are knocked aside one after another as `zoom` runs 0...1, alternating sides.

  static let knockStagger = 0.09
  static let knockMaxLead = 0.5
  static let knockTiltDegrees = 14.0
  static let knockShrinkBy = 0.18

  public static func knockAt(_ index: Int, _ zoom: Double) -> Double {
    let lead = min(knockMaxLead, Double(index) * knockStagger)
    return max(0, min(1, (zoom - lead) / (1 - lead)))
  }

  public static func knockSide(_ index: Int) -> Double { index % 2 == 0 ? -1 : 1 }

  public static func knockX(_ index: Int, _ zoom: Double, throwX: Double) -> Double {
    knockAt(index, zoom) * knockSide(index) * throwX
  }

  /// Squared, so rows accelerate as they fall.
  public static func knockY(_ index: Int, _ zoom: Double, fall: Double) -> Double {
    let p = knockAt(index, zoom)
    return p * p * fall
  }

  public static func knockTilt(_ index: Int, _ zoom: Double) -> Double {
    knockAt(index, zoom) * knockSide(index) * knockTiltDegrees
  }

  public static func knockShrink(_ index: Int, _ zoom: Double) -> Double {
    1 - knockShrinkBy * knockAt(index, zoom)
  }

  // ---- drag to reorder

  /// Rows the pointer must travel past the held slot before the target moves.
  static let dragHysteresis = 0.6

  /// How many rows a drag of `offset` has passed, each measured by its own pitch.
  public static func rowsPassed(_ dragIndex: Int, _ offset: Double, _ rowPitch: Double, _ pitches: [Double]?) -> Double {
    guard let pitches else { return offset / rowPitch }
    let step = offset < 0 ? -1 : 1
    var left = abs(offset)
    var passed = 0.0
    var i = dragIndex + step
    while i >= 0 && i < pitches.count {
      let pitch = pitches[i] > 0 ? pitches[i] : rowPitch
      if left < pitch { return Double(step) * (passed + left / pitch) }
      left -= pitch
      passed += 1
      i += step
    }
    return Double(step) * (passed + left / rowPitch)
  }

  /// Where the dragged row lands when it drops into `target`: the pitches of the rows it passed.
  public static func dropOffset(_ dragIndex: Int, _ target: Int, _ rowPitch: Double, _ pitches: [Double]?) -> Double {
    if target == dragIndex { return 0 }
    let step = target < dragIndex ? -1 : 1
    var out = 0.0
    var i = dragIndex + step
    while step > 0 ? i <= target : i >= target {
      let pitch = pitches.flatMap { i < $0.count && $0[i] > 0 ? $0[i] : nil } ?? rowPitch
      out += Double(step) * pitch
      i += step
    }
    return out
  }

  public static func dragTargetFor(_ dragIndex: Int, _ dragOffset: Double, _ rowPitch: Double, _ heldTarget: Int, _ count: Int, _ pitches: [Double]?) -> Int {
    if dragIndex < 0 || rowPitch <= 0 { return -1 }
    let raw = rowsPassed(dragIndex, dragOffset, rowPitch, pitches)
    let held = heldTarget < 0 ? 0 : heldTarget - dragIndex
    let next = abs(raw - Double(held)) >= dragHysteresis ? Int(raw.rounded()) : held
    return max(0, min(count - 1, dragIndex + next))
  }

  /// The dragged row follows the pointer; rows it has passed step aside by one pitch.
  public static func rowShift(_ index: Int, _ dragIndex: Int, _ dragTarget: Int, _ dragOffset: Double, _ rowPitch: Double) -> Double {
    if dragIndex < 0 { return 0 }
    if index == dragIndex { return dragOffset }
    if dragIndex < dragTarget && index > dragIndex && index <= dragTarget { return -rowPitch }
    if dragIndex > dragTarget && index >= dragTarget && index < dragIndex { return rowPitch }
    return 0
  }

  // ---- the strip's sunrise arrows

  public static func arrowBox(_ fraction: Double, barWidth: Double, boxWidth: Double, tuck: Double, rising: Bool) -> Double {
    let at = barWidth * fraction
    let pos = rising ? at - boxWidth + tuck : at - tuck
    return max(0, min(barWidth - boxWidth, pos)).rounded()
  }

  public static func arrowCovered(_ boxX: Double, boxWidth: Double, markerCenter: Double, markerWidth: Double, slack: Double) -> Bool {
    abs(markerCenter - (boxX + boxWidth / 2)) < markerWidth / 2 + slack
  }
}

/// The easing curves the transitions use.
public enum Easing: Sendable {
  case linear, outCubic, outQuart, inOutCubic, inOutSine

  public func callAsFunction(_ t: Double) -> Double {
    let x = max(0, min(1, t))
    switch self {
    case .linear: return x
    case .outCubic: return 1 - pow(1 - x, 3)
    case .outQuart: return 1 - pow(1 - x, 4)
    case .inOutCubic: return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    case .inOutSine: return -(cos(Double.pi * x) - 1) / 2
    }
  }
}
