import Foundation

struct ShellResult: Sendable {
  var status: Int32
  /// stdout and stderr, interleaved.
  var output: String
}

enum Shell {
  /// Runs a tool without a shell (arguments are passed as-is) and waits for
  /// it off the main thread.
  static func run(_ tool: String, _ arguments: [String]) async throws -> ShellResult {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return continuation.resume(throwing: error) }
        // Read before waiting: a child that fills the pipe would never exit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        continuation.resume(
          returning: ShellResult(
            status: process.terminationStatus, output: String(decoding: data, as: UTF8.self)))
      }
    }
  }

  /// Runs a tool and throws when it fails.
  @discardableResult static func check(_ tool: String, _ arguments: [String]) async throws
    -> ShellResult
  {
    let result = try await run(tool, arguments)
    guard result.status == 0 else {
      throw UpdateError.installFailed(
        "\((tool as NSString).lastPathComponent) failed (\(result.status)): \(result.output)")
    }
    return result
  }

  /// `text` as one single-quoted sh word.
  static func quote(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// `text` as an AppleScript string literal.
  static func appleScriptString(_ text: String) -> String {
    "\""
      + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
        of: "\"", with: "\\\"") + "\""
  }
}
