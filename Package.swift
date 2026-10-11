// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "AppUpdater", platforms: [.macOS(.v12)],
  products: [.library(name: "AppUpdater", targets: ["AppUpdater"])],
  targets: [
    .target(name: "AppUpdater"),
    .testTarget(name: "AppUpdaterTests", dependencies: ["AppUpdater"]),
  ])
