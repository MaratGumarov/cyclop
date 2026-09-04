import AppKit
import QuickLookUI

/// Space on a shelf card, doing what Space does in Finder.
///
/// The preview panel is one per app and asks the key window's responder chain
/// who is driving it — `NotchPanel` answers, and hands over this object. It is
/// asked for the files, so nothing here has to know what a shelf is.
final class QuickLook: NSObject {
    static let shared = QuickLook()

    private var urls: [URL] = []
    /// Told which file is on screen — once at the start, and again on every
    /// arrow key. The shelf uses it to mark the same card.
    private var onItem: ((URL) -> Void)?
    private var indexObserver: NSKeyValueObservation?

    private var isOpen: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// Shows the files, opened on `index`, or closes the panel if it is
    /// already up: Space toggles in Finder, and a preview the opening key
    /// cannot dismiss is a trap.
    func show(_ urls: [URL], startingAt index: Int = 0, onItem: ((URL) -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        if isOpen {
            QLPreviewPanel.shared().orderOut(nil)
            return
        }
        self.urls = urls
        self.onItem = onItem
        // Quick Look answers Space, Esc and the arrow keys, and none of those
        // reach a window of an app the system does not consider active — the
        // notch panel is non-activating precisely so it never has to be. So
        // this is the one moment Cyclop asks to be the front app; it stays out
        // of the Dock and the ⌘-Tab list regardless, being `.accessory`.
        NSApp.activate(ignoringOtherApps: true)
        let panel = QLPreviewPanel.shared()!
        // Set here as well as in `beginPreviewPanelControl`: the chain walk
        // starts at `NSApp.keyWindow`, which an app that has only just been
        // asked to activate may still report as nil.
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        // After `reloadData`, which resets it to the first item.
        let start = min(max(index, 0), urls.count - 1)
        panel.currentPreviewItemIndex = start
        // The panel announces the arrow keys nowhere else: there is no
        // delegate call for "the preview moved", only this property. It is
        // observed after the starting index is set, so opening does not read
        // as a move — and the file is looked up in our own list, because
        // `currentPreviewItem` is still the previous one while this fires.
        indexObserver = panel.observe(\.currentPreviewItemIndex, options: [.new]) { [weak self] _, change in
            guard let self, let index = change.newValue, self.urls.indices.contains(index) else { return }
            self.onItem?(self.urls[index])
        }
        onItem?(urls[start])
        panel.makeKeyAndOrderFront(nil)
    }
}

extension QuickLook: QLPreviewPanelDelegate {
    /// Hands the front back where it was found. Cyclop has no window to be
    /// active in and no menu bar to show while it is, so staying in front
    /// after the preview closes would leave the person looking at a desktop
    /// whose keyboard belongs to nothing.
    /// The rectangle the preview grows out of and shrinks back into — the
    /// card itself, so the animation is Finder's.
    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let url = item.previewItemURL else { return .zero }
        return ShelfCardFrames.screenFrame(for: url)
    }

    func windowWillClose(_ notification: Notification) {
        indexObserver = nil
        onItem = nil
        urls = []
        NSApp.deactivate()
    }
}

extension QuickLook: QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}
