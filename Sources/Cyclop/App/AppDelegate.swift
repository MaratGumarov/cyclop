import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var controller: NotchController?
    private var statusItem: NSStatusItem?
    private var privacyItem: NSMenuItem?
    private var privacyAllItem: NSMenuItem?
    private var privacySectionItems: [PrivacyMode.Section: NSMenuItem] = [:]
    private var recordItem: NSMenuItem?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = NotchController()
        controller?.install()
        installStatusItem()

        // The icon is the one part of the app that is on screen at all times,
        // which makes it the only honest place to say that a microphone and the
        // system's audio are being written to a file. macOS shows indicators of
        // its own; this app owes its own switch its own light.
        controller?.recorder.$session
            .sink { [weak self] session in
                MainActor.assumeIsolated { self?.refreshStatusIcon(recording: session != nil) }
            }
            .store(in: &cancellables)
    }

    /// A recording in flight is finished before the process goes away. The
    /// file is a container that has to be closed properly, and one that is not
    /// is not a shorter recording — it is no recording at all.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder = controller?.recorder, recorder.isRecording else { return .terminateNow }
        // No mixdown on the way out: closing the file is what saves it, and
        // flattening it is what would keep the user waiting.
        recorder.stop(mix: false) {
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.teardown()
    }

    // MARK: - Menu bar item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Cyclop \(Bundle.main.shortVersion)", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: localized("Open Panel"),
            action: #selector(togglePanel),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        // Above the panel switch, because both halves of it are things people
        // reach for in a hurry: a call that started in a chat and is worth
        // keeping, and a recording that has to stop now. Neither should need
        // the panel opened first, and the second must never be hunted for.
        let record = NSMenuItem(
            title: localized("Start recording"),
            action: #selector(toggleRecording),
            keyEquivalent: ""
        )
        record.target = self
        menu.insertItem(record, at: 2)
        recordItem = record

        // Sits next to the panel switch rather than in the Settings tab: it
        // changes what the panel shows, and it is the one people look for in a
        // hurry, with the camera already running.
        //
        // A submenu rather than a plain switch, because the tabs hold different
        // things and not everyone wants all of them covered. "All" comes first
        // and is what most people will ever touch; the sections below it are
        // for the case where that is too much.
        let privacy = NSMenuItem(title: localized("Hide Contents"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let all = NSMenuItem(title: localized("All"), action: #selector(togglePrivacyAll), keyEquivalent: "")
        all.target = self
        submenu.addItem(all)
        privacyAllItem = all
        submenu.addItem(.separator())

        for section in PrivacyMode.Section.allCases {
            let item = NSMenuItem(
                title: section.title,
                action: #selector(togglePrivacySection(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = section.rawValue
            submenu.addItem(item)
            privacySectionItems[section] = item
        }

        privacy.submenu = submenu
        menu.addItem(privacy)
        privacyItem = privacy

        menu.addItem(.separator())
        let quit = NSMenuItem(title: localized("Quit"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        // The idle look is described once, by the same function that describes
        // the recording one.
        refreshStatusIcon(recording: false)
    }

    @objc private func togglePanel() {
        controller?.toggle()
    }

    @objc private func toggleRecording() {
        guard let recorder = controller?.recorder else { return }
        if recorder.isRecording {
            recorder.stop()
        } else {
            recorder.start(title: localized("Recording"))
        }
    }

    private func refreshStatusIcon(recording: Bool) {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: recording ? "record.circle" : "eye.fill",
            accessibilityDescription: recording ? localized("Stop recording") : "Cyclop"
        )
        button.image?.isTemplate = !recording
        button.contentTintColor = recording ? .systemRed : nil
    }

    /// Everything shown is re-read when the menu opens, not kept fresh in
    /// between: a menu nobody is looking at deserves no bookkeeping.
    func menuWillOpen(_ menu: NSMenu) {
        refreshPrivacyItems()
        if let recorder = controller?.recorder {
            recordItem?.title = recorder.isRecording
                ? localized("Stop recording (%@)", formatTime(recorder.elapsed))
                : localized("Start recording")
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func togglePrivacyAll(_ sender: NSMenuItem) {
        guard let privacy = controller?.privacy else { return }
        // Anything short of everything means "turn the rest on too"; only a
        // full house turns them all off. One press, and no state where the
        // item says All while half the sections are open.
        privacy.setCoveringAll(!privacy.coversAll)
        refreshPrivacyItems()
    }

    @objc private func togglePrivacySection(_ sender: NSMenuItem) {
        guard let privacy = controller?.privacy,
              let raw = sender.representedObject as? String,
              let section = PrivacyMode.Section(rawValue: raw) else { return }
        privacy.setCovering(section, !privacy.covers(section))
        refreshPrivacyItems()
    }

    /// The parent item carries the summary: a tick when every section is
    /// covered, a dash when some are. Without it the state is a submenu away,
    /// and this is the one switch worth reading at a glance.
    private func refreshPrivacyItems() {
        guard let privacy = controller?.privacy else { return }
        privacyItem?.state = privacy.coversAll ? .on : (privacy.coversAny ? .mixed : .off)
        privacyAllItem?.state = privacy.coversAll ? .on : .off
        for (section, item) in privacySectionItems {
            item.state = privacy.covers(section) ? .on : .off
        }
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}

