import Foundation
import os

/// Unified-logging namespace for the assistant / GPT integration.
///
/// One `Logger` under `subsystem = org.sockpuppet.djroomba`,
/// `category = openai`. Use the `log` CLI to tail or replay the
/// conversation without UI:
///
/// ```sh
/// # Live stream:
/// log stream --predicate \
///   'subsystem == "org.sockpuppet.djroomba" AND category == "openai"' \
///   --info --debug
///
/// # Replay last 5 minutes:
/// log show --predicate \
///   'subsystem == "org.sockpuppet.djroomba" AND category == "openai"' \
///   --info --debug --last 5m
/// ```
///
/// Conventions used in this file's call sites:
/// - `→ user`, `← assistant` — chat turn boundaries (`.info`)
/// - `→ tool`, `← tool` — every tool call + its output (`.debug`)
/// - `! error` — anything that broke the round trip (`.error`)
///
/// **What is *not* logged:** the API key, the full system prompt, full
/// tool outputs beyond `logTruncate` (chat-scale JSON blobs are huge —
/// truncating keeps logs scannable). Tool args are short JSON and stay
/// inline.
enum AssistantLog {
  static let logger = Logger(
    subsystem: "org.sockpuppet.djroomba",
    category: "openai",
  )

  /// Hard cap on logged tool-output and user/assistant text. Chosen large
  /// enough to keep most replies intact, small enough that a 200-track
  /// `playlist_contents` blob doesn't blow the log.
  static let logTruncate = 600

  static func truncate(_ string: String, max: Int = logTruncate) -> String {
    string.count > max ? String(string.prefix(max)) + "…[+\(string.count - max)]" : string
  }
}
