import SwiftUI

/// The row the notch grows when a meeting is a minute away, and again when a
/// recording has outlived the meeting it was started for.
///
/// It hangs there rather than flashing past, because what it says stays true
/// for as long as it is up: the meeting has not started yet, the recording is
/// still running. Nothing here is a notification — there is no history and no
/// second chance to catch it. It goes when the thing it is about is over, or
/// when the cross says it has been read.
///
/// One row, two buttons, and the panel itself is still one hover away with the
/// whole agenda in it.
struct MeetingPeek: View {
    @ObservedObject var vm: NotchViewModel
    let peek: NotchViewModel.Peek
    let hero: Namespace.ID

    /// The same cover the calendar tab uses, down to the dust field: a title
    /// that hangs over the menu bar for a minute is the most public thing this
    /// app puts on screen, and covering the tab but not this would be covering
    /// nothing.
    private var hidden: Bool { vm.privacy.hides(.calendar, "calendar") }

    var body: some View {
        Group {
            switch peek {
            case .meeting(let meeting): row(for: meeting)
            case .recording: recordingRow
            }
        }
        .padding(.horizontal, 14)
        .frame(height: NotchGeometry.peekRowHeight)
    }

    private func row(for meeting: CalendarStore.Meeting) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color(meeting.calendarColor))
                .frame(width: 6, height: 6)
            SpoilerText(
                text: meeting.title,
                hidden: hidden,
                font: .system(size: 11.5, weight: .medium),
                height: 13,
                seed: UInt64(bitPattern: Int64(meeting.id.hashValue))
            )
            Text(CalendarPane.countdown(to: meeting, from: vm.calendar.now))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .layoutPriority(1)
                .hero(.countdown, in: hero)

            Spacer(minLength: 8)

            actions {
                if meeting.link != nil {
                    MeetingPill(
                        symbol: "video.fill",
                        title: Text(localized("Join")),
                        style: .prominent,
                        compact: true
                    ) {
                        vm.calendar.join(meeting)
                        vm.dismissPeek()
                    }
                    .hero(.join, in: hero)

                    MeetingPill(
                        symbol: "record.circle",
                        title: Text(localized("Record")),
                        style: .quiet,
                        symbolTint: .red,
                        compact: true
                    ) {
                        vm.calendar.join(meeting)
                        vm.recorder.start(for: meeting)
                        vm.dismissPeek()
                    }
                    .hero(.record, in: hero)
                }
                close
            }
        }
    }

    private var recordingRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
            if let session = vm.recorder.session {
                SpoilerText(
                    text: session.title,
                    hidden: hidden,
                    font: .system(size: 11.5, weight: .medium),
                    height: 13,
                    seed: UInt64(bitPattern: Int64(session.title.hashValue))
                )
            }

            Spacer(minLength: 8)

            actions {
                StopRecordingPill(recorder: vm.recorder, compact: true)
                    .hero(.stop, in: hero)
                close
            }
        }
    }

    /// Takes the row down by hand. It sits inside the buttons, in the strip
    /// hovering does not reach, for the same reason they do: a dismiss that
    /// unfolds the panel over the pointer coming to press it is not a dismiss.
    ///
    /// Nothing else changes — the meeting still starts, the recording still
    /// runs. This only says "I have read it", which the row otherwise has no
    /// way of hearing.
    private var close: some View {
        Button {
            vm.dismissPeek()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(localized("Hide"))
    }

    /// The buttons, in exactly the width the hover target leaves them. Hovering
    /// the rest of the row unfolds the panel, as hovering the notch does;
    /// hovering this does not, or a button would step aside from the pointer
    /// coming to press it. The width is `NotchGeometry.peekActionsWidth` and
    /// nothing else — the layout and the hover target read the same number.
    private func actions<Buttons: View>(@ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 8, content: buttons)
            .frame(width: NotchGeometry.peekActionsWidth, alignment: .trailing)
    }
}

/// The parts that exist both in the peek and in the calendar tab.
///
/// The peek is that tab folded into one row, so these are not two views that
/// cross-fade — they are one view that moves, and it moves whichever way the
/// panel is going. The list is kept in one place because the failure mode is
/// silent and one-sided: a pair added here and forgotten there is a button
/// that teleports.
enum MeetingHero: String {
    case join, record, stop, countdown
}

extension View {
    /// Matched by position only, never by size. Matching the frame would press
    /// the arriving view into the leaving one's rectangle for the length of the
    /// animation — long enough for a button's label to truncate and snap back,
    /// which is the one artefact this whole exercise is against. Position alone
    /// gives the travel and leaves both ends the size they were designed at.
    func hero(_ id: MeetingHero, in namespace: Namespace.ID) -> some View {
        matchedGeometryEffect(id: id.rawValue, in: namespace, properties: .position)
    }
}
