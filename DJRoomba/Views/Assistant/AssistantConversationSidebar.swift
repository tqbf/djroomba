import AppKit
import SwiftUI

// MARK: - AssistantConversationSidebar

/// Left column of the DJ Roomba tab: a scrollable list of past
/// conversations + the selection state. Each row gets a coloured
/// avatar circle whose hue is deterministic on the conversation id —
/// the user gets a stable visual "fingerprint" they can scan even
/// when titles are similar. Background carries a faint warm/lavender
/// gradient so the column isn't just flat secondary grey; the
/// gradient endpoints flip in dark mode so it doesn't glow.
///
/// Sized for the docked pane (not a tear-off window): fixed width
/// set by the parent (`AssistantPaneView`), scrolls vertically when
/// long.
struct AssistantConversationSidebar: View {

  // MARK: Internal

  let conversations: [ConversationListEntry]
  let currentID: String?
  let onSelect: (String) -> Void
  let onDelete: (String) -> Void

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      if conversations.isEmpty {
        empty
      } else {
        // `List` instead of `ScrollView + LazyVStack` so `.swipeActions`
        // works — that's the native macOS idiom for trackpad
        // swipe-to-reveal a destructive action. `.listStyle(.plain)`
        // strips the chrome and `.scrollContentBackground(.hidden)`
        // lets the parent gradient show through; row insets / dividers
        // get zeroed so the custom row treatment stays intact.
        List {
          ForEach(conversations) { entry in
            ConversationRow(
              entry: entry,
              isSelected: entry.id == currentID,
              onSelect: { onSelect(entry.id) },
            )
            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
              Button(role: .destructive) {
                onDelete(entry.id)
              } label: {
                Label("Delete", systemImage: "trash")
              }
            }
            // Parallel right-click affordance — `swipeActions` requires a
            // trackpad two-finger swipe (the native gesture), so the
            // context menu gives mouse users + accessibility users a
            // path to the same action.
            .contextMenu {
              Button(role: .destructive) {
                onDelete(entry.id)
              } label: {
                Label("Delete Conversation", systemImage: "trash")
              }
            }
          }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .padding(.vertical, 4)
      }
    }
    .background(sidebarBackground)
  }

  // MARK: Private

  /// Warm cream → cool lavender vertical wash in light mode, deep
  /// indigo → plum in dark mode. NSColor-backed so the AppKit
  /// appearance switch is automatic — no SwiftUI `colorScheme`
  /// plumbing.
  private static let topTint = Color(
    nsColor: NSColor(name: "AssistantSidebarTop") { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      return isDark
        ? NSColor(red: 0.13, green: 0.10, blue: 0.20, alpha: 1)
        : NSColor(red: 1.00, green: 0.97, blue: 0.92, alpha: 1)
    }
  )

  private static let bottomTint = Color(
    nsColor: NSColor(name: "AssistantSidebarBottom") { appearance in
      let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      return isDark
        ? NSColor(red: 0.16, green: 0.11, blue: 0.24, alpha: 1)
        : NSColor(red: 0.96, green: 0.93, blue: 1.00, alpha: 1)
    }
  )

  private var sidebarBackground: some View {
    LinearGradient(
      colors: [Self.topTint, Self.bottomTint],
      startPoint: .top,
      endPoint: .bottom,
    )
  }

  private var header: some View {
    HStack(spacing: 6) {
      Image(systemName: "bubble.left.and.bubble.right.fill")
        .font(.subheadline)
        .foregroundStyle(
          LinearGradient(
            colors: [.purple, .pink],
            startPoint: .topLeading,
            endPoint: .bottomTrailing,
          )
        )
      Text("Conversations")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
      Spacer()
      if !conversations.isEmpty {
        Text("\(conversations.count)")
          .font(.caption2.monospacedDigit().weight(.semibold))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(
            Capsule().fill(.primary.opacity(0.08))
          )
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var empty: some View {
    VStack(spacing: 8) {
      Image(systemName: "sparkles.rectangle.stack.fill")
        .font(.system(size: 30))
        .foregroundStyle(
          LinearGradient(
            colors: [.purple, .pink, .orange],
            startPoint: .topLeading,
            endPoint: .bottomTrailing,
          )
        )
      Text("No conversations yet")
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
      Text("Ask DJ Roomba something to get started.")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .padding()
  }
}

// MARK: - ConversationRow

/// One sidebar entry — coloured avatar circle + title + relative
/// time, with hover + selection treatments. Borderless button so the
/// whole row is one click target.
private struct ConversationRow: View {

  // MARK: Internal

  let entry: ConversationListEntry
  let isSelected: Bool
  let onSelect: () -> Void

  var body: some View {
    Button(action: onSelect) {
      HStack(alignment: .center, spacing: 10) {
        avatar
        VStack(alignment: .leading, spacing: 1) {
          Text(displayTitle)
            .font(.subheadline)
            .fontWeight(isSelected ? .semibold : .regular)
            .lineLimit(2)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(relativeTime)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(rowBackground)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 6)
    .onHover { isHovering = $0 }
  }

  // MARK: Private

  /// Six-stop fun palette for avatar circles. Index is chosen by a
  /// deterministic hash on the conversation id, so a given conversation
  /// keeps the same colour every render and every relaunch — the user
  /// can scan the column by hue.
  private static let avatarPalette: [Color] = [
    .pink,
    .orange,
    .yellow,
    .mint,
    .teal,
    .indigo,
    .purple,
    .red,
  ]

  private static let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  @State private var isHovering = false

  private var hasActivity: Bool {
    // A conversation with no user turn yet has `lastActivityAt ==
    // startedAt` (the store seeds activity to `startedAt`). Use a
    // small slack window (1 second) to absorb timestamp jitter.
    entry.lastActivityAt.timeIntervalSince(entry.startedAt) > 1
  }

  private var displayTitle: String {
    if let title = entry.title, !title.isEmpty {
      return title
    }
    return hasActivity ? "Untitled" : "New Conversation"
  }

  private var relativeTime: String {
    Self.relativeFormatter.localizedString(
      for: entry.lastActivityAt,
      relativeTo: .now,
    )
  }

  private var avatarColor: Color {
    let hash = entry.id.utf8.reduce(into: 0) { $0 = ($0 &+ Int($1)) &* 31 }
    let index = ((hash % Self.avatarPalette.count) + Self.avatarPalette.count)
      % Self.avatarPalette.count
    return Self.avatarPalette[index]
  }

  /// Initial letter for the avatar — first non-space character of the
  /// display title, uppercased. Falls back to a sparkle for an empty
  /// conversation so even unstarted rows have a hint of personality.
  private var avatarInitial: String {
    let trimmed = displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if let first = trimmed.first {
      return String(first).uppercased()
    }
    return "✦"
  }

  /// Coloured circle with a white initial. Mirrors the Apple Mail /
  /// Reminders "avatar disc" idiom — recognisable at a glance, gives
  /// each conversation its own visual identity.
  private var avatar: some View {
    ZStack {
      Circle()
        .fill(
          LinearGradient(
            colors: [avatarColor, avatarColor.opacity(0.7)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing,
          )
        )
      Text(avatarInitial)
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
    }
    .frame(width: 28, height: 28)
    .shadow(color: avatarColor.opacity(0.35), radius: 2, y: 1)
  }

  /// Row background: selected ⇒ accent-tinted pill; hovering ⇒ very
  /// faint primary fill; otherwise ⇒ clear. Selected wins over hover.
  private var rowBackground: some View {
    let fill: Color =
      if isSelected {
        .accentColor.opacity(0.22)
      } else if isHovering {
        .primary.opacity(0.06)
      } else {
        .clear
      }
    return RoundedRectangle(cornerRadius: 8, style: .continuous)
      .fill(fill)
  }
}
