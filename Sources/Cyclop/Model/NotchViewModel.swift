import AppKit
import Combine

@MainActor
final class NotchViewModel: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case media, shelf, clipboard, snippets, calendar, translate, notes, teleprompter, settings
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .media: return "music.note"
            case .shelf: return "tray.full.fill"
            case .clipboard: return "list.clipboard.fill"
            case .snippets: return "pin.fill"
            case .calendar: return "calendar"
            case .translate: return "translate"
            case .notes: return "note.text"
            case .teleprompter: return "text.viewfinder"
            case .settings: return "gearshape.fill"
            }
        }

        var title: String {
            switch self {
            case .media: return localized("Music")
            case .shelf: return localized("Shelf")
            case .clipboard: return localized("Clipboard")
            case .snippets: return localized("Snippets")
            case .calendar: return localized("Calendar")
            case .translate: return localized("Translate")
            case .notes: return localized("Notes")
            case .teleprompter: return localized("Teleprompter")
            case .settings: return localized("Settings")
            }
        }

        /// Tabs with a field in them. Landing on one hands it the keyboard, so
        /// that arriving and typing is a single move.
        var needsKeyboard: Bool { self == .translate || self == .snippets || self == .notes }

        /// Which rail the icon sits on. The left one carries the original six
        /// and is full — icon height is a ceiling now, not a constant (#26,
        /// #27), so a seventh icon would not overflow the panel, but it would
        /// shrink every icon on the rail to make room, which is the same
        /// objection in a quieter voice. Growth continues in a second column
        /// on the right, which the scratch notes open. Settings joins that
        /// column rather than the content rail: it is not something to hover
        /// past on the way to a track or a calendar, so it sits last,
        /// furthest from the tabs people actually rest on.
        static let leftRail: [Tab] = [.media, .shelf, .clipboard, .snippets, .calendar, .translate]
        static let rightRail: [Tab] = [.notes, .teleprompter, .settings]
    }

    /// What the notch is showing while nobody is hovering it.
    ///
    /// Not a panel and not a notification: the notch itself, grown by one row.
    /// It hangs there — that is the whole point — so it is only ever raised by
    /// something that is true for a bounded stretch of time and stops being
    /// true on its own.
    enum Peek: Equatable {
        /// A meeting that starts within the minute. Ends when it starts.
        case meeting(CalendarStore.Meeting)
        /// A recording still running past the end of the meeting it was
        /// started for. Ends when the recording does.
        case recording

        /// Whether it is the kind that shows a countdown, and therefore the
        /// kind that needs the calendar's clock running behind it.
        var countsDown: Bool {
            if case .meeting = self { return true }
            return false
        }
    }

    @Published private(set) var peek: Peek?
    private var peekTimer: Timer?

    @Published var isOpen = false
    @Published var isDropTargeted = false
    @Published var tab: Tab = .media {
        didSet {
            // Opening the tab only re-checks the status. The permission prompt
            // is the user's own press on the button inside the pane: this is
            // the one permission Cyclop asks for at all, and it deserves an
            // explanation before the system dialog, not after.
            if tab == .calendar { calendar.refreshAccess() }
            // The snippets file is edited from outside the app, so it is read
            // on the way in rather than held from launch.
            if tab == .snippets { snippets.reload() }
            // Same reason, sharper stakes: the shelf can hold files inside the
            // folders macOS guards, and looking at one raises a permission
            // prompt. It is asked here, with the shelf on screen, rather than
            // at launch with nothing to explain it.
            if tab == .shelf { shelf.refreshFromDisk() }
            // Leaving the notes sweeps out the blank ones — they cost one
            // hover to recreate, and a trail of empty cards is the clutter a
            // scratchpad exists to avoid.
            if oldValue == .notes, tab != .notes { notes.leave() }
            // Leaving the tab that types gives the keyboard straight back.
            if !tab.needsKeyboard { wantsKeyboard = false }
            // Leaving the teleprompter stops the scroll and drops the pin, so
            // the panel goes back to obeying the pointer like everything else.
            if oldValue == .teleprompter, tab != .teleprompter { teleprompter.suspend() }
        }
    }

    /// Whether the panel must stay open with no pointer on it.
    ///
    /// This is the one exception to the rule stated at `NotchController.setOpen`
    /// — the pointer decides, always — and it exists because the teleprompter
    /// cannot work under that rule: the whole point is reading while looking at
    /// the camera, hands nowhere near the trackpad. The exception is kept as
    /// narrow as it can be. It applies to one tab, only while the script is
    /// actually moving, and it ends three ways that need no explaining: the
    /// script runs out, Escape, or a click anywhere outside the panel.
    var holdsOpen: Bool { tab == .teleprompter && teleprompter.isRunning }

    /// Whether the panel currently holds the keyboard.
    ///
    /// Tracked apart from `tab` because the two come apart in one direction:
    /// clicking into another app drops the claim without changing which tab is
    /// showing, so the text one was typing survives and the panel is free to
    /// collapse. Landing on a tab that types always raises it again — there is
    /// no such thing as a panel that shows a field but cannot receive a key.
    @Published var wantsKeyboard = false

    let geometry: NotchGeometry
    let media: MediaController
    let shelf: ShelfStore
    let clipboard: ClipboardStore
    let calendar: CalendarStore
    let translator: Translator
    let snippets: SnippetStore
    let notes: NoteStore
    let teleprompter: TeleprompterStore
    /// Handed in rather than made here, and it is the only store that is: a
    /// recording outlives this object. Plugging in a display rebuilds the whole
    /// panel, and a recording that ended because a monitor was connected
    /// mid-call is a lost file, not a redraw.
    let recorder: MeetingRecorder
    /// Shared by every pane that shows something worth not showing.
    let privacy = PrivacyMode()

    private var cancellables = Set<AnyCancellable>()

    init(geometry: NotchGeometry, recorder: MeetingRecorder) {
        self.geometry = geometry
        self.recorder = recorder
        self.media = MediaController()
        self.shelf = ShelfStore()
        self.clipboard = ClipboardStore()
        self.calendar = CalendarStore()
        self.translator = Translator()
        self.snippets = SnippetStore()
        self.notes = NoteStore()
        self.teleprompter = TeleprompterStore()

        // The panel header reads through to the stores — counters, the source
        // name, the equalizer. Nested ObservableObjects do not propagate on
        // their own, so those would only refresh when something else happened
        // to redraw the view.
        //
        // Forwarded only while the panel is open. Collapsed, there is nothing
        // these redraws could change — the panel is a black shape — yet the
        // stores keep their own schedule: a track change every few minutes, a
        // copy whenever one happens, and each send re-evaluated the whole
        // view for nobody. Opening repaints from the stores directly, because
        // `isOpen` is itself @Published and its own send does that.
        //
        // The stores with a text field in their pane — the translator, the
        // snippets and the notes — are deliberately absent. They change on every
        // keystroke, and redrawing the whole panel per letter costs more than a
        // stale counter: it rebuilds the field, which drops the focus, so the
        // first letter typed is also the last one that lands. Their panes
        // observe them directly, and the header counter refreshes anyway,
        // because the list is only ever re-read on the way into the tab.
        for child in [
            media.objectWillChange,
            shelf.objectWillChange,
            clipboard.objectWillChange,
            calendar.objectWillChange,
            recorder.objectWillChange,
        ] {
            child
                .sink { [weak self] _ in
                    guard let self, self.isOpen || self.isDropTargeted || self.peek != nil else { return }
                    self.objectWillChange.send()
                }
                .store(in: &cancellables)
        }
    }

    // MARK: - Peek

    /// Raises the peek, optionally with the moment it stops being true.
    func showPeek(_ peek: Peek, until: Date? = nil) {
        peekTimer?.invalidate()
        peekTimer = nil
        self.peek = peek

        guard let until else { return }
        guard until > Date() else { return dismissPeek(peek) }
        let timer = Timer(fire: until, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissPeek(peek) }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        peekTimer = timer
    }

    /// Takes it down. A peek can be named, so that one raised in the meantime
    /// survives the timer of the one it replaced.
    func dismissPeek(_ which: Peek? = nil) {
        if let which, peek != which { return }
        peekTimer?.invalidate()
        peekTimer = nil
        peek = nil
    }

    /// Body this tab takes when open — asked whether it is open yet or not.
    ///
    /// Separate from `bodySize` because the rects are cut one step before the
    /// panel is marked open: `setOpen` grows the interactive area first, so
    /// the pointer never falls through a region the animation has not covered.
    /// Reading a size that returns the notch until `isOpen` flips would hand
    /// that step the collapsed size and leave the whole body drawn but deaf to
    /// the pointer.
    ///
    /// One tab is taller than the rest. Type large enough to read at a glance
    /// leaves room for two lines in the standard body, and two lines is not a
    /// teleprompter — it is a countdown. The extra height buys the paragraph
    /// the reader needs to see coming.
    var openBodySize: CGSize {
        tab == .teleprompter ? geometry.tallExpandedSize : geometry.expandedSize
    }

    /// Size of the visible body for the current state.
    var bodySize: CGSize {
        if isOpen || isDropTargeted { return openBodySize }
        return peek != nil ? geometry.peekSize : geometry.notchSize
    }

    /// Off switch for people who copy images all day and do not want them kept.
    static let saveClipboardImagesKey = "saveClipboardImages"

    /// Defaults to on: the feature is the reason the folder exists.
    static var saveClipboardImagesEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: saveClipboardImagesKey) != nil else { return true }
        return defaults.bool(forKey: saveClipboardImagesKey)
    }

    /// Hover and click both land here. A tab that types takes the keyboard
    /// either way: showing a field one cannot type into is worse than briefly
    /// dimming the caret of the window underneath, and the dwell threshold on
    /// the rail already keeps a passing pointer from arriving here at all.
    func select(_ tab: Tab) {
        self.tab = tab
        if tab.needsKeyboard { wantsKeyboard = true }
    }

    func start() {
        media.start()
        shelf.load()
        snippets.reload()
        // Only picks up where it left off if access was granted earlier; it
        // never prompts on its own.
        calendar.start()

        // Screenshots reach the shelf through here whether they were taken on
        // this Mac or on a phone: a copy made on the phone arrives in the same
        // pasteboard, carried over by Continuity.
        //
        // The switch is asked by the store before it touches image data, not
        // here after the fact: turned off, a copied picture used to be encoded
        // to PNG in full just to be dropped on this doorstep — pure heat on
        // exactly the machines whose owners turned the feature off.
        clipboard.wantsImages = { Self.saveClipboardImagesEnabled }
        clipboard.onImage = { [weak self] png in
            guard let self, let url = ScreenshotVault.save(png) else { return }
            self.received(url)
        }
        clipboard.start()

        // The recording says where it went the moment it is written.
        recorder.onFinished = { [weak self] url in self?.received(url) }
    }

    func stop() {
        media.stop()
        clipboard.stop()
        calendar.stop()
        // Whatever was typed makes it to disk even when quitting mid-thought.
        notes.flush()
    }

    /// A file that arrived on its own — a screenshot copied elsewhere or synced
    /// from a phone by Continuity, a recording that has just finished writing —
    /// rather than one the user handed to the panel directly.
    ///
    /// It goes on the shelf either way, which is the answer to "where did it
    /// go": a card that can be dragged straight into a chat, opened, or shown
    /// in Finder, instead of a path in a folder nobody opens. It only switches
    /// to showing it when nobody is mid-sentence: the tab's own field would
    /// slide out from under the caret, and losing the keyboard mid-word sends
    /// the rest of the sentence to whatever is underneath. The shelf's counter
    /// shows the new card regardless, so nothing is lost by waiting.
    func received(_ url: URL) {
        shelf.add([url])
        guard !wantsKeyboard else { return }
        tab = .shelf
    }

    /// A file the user dropped on the panel by hand — switching to the shelf
    /// is the point, not a side effect to guard against.
    func accept(urls: [URL]) -> Bool {
        shelf.add(urls)
        tab = .shelf
        return true
    }
}
