import SwiftUI

/// Click-drag scrubber for the now-playing bar. `M:SS` elapsed on the left,
/// stock `Slider` in the middle, `M:SS` total on the right. Matches Music.app's
/// compact-window transport: a single horizontal strip, native control sizes,
/// the project's `.caption2 + .monospacedDigit() + .secondary` time-label
/// tokens (see `plans/typography.md`).
///
/// The dragging-vs-snapshot dance: while the user is actively dragging, the
/// 0.5 s now-playing tick must NOT yank the slider thumb out from under their
/// cursor. Local `@State` mirrors the snapshot's `elapsed` and is overwritten
/// from the snapshot **only when `isDragging == false`** (via `.onChange`).
/// During the drag the Slider mutates `displayPosition` directly via its
/// `$binding`; on drag end (Slider's `onEditingChanged: false`) we write the
/// final position to the player and let the next snapshot tick re-sync.
///
/// Edge cases:
/// - No song playing → slider disabled, both labels show `—:——`.
/// - Duration unknown / zero → slider disabled, total label shows `—:——`.
/// - Live scrub while paused → seek runs, engine state untouched, stays paused.
struct ScrubBar: View {

  // MARK: Internal

  var body: some View {
    HStack(spacing: 8) {
      Text(elapsedLabel)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 32, alignment: .trailing)

      Slider(
        value: $displayPosition,
        in: 0 ... sliderUpperBound,
        onEditingChanged: handleEditingChanged,
      )
      .controlSize(.small)
      .disabled(!isScrubbable)
      .accessibilityLabel("Playback position")
      .accessibilityValue(elapsedLabel)
      .frame(minWidth: 160, maxWidth: 320)

      Text(totalLabel)
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 32, alignment: .leading)
    }
    .onChange(of: snapshot.elapsed) { _, newElapsed in
      // Snapshot drives the display ONLY when the user isn't holding
      // the thumb. While dragging, the Slider's binding owns the value.
      guard !isDragging else { return }
      displayPosition = newElapsed
    }
    .onChange(of: snapshot.nowPlayingItemID) { _, _ in
      // Track change resets the playhead — re-sync immediately so the
      // slider doesn't briefly show the prior song's elapsed.
      guard !isDragging else { return }
      displayPosition = snapshot.elapsed
    }
  }

  // MARK: Private

  private static let placeholderTime = "—:——"

  @Environment(MusicController.self) private var controller

  /// Mirror of `snapshot.elapsed`. Owned by the Slider during a drag, by
  /// `.onChange(snapshot.elapsed)` otherwise. Per swiftui-pro: prefer
  /// `@State + onChange` over `Binding(get:set:)`.
  @State private var displayPosition: Double = 0

  /// True while the user is holding the thumb — gates the snapshot
  /// re-sync so the tick can't snap the cursor away mid-drag.
  @State private var isDragging = false

  private var snapshot: PlayerStateSnapshot {
    controller.playback.snapshot
  }

  /// Slider domain must be non-empty even when disabled — `0 ... 0` is a
  /// valid empty range; the slider just shows a fixed thumb at the start.
  /// When we have a real duration use it; otherwise a `1` placeholder
  /// keeps the visual proportions sane while disabled.
  private var sliderUpperBound: Double {
    guard let duration = snapshot.duration, duration > 0 else { return 1 }
    return duration
  }

  private var isScrubbable: Bool {
    guard snapshot.hasContent else { return false }
    guard let duration = snapshot.duration, duration > 0 else { return false }
    return true
  }

  private var elapsedLabel: String {
    guard isScrubbable else { return Self.placeholderTime }
    // While dragging, label tracks the thumb (the user wants to see the
    // *destination* time, not the still-playing source time).
    return (isDragging ? displayPosition : snapshot.elapsed).musicTimeText
  }

  private var totalLabel: String {
    guard let duration = snapshot.duration, duration > 0 else {
      return Self.placeholderTime
    }
    return duration.musicTimeText
  }

  private func handleEditingChanged(_ editing: Bool) {
    if editing {
      isDragging = true
    } else {
      // Drag end (or single click on the track): commit the position to
      // the player, then drop the drag flag so the next snapshot tick
      // re-syncs `displayPosition` to whatever the engine reports.
      controller.seek(to: displayPosition)
      isDragging = false
    }
  }

}
