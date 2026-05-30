import ContextWindow
import Foundation

/// `ToolRunner` shim that emits a `→ tool` / `← tool` log pair around its
/// inner runner. Lives at the registration seam so every tool is observable
/// uniformly, without each tool's body having to remember to log.
///
/// Args are short JSON and logged inline; outputs are truncated via
/// `AssistantLog.truncate` so a 200-row `playlist_contents` blob doesn't
/// dominate the log. See `AssistantLog` for predicate / `log` invocation.
struct LoggedToolRunner: ToolRunner {
  let name: String
  let inner: ToolRunner

  func run(args: Data) async throws -> String {
    let argsString = String(decoding: args, as: UTF8.self)
    // `.info` rather than `.debug` so the tool boundary is persisted to the
    // unified-log store and replayable via `log show --info` — debug-level
    // entries are kept in memory only by default on macOS.
    AssistantLog.logger.info(
      "→ tool \(name, privacy: .public) args=\(argsString, privacy: .public)"
    )
    do {
      let output = try await inner.run(args: args)
      AssistantLog.logger.info(
        "← tool \(name, privacy: .public) out=\(AssistantLog.truncate(output), privacy: .public)"
      )
      return output
    } catch {
      AssistantLog.logger.error(
        "! tool \(name, privacy: .public) threw: \(String(describing: error), privacy: .public)"
      )
      throw error
    }
  }
}
