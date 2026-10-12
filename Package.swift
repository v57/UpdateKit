// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "UpdateKit", platforms: [.macOS(.v12)],
  products: [.library(name: "UpdateKit", targets: ["UpdateKit"])],
  targets: [
    .target(name: "UpdateKit"),
    .testTarget(name: "UpdateKitTests", dependencies: ["UpdateKit"]),
  ])
