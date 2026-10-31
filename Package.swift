// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "UpdateKit", platforms: [.macOS(.v14)],
  products: [.library(name: "UpdateKit", targets: ["UpdateKit"])],
  targets: [
    .target(name: "UpdateKit", dependencies: [.product(name: "ComponentKit", package: "Component")]),
    .testTarget(name: "UpdateKitTests", dependencies: ["UpdateKit"]),
  ])

// The update window is drawn with ComponentKit (`../Component`): GitHub's main branch, or the checkout next to this
// one with `V57_LOCAL=1`.
package.dependencies.append(
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/Component.git", branch: "main") : .package(path: "../Component"))

#if os(Windows) || os(Linux)
// Off Apple platforms SwiftUI (and Combine) come from v57/SwiftUI: GitHub's main branch, or the checkout next to
// this one with `V57_LOCAL=1`.
package.dependencies.append(
  Context.environment["V57_LOCAL"] == nil
    ? .package(url: "https://github.com/v57/SwiftUI.git", branch: "main") : .package(path: "../SwiftUI"))
for target in package.targets where target.name == "UpdateKit" {
  target.dependencies.append(.product(name: "SwiftUI", package: "SwiftUI"))
}
#endif
