// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "Elsewhen",
  defaultLocalization: "en",
  platforms: [.macOS(.v13)],
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
    )
  ]
)
