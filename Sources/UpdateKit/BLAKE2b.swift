import Foundation

/// BLAKE2b (RFC 7693), unkeyed, the hash minisign signs ("prehashed" signatures): fed in pieces, so a release
/// file is hashed without being read into memory at once.
struct BLAKE2b {
  static let blockSize = 128

  private static let iv: [UInt64] = [
    0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b, 0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
    0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f, 0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179,
  ]

  private static let sigma: [[Int]] = [
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
    [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
    [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
    [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
    [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
    [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
    [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
    [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
    [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
  ]

  private var h: [UInt64]
  private var buffer: [UInt8] = []
  /// Bytes compressed so far (RFC 7693's t, whose high word no release file reaches).
  private var counter: UInt64 = 0
  private let length: Int

  /// A hash of `length` bytes (1...64).
  init(length: Int = 64) {
    precondition((1...64).contains(length))
    self.length = length
    h = Self.iv
    h[0] ^= 0x0101_0000 ^ UInt64(length)
    buffer.reserveCapacity(Self.blockSize)
  }

  mutating func update(_ data: some DataProtocol) {
    for region in data.regions {
      region.withUnsafeBytes { raw in
        var bytes = raw[...]
        while !bytes.isEmpty {
          // The last block is compressed only in finalize, flagged as the last: keep a full one back.
          if buffer.count == Self.blockSize {
            counter &+= UInt64(Self.blockSize)
            compress(buffer, last: false)
            buffer.removeAll(keepingCapacity: true)
          }
          let take = min(Self.blockSize - buffer.count, bytes.count)
          buffer.append(contentsOf: bytes.prefix(take))
          bytes = bytes.dropFirst(take)
        }
      }
    }
  }

  mutating func finalize() -> Data {
    counter &+= UInt64(buffer.count)
    compress(buffer + [UInt8](repeating: 0, count: Self.blockSize - buffer.count), last: true)
    var out = Data(capacity: 64)
    for word in h {
      for shift in stride(from: 0, to: 64, by: 8) { out.append(UInt8(truncatingIfNeeded: word >> UInt64(shift))) }
    }
    return out.prefix(length)
  }

  static func hash(_ data: some DataProtocol, length: Int = 64) -> Data {
    var hasher = BLAKE2b(length: length)
    hasher.update(data)
    return hasher.finalize()
  }

  private mutating func compress(_ block: [UInt8], last: Bool) {
    var m = [UInt64](repeating: 0, count: 16)
    for i in 0..<16 {
      var word: UInt64 = 0
      for j in 0..<8 { word |= UInt64(block[i * 8 + j]) << UInt64(8 * j) }
      m[i] = word
    }
    var v = h + Self.iv
    v[12] ^= counter
    if last { v[14] = ~v[14] }
    func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
      v[a] = v[a] &+ v[b] &+ x
      v[d] = (v[d] ^ v[a]).rotatedRight(32)
      v[c] = v[c] &+ v[d]
      v[b] = (v[b] ^ v[c]).rotatedRight(24)
      v[a] = v[a] &+ v[b] &+ y
      v[d] = (v[d] ^ v[a]).rotatedRight(16)
      v[c] = v[c] &+ v[d]
      v[b] = (v[b] ^ v[c]).rotatedRight(63)
    }
    for s in Self.sigma {
      g(0, 4, 8, 12, m[s[0]], m[s[1]])
      g(1, 5, 9, 13, m[s[2]], m[s[3]])
      g(2, 6, 10, 14, m[s[4]], m[s[5]])
      g(3, 7, 11, 15, m[s[6]], m[s[7]])
      g(0, 5, 10, 15, m[s[8]], m[s[9]])
      g(1, 6, 11, 12, m[s[10]], m[s[11]])
      g(2, 7, 8, 13, m[s[12]], m[s[13]])
      g(3, 4, 9, 14, m[s[14]], m[s[15]])
    }
    for i in 0..<8 { h[i] ^= v[i] ^ v[i + 8] }
  }
}

extension UInt64 {
  fileprivate func rotatedRight(_ n: UInt64) -> UInt64 { (self >> n) | (self << (64 - n)) }
}
