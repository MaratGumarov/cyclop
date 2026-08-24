import SwiftUI

/// The pill both the peek and the calendar tab show while something is being
/// recorded, so that opening the panel moves it rather than swapping it.
struct StopRecordingPill: View {
    @ObservedObject var recorder: MeetingRecorder
    var compact = false

    var body: some View {
        if let session = recorder.session {
            MeetingPill(
                symbol: "stop.fill",
                // Counts itself. A published number ticking once a second
                // would have re-rendered the whole panel to move it.
                title: Text(timerInterval: session.started...Date.distantFuture, countsDown: false),
                style: .danger,
                compact: compact
            ) {
                recorder.stop()
            }
            .help(localized("Stop recording · %@", session.title))
        }
    }
}

/// The capsule every meeting button is made of — the two in the peek and the
/// three in the calendar tab.
///
/// One definition, because the ends of every `matchedGeometryEffect` pair are
/// meant to be one view that moves: built by separate code they drift apart in
/// font and padding, and a move between two shapes that no longer match reads
/// as a swap.
struct MeetingPill: View {
    /// Prominence, not colour: which of the buttons in a row is the one it is
    /// there for.
    enum Style {
        /// The press the row exists for.
        case prominent
        case neutral
        /// Deliberately the dimmer of two. A mistaken press on "Record" is a
        /// file of a conversation nobody agreed to record, so it is the one
        /// that has to be aimed at.
        case quiet
        /// Recording, and stopping it.
        case danger
    }

    let symbol: String
    let title: Text
    var style: Style = .neutral
    /// Set where the icon carries the meaning and the lettering stays quiet.
    var symbolTint: Color?
    /// The peek's row is 36 pt tall; the tab below has room to breathe.
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: compact ? 5 : 6) {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 9 : 10))
                    .foregroundStyle(symbolTint ?? foreground)
                title
                    .font(.system(size: compact ? 10.5 : 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(foreground)
            }
            .padding(.horizontal, compact ? 9 : 12)
            .padding(.vertical, compact ? 5 : 7)
            .background(background)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private var foreground: Color { style == .prominent ? .black : .white }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .prominent:
            Capsule().fill(Color.white.opacity(0.92))
        case .neutral:
            Capsule().fill(Theme.surfaceHover)
        case .quiet:
            Capsule().fill(Theme.surface)
        case .danger:
            Capsule()
                .fill(Color.red.opacity(0.22))
                .overlay(Capsule().stroke(Color.red.opacity(0.45), lineWidth: 1))
        }
    }
}
