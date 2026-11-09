// swift-tools-version:6.0
import PackageDescription

let package = Package(
  name: "Elsewhen",
  defaultLocalization: "en",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "Elsewhen", targets: ["Elsewhen"])
  ],
  targets: [
    // Everything that is arithmetic or text: no AppKit, so it is testable on its own.
    .target(
      name: "ElsewhenCore",
      resources: [.copy("Resources/world.json"), .copy("Resources/cities.json"), .copy("Resources/greetings.json")]
    ),
    .executableTarget(
      name: "Elsewhen",
      dependencies: ["ElsewhenCore"],
      resources: [.process("Resources")]
    ),
    .testTarget(
      name: "ElsewhenCoreTests",
      dependencies: ["ElsewhenCore"]
    ),
    // The app's own behaviour, and reference images of the panel.
    .testTarget(
      name: "ElsewhenTests",
      dependencies: ["Elsewhen", "ElsewhenCore"],
      resources: [.copy("__Snapshots__")]
    )
  ],
  swiftLanguageModes: [.v6]
)
