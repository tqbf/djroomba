import Foundation

// MARK: - ConversationListEntry

/// One row in the assistant's conversation sidebar — the joined view of
/// a `ContextWindow` `Context` (the library's record-bearing unit, name
/// + `startTime`) and our app-side **title** (summarized by
/// `gpt-5.4-mini` when a conversation is archived by "New Request").
///
/// Sorted by `lastActivityAt` descending in the UI. Conversations with
/// no user turns yet (`title == nil` AND no activity past their
/// `startedAt`) read as "New Conversation" in the sidebar so the user
/// can find an unstarted chat they opened then walked away from.
struct ConversationListEntry: Identifiable, Sendable, Equatable, Hashable {
  /// The library's context name — stable string, also the `Identifiable` key.
  let id: String
  /// User-visible title. `nil` until the summarizer has run.
  let title: String?
  /// When this conversation was first opened (`Context.startTime`).
  let startedAt: Date
  /// Last record timestamp; drives the sidebar sort and the relative
  /// timestamp glyph. Falls back to `startedAt` for an empty conversation.
  let lastActivityAt: Date
}

// MARK: - AssistantConversationStore

/// Per-conversation **app-side metadata** that the vendored
/// `ContextWindow` library doesn't model: the summarized title, the
/// cached last-activity timestamp, and the pointer to the currently-
/// selected conversation. All stored in `UserDefaults` because:
///
/// - The volume is tiny (a few hundred bytes per conversation).
/// - The vendored library owns `assistant.sqlite`; sticking a sibling
///   table in there would couple this app to that schema.
/// - A wipe of `UserDefaults` is recoverable — titles re-summarize on
///   demand; the records (the conversation itself) live in SQLite.
///
/// All keys are namespaced under `djroomba.assistant.` so there's no
/// chance of colliding with other `@AppStorage` use.
enum AssistantConversationStore {

  // MARK: Internal

  /// Conventional prefix on every assistant context name. Filters
  /// the library's `listContexts()` results to just our own — defensive
  /// (today only the assistant writes to `assistant.sqlite`, but the
  /// library could grow other consumers).
  static let contextNamePrefix = "djroomba-assistant"

  /// The legacy single-conversation context name from the initial
  /// (pre-multi-conversation) ship. Adopted as the first conversation
  /// for existing users so their history survives the upgrade.
  static let legacyContextName = "djroomba-assistant"

  /// Every stored title, keyed by library context name.
  static func titles() -> [String: String] {
    UserDefaults.standard.dictionary(forKey: Keys.titles) as? [String: String] ?? [:]
  }

  static func title(for contextName: String) -> String? {
    titles()[contextName]
  }

  /// Set / replace the title for one conversation. Stored as a flat dict
  /// (one write per change) so partial reads/writes can't drift.
  static func setTitle(_ title: String, for contextName: String) {
    var all = titles()
    all[contextName] = title
    UserDefaults.standard.set(all, forKey: Keys.titles)
  }

  static func clearTitle(for contextName: String) {
    var all = titles()
    all.removeValue(forKey: contextName)
    UserDefaults.standard.set(all, forKey: Keys.titles)
  }

  /// Cached per-conversation last-activity time. Set on every send so
  /// the sidebar can sort by recency without paginating records out of
  /// every context just to find the most recent.
  static func lastActivity() -> [String: Date] {
    let raw = UserDefaults.standard.dictionary(forKey: Keys.lastActivity) as? [String: Double] ?? [:]
    return raw.mapValues { Date(timeIntervalSince1970: $0) }
  }

  static func setLastActivity(_ date: Date, for contextName: String) {
    var raw = UserDefaults.standard.dictionary(forKey: Keys.lastActivity) as? [String: Double] ?? [:]
    raw[contextName] = date.timeIntervalSince1970
    UserDefaults.standard.set(raw, forKey: Keys.lastActivity)
  }

  static func clearLastActivity(for contextName: String) {
    var raw = UserDefaults.standard.dictionary(forKey: Keys.lastActivity) as? [String: Double] ?? [:]
    raw.removeValue(forKey: contextName)
    UserDefaults.standard.set(raw, forKey: Keys.lastActivity)
  }

  /// The conversation the user was last in. `nil` until they've ever
  /// sent anything; once set, a relaunch resumes here.
  static func currentContextName() -> String? {
    UserDefaults.standard.string(forKey: Keys.currentName)
  }

  static func setCurrentContextName(_ name: String?) {
    if let name {
      UserDefaults.standard.set(name, forKey: Keys.currentName)
    } else {
      UserDefaults.standard.removeObject(forKey: Keys.currentName)
    }
  }

  /// Build a fresh, unique context name for a new conversation.
  static func mintContextName() -> String {
    "\(contextNamePrefix)-\(UUID().uuidString.lowercased())"
  }

  // MARK: Private

  private enum Keys {
    static let titles = "djroomba.assistant.titles"
    static let lastActivity = "djroomba.assistant.lastActivity"
    static let currentName = "djroomba.assistant.currentContextName"
  }
}
