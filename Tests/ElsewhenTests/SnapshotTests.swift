import AppKit
import XCTest
@testable import Elsewhen

/// The panel against reference images of its fixed scene, so a change that
/// moves pixels is one somebody meant. A missing reference is recorded, not
/// failed; RECORD_SNAPSHOTS=1 re-records them all into the source tree.
/// SNAPSHOT_OUT, when set, collects every render and any differences.
@MainActor
final class SnapshotTests: XCTestCase {
  /// A pixel differs when a channel is off by more than this, out of 255.
  let channelTolerance = 24
  /// And the image differs when more than this share of pixels do: antialiasing moves a few.
  let pixelTolerance = 0.004

  var references: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("__Snapshots__") }
  var output: URL? { ProcessInfo.processInfo.environment["SNAPSHOT_OUT"].map { URL(fileURLWithPath: $0) } }
  var recording: Bool { ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1" }

  func testListLight() throws { try check("list-light", dark: false, globe: false) }
  func testListDark() throws { try check("list-dark", dark: true, globe: false) }
  func testGlobeLight() throws { try check("globe-light", dark: false, globe: true) }
  func testGlobeDark() throws { try check("globe-dark", dark: true, globe: true) }

  func check(_ name: String, dark: Bool, globe: Bool) throws {
    _ = NSApplication.shared
    let model = Snapshots.model()
    let png = try XCTUnwrap(Snapshots.png(model, dark: dark, globe: globe), "the panel renders")
    let rendered = try XCTUnwrap(Pixels(png))
    XCTAssertGreaterThan(rendered.width, 300)
    XCTAssertGreaterThan(rendered.height, 300)
    XCTAssertGreaterThan(rendered.distinctColours, 50, "something was drawn")

    if let output {
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      try png.write(to: output.appendingPathComponent(name + ".png"))
    }

    let reference = references.appendingPathComponent(name + ".png")
    if recording {
      try png.write(to: reference)
      throw XCTSkip("recorded \(name)")
    }
    guard let data = try? Data(contentsOf: reference) else {
      if let output { try png.write(to: output.appendingPathComponent("new-" + name + ".png")) }
      throw XCTSkip("no reference for \(name) yet; record with RECORD_SNAPSHOTS=1")
    }
    let expected = try XCTUnwrap(Pixels(data))
    XCTAssertEqual(rendered.width, expected.width, "\(name) width")
    XCTAssertEqual(rendered.height, expected.height, "\(name) height")
    guard rendered.width == expected.width, rendered.height == expected.height else { return }
    let share = rendered.differingShare(expected, tolerance: channelTolerance)
    if share > pixelTolerance, let output {
      try png.write(to: output.appendingPathComponent("failed-" + name + ".png"))
    }
    XCTAssertLessThanOrEqual(share, pixelTolerance, "\(name): \(String(format: "%.2f", share * 100))% of pixels differ")
  }
}

/// An image as RGBA bytes, whatever format its PNG was in.
struct Pixels {
  let width: Int
  let height: Int
  let bytes: [UInt8]

  init?(_ data: Data) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    width = image.width
    height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    guard drawn else { return nil }
    self.bytes = bytes
  }

  var distinctColours: Int {
    var seen = Set<UInt32>()
    var i = 0
    while i < bytes.count && seen.count <= 1000 {
      seen.insert(UInt32(bytes[i]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]))
      i += 4 * 7
    }
    return seen.count
  }

  func differingShare(_ other: Pixels, tolerance: Int) -> Double {
    var differing = 0
    var i = 0
    while i < bytes.count {
      for c in 0..<4 where abs(Int(bytes[i + c]) - Int(other.bytes[i + c])) > tolerance {
        differing += 1
        break
      }
      i += 4
    }
    return Double(differing) / Double(width * height)
  }
}
