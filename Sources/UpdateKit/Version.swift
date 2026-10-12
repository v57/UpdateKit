import Foundation

/// A dotted version such as "1.2", "v1.10.3" or "2.0-beta.2", compared
/// numerically ("1.10" > "1.9", "1.0" == "1"). A pre-release ("-beta.2") sorts
/// before the same version without one.
public struct Version: Comparable, Sendable, CustomStringConvertible {
  public let components: [Int]
  public let prerelease: String?
  public let description: String

  public init(_ string: String) {
    var text = string.trimmingCharacters(in: .whitespaces)
    if text.first == "v" || text.first == "V" { text.removeFirst() }
    description = text
    let parts = text.split(separator: "-", maxSplits: 1)
    components = (parts.first ?? "").split(separator: ".").map { part in
      Int(part.prefix { $0.isNumber }) ?? 0
    }
    prerelease = parts.count > 1 ? String(parts[1]) : nil
  }

  public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }

  public static func < (a: Version, b: Version) -> Bool {
    for i in 0..<max(a.components.count, b.components.count) {
      let l = i < a.components.count ? a.components[i] : 0
      let r = i < b.components.count ? b.components[i] : 0
      if l != r { return l < r }
    }
    switch (a.prerelease, b.prerelease) {
    case (nil, _): return false
    case (_, nil): return true
    case (let l?, let r?): return l.compare(r, options: .numeric) == .orderedAscending
    }
  }
}
