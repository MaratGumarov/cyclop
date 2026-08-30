import SwiftUI

struct NotchContentView: View {
    @ObservedObject var vm: NotchViewModel

    /// One namespace for the whole notch, because the two states it moves
    /// between — the peek and the open calendar tab — live in different
    /// branches of the same view.
    @Namespace private var hero

    private var isOpen: Bool { vm.isOpen || vm.isDropTargeted }
    /// The notch grown by one row, with nobody hovering it.
    private var peek: NotchViewModel.Peek? { isOpen ? nil : vm.peek }
    private var size: CGSize { vm.bodySize }
    private var topRadius: CGFloat { isOpen ? Theme.openTopRadius : Theme.collapsedTopRadius }

    var body: some View {
        // The shape is wider than the body by `topRadius` on each side: that
        // slack is where the concave shoulders live, so it must not be clipped.
        ZStack(alignment: .top) {
            NotchShape(
                topRadius: topRadius,
                bottomRadius: isOpen
                    ? Theme.openBottomRadius
                    : (peek != nil ? Theme.peekBottomRadius : Theme.collapsedBottomRadius)
            )
            .fill(Color.black)
            .frame(width: size.width + 2 * topRadius, height: size.height)
            .shadow(color: .black.opacity(isOpen ? 0.5 : 0), radius: 18, y: 8)

            VStack(spacing: 0) {
                header
                if isOpen {
                    content
                        .transition(.opacity)
                } else if let peek {
                    MeetingPeek(vm: vm, peek: peek, hero: hero)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipped()
        }
        .overlay(alignment: .top) {
            // Placed off the notch's own width rather than the body's: the
            // panel is 620 pt wide once it opens, and a mark that followed
            // that would fly off to the far end of the menu bar on the way.
            RecordingMark(recorder: vm.recorder, visible: !isOpen)
                .offset(
                    x: vm.geometry.notchSize.width / 2 + Theme.collapsedTopRadius + 6,
                    y: (vm.geometry.notchSize.height - RecordingMark.dot) / 2
                )
        }
        .frame(width: size.width + 2 * topRadius, height: size.height, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(Theme.openAnimation, value: isOpen)
        .animation(Theme.openAnimation, value: vm.peek)
        .animation(Theme.paneAnimation, value: vm.tab)
    }

    // MARK: - Header
    //
    // This strip sits directly on top of the menu bar. Menu bar utilities such
    // as Ice watch for clicks there with a global event monitor — a passive
    // observer that sees the click no matter which window consumes it — so
    // clicking here toggles them as a side effect. Nothing interactive goes in
    // this row; the tab switcher lives in the rail below.

    private var header: some View {
        HStack(spacing: 0) {
            if isOpen {
                Text(vm.tab.title.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.tertiary)
                    .padding(.leading, 16)
                    .id(vm.tab)
                    .transition(.opacity)
            }
            Spacer(minLength: 0)
            Color.clear.frame(width: vm.geometry.notchSize.width, height: 1)
            Spacer(minLength: 0)
            if isOpen {
                trailing
                    .padding(.trailing, 16)
                    .transition(.opacity)
            }
        }
        .frame(height: vm.geometry.notchSize.height)
    }

    private var trailing: some View {
        HStack(spacing: 8) {
            // Ahead of whatever the tab has to say, and on every tab: which tab
            // one happens to be looking at is no reason to not know that a
            // microphone is open.
            RecordingButton(recorder: vm.recorder) { vm.toggleRecording() }
            tabTrailing
        }
    }

    @ViewBuilder
    private var tabTrailing: some View {
        switch vm.tab {
        case .media:
            HStack(spacing: 6) {
                if vm.media.track != nil {
                    EqualizerBars(isAnimating: vm.media.isPlaying)
                }
                Text(vm.media.sourceName ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.tertiary)
            }
        case .shelf:
            counter(vm.shelf.items.count)
        case .clipboard:
            counter(vm.clipboard.items.count)
        case .snippets:
            counter(vm.snippets.items.count)
        case .calendar:
            if let next = vm.calendar.next {
                Text(CalendarPane.countdown(to: next, from: vm.calendar.now))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(next.isRunning ? Color.white.opacity(0.8) : Theme.tertiary)
                    .hero(.countdown, in: hero)
            }
        case .translate:
            // Nothing: the columns name both languages already, and the strip
            // is the one part of the panel worth not spending on a repeat.
            EmptyView()
        case .notes:
            NotesCounter(notes: vm.notes)
        case .teleprompter:
            EmptyView()
        case .settings:
            EmptyView()
        }
    }

    @ViewBuilder
    private func counter(_ value: Int) -> some View {
        if value > 0 {
            Text("\(value)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }

    // MARK: - Body

    private var content: some View {
        HStack(spacing: 14) {
            Rail(vm: vm, tabs: NotchViewModel.Tab.leftRail)
            panes
            Rail(vm: vm, tabs: NotchViewModel.Tab.rightRail)
        }
        .padding(.horizontal, 14)
        // The body's height is measured from this same number, so the two
        // cannot drift apart into a rail that does not fit.
        .padding(.bottom, NotchGeometry.bodyBottomPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var panes: some View {
        // Content is replaced in place — no travel. The rail is vertical and
        // the panes are unrelated, so a direction would only be decoration.
        ZStack {
            pane
                .id(vm.tab)
                .transition(.asymmetric(
                    insertion: .opacity
                        .combined(with: .scale(scale: 0.97))
                        .animation(Theme.paneIn),
                    removal: .opacity
                        .combined(with: .scale(scale: 1.02))
                        .animation(Theme.paneOut)
                ))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private var pane: some View {
        switch vm.tab {
        case .media:
            MediaPane(media: vm.media)
        case .shelf:
            ShelfPane(shelf: vm.shelf, isTargeted: vm.isDropTargeted)
        case .clipboard:
            ClipboardPane(clipboard: vm.clipboard, privacy: vm.privacy)
        case .calendar:
            CalendarPane(calendar: vm.calendar, privacy: vm.privacy, recorder: vm.recorder, hero: hero)
        case .snippets:
            SnippetsPane(snippets: vm.snippets, privacy: vm.privacy, wantsKeyboard: $vm.wantsKeyboard)
        case .translate:
            TranslatePane(translator: vm.translator, wantsKeyboard: $vm.wantsKeyboard)
        case .notes:
            NotesPane(notes: vm.notes, privacy: vm.privacy, wantsKeyboard: $vm.wantsKeyboard)
        case .teleprompter:
            TeleprompterPane(prompter: vm.teleprompter, wantsKeyboard: $vm.wantsKeyboard)
        case .settings:
            SettingsPane(shelf: vm.shelf)
        }
    }
}

/// The red dot beside the collapsed notch, and the only thing on screen while
/// the panel is folded away that says a recording is running.
///
/// It watches the recorder itself rather than reading through the view model,
/// which forwards its children only while somebody is looking at the panel —
/// and the whole point of this mark is the hour when nobody is.
///
/// Beside the notch rather than under it or inside it. Under it, the mark was
/// gone the moment a peek dropped down and took that edge; inside it, a red
/// dot sits next to the camera and says the camera is on — which is the one
/// thing this recording is not. To the right it keeps the company it belongs
/// in: the menu bar, where every other "this is running" lives.
private struct RecordingMark: View {
    /// Its own diameter, since the offset that places it has to centre it
    /// against the height of the notch.
    static let dot: CGFloat = 6

    @ObservedObject var recorder: MeetingRecorder
    /// The open panel says it louder, with a counter in the header.
    let visible: Bool

    @State private var dim = false

    var body: some View {
        if visible, recorder.isRecording {
            Circle()
                .fill(Color.red)
                .frame(width: Self.dot, height: Self.dot)
                .opacity(dim ? 0.35 : 1)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: dim)
                .onAppear { dim = true }
                .onDisappear { dim = false }
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }
}

/// The recorder's place in the panel's header, on whichever tab is open: the
/// counter while a recording runs, and the way to start one while none does.
///
/// Recording lives here rather than only under the agenda because the calls
/// worth keeping are not only the ones somebody sent an invitation for. The
/// header is the one strip that every tab has, so it is the one place where
/// "record this" costs no navigation.
///
/// Small, grey and off to the side on purpose: a mistaken press is a file of a
/// conversation nobody agreed to record, so this is a mark to be aimed at, not
/// one to be landed on while reaching for a tab.
private struct RecordingButton: View {
    @ObservedObject var recorder: MeetingRecorder
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            if let session = recorder.session {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 5, height: 5)
                    Text(timerInterval: session.started...Date.distantFuture, countsDown: false)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.white.opacity(0.8))
                }
            } else {
                // Red only when there is something to say: a refused
                // permission otherwise shows its words on the Calendar tab
                // alone, and pressing here from the Shelf would look like
                // nothing happened at all.
                Image(systemName: "record.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(recorder.failure == nil ? Theme.tertiary : Color.red.opacity(0.85))
            }
        }
        .buttonStyle(.plain)
        .help(recorder.failure ?? localized(recorder.isRecording ? "Stop recording" : "Start recording"))
    }
}

/// Watches the note store itself rather than reading through the view model:
/// notes are born and deleted inside the pane while this counter is on
/// screen, and the view model deliberately does not forward keystroke-driven
/// stores.
private struct NotesCounter: View {
    @ObservedObject var notes: NoteStore

    var body: some View {
        if !notes.notes.isEmpty {
            Text("\(notes.notes.count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.tertiary)
        }
    }
}

/// Tab switcher.
///
/// Hovering switches tabs, but only after the pointer has stopped: a pointer
/// crossing the rail on its way somewhere else is gone in a few dozen
/// milliseconds, while one that came to choose stays put. The same dwell
/// threshold is what separates "the mouse was flung across the top of the
/// screen" from "the mouse came to the notch" in `PointerWatcher`.
private struct Rail: View {
    @ObservedObject var vm: NotchViewModel
    /// Which icons this rail carries — there are two rails now, one per side.
    let tabs: [NotchViewModel.Tab]

    @State private var hovered: NotchViewModel.Tab?

    /// Long enough to swallow a pass-through, short enough that a deliberate
    /// hover still feels like it answered instantly.
    private let dwell = Duration.milliseconds(150)

    var body: some View {
        VStack(spacing: NotchGeometry.railSpacing) {
            ForEach(tabs) { tab in
                Button {
                    vm.select(tab)
                } label: {
                    Image(systemName: tab.symbol)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 30, height: vm.geometry.railIconHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(fill(for: tab))
                        )
                        .foregroundStyle(vm.tab == tab ? Color.white : Theme.tertiary)
                        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        // A render-time transform. Growing the frame instead
                        // would re-lay out the rail on every hover, and layout
                        // that runs on pointer movement is exactly the kind
                        // that shows up as a stutter.
                        .scaleEffect(hovered == tab ? 1.15 : 1)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside {
                        hovered = tab
                    } else if hovered == tab {
                        hovered = nil
                    }
                }
            }
        }
        .frame(width: 30)
        // Centred in the height an ordinary tab has, then that block pinned to
        // the top of whatever height this tab actually got. On the eight normal
        // tabs the two are the same and nothing moves; on the teleprompter the
        // extra 192 pt goes to the script below, and the icons stay put.
        .frame(height: vm.geometry.standardContentHeight, alignment: .center)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(Theme.contentAnimation, value: hovered)
        // Moving to another icon cancels the pending switch along with the
        // task, so only the icon actually rested on ever wins.
        .task(id: hovered) {
            guard let hovered, hovered != vm.tab else { return }
            try? await Task.sleep(for: dwell)
            guard !Task.isCancelled else { return }
            vm.select(hovered)
        }
    }

    private func fill(for tab: NotchViewModel.Tab) -> Color {
        if vm.tab == tab { return Theme.surfaceHover }
        return hovered == tab ? Theme.surface : .clear
    }
}
