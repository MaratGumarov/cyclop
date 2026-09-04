import AppKit
import SwiftUI

/// Drag handle for shelf cards.
///
/// SwiftUI's `onDrag` hands back a single `NSItemProvider`, so it can never
/// carry more than one file. Dragging a selection needs an AppKit dragging
/// session with one `NSDraggingItem` per URL, which is what this overlay
/// starts. It also owns the click handling, because selection and dragging
/// come from the same mouse-down.
struct ShelfDragSource: NSViewRepresentable {
    /// The one card this handle covers, as opposed to what a drag from it
    /// would carry. Registered so Quick Look can zoom out of the card.
    var url: URL
    /// Files to drag: the whole selection if this card is part of it, else
    /// just this card.
    var urls: () -> [URL]
    var onClick: (NSEvent.ModifierFlags) -> Void
    var onDoubleClick: () -> Void
    /// Raised while the trackpad is pressed past the click, and lowered when
    /// the finger comes off. Trackpads without pressure never raise it.
    var onDeepPress: (Bool) -> Void

    func makeNSView(context: Context) -> DragView {
        let view = DragView()
        // Asking for the deep-click behaviour is what makes the trackpad
        // report stages at all — and it brings the second haptic tick with
        // it, so the press is felt as well as seen.
        view.pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
        view.apply(urls, onClick, onDoubleClick, onDeepPress)
        ShelfCardFrames.register(view, for: url)
        return view
    }

    func updateNSView(_ view: DragView, context: Context) {
        view.apply(urls, onClick, onDoubleClick, onDeepPress)
        ShelfCardFrames.register(view, for: url)
    }

    final class DragView: NSView, NSDraggingSource {
        var urls: () -> [URL] = { [] }
        var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
        var onDoubleClick: () -> Void = {}
        var onDeepPress: (Bool) -> Void = { _ in }

        private var mouseDownPoint: NSPoint?
        private var dragging = false
        private var deep = false

        func apply(
            _ urls: @escaping () -> [URL],
            _ onClick: @escaping (NSEvent.ModifierFlags) -> Void,
            _ onDoubleClick: @escaping () -> Void,
            _ onDeepPress: @escaping (Bool) -> Void
        ) {
            self.urls = urls
            self.onClick = onClick
            self.onDoubleClick = onDoubleClick
            self.onDeepPress = onDeepPress
        }

        /// Stage 2 is the press past the click — the same one Finder opens
        /// Quick Look on.
        override func pressureChange(with event: NSEvent) {
            setDeep(event.stage >= 2)
        }

        private func setDeep(_ on: Bool) {
            guard deep != on else { return }
            deep = on
            onDeepPress(on)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            mouseDownPoint = event.locationInWindow
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragging, let start = mouseDownPoint else { return }
            let delta = hypot(
                event.locationInWindow.x - start.x,
                event.locationInWindow.y - start.y
            )
            guard delta > 3 else { return }

            let files = urls()
            guard !files.isEmpty else { return }
            dragging = true
            // A press that turns into a drag is a drag: the enlarged preview
            // must not stay up behind the file being carried away.
            setDeep(false)

            let items = files.enumerated().map { index, url -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                // Fan the icons out slightly so a group reads as a stack.
                let offset = CGFloat(index) * 9
                item.setDraggingFrame(
                    NSRect(x: offset, y: -offset, width: 48, height: 48),
                    contents: icon
                )
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            // Where the preview shrinks back. `pressureChange` does report the
            // release on its own, but not always before the mouse-up, and a
            // preview still open after the finger is off is the one state this
            // must never end in.
            let wasDeep = deep
            setDeep(false)
            defer {
                mouseDownPoint = nil
                dragging = false
            }
            // The click that opened the preview is spent on opening it.
            guard !wasDeep else { return }
            guard !dragging else { return }
            if event.clickCount >= 2 {
                onDoubleClick()
            } else {
                onClick(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
            }
        }

        func draggingSession(
            _ session: NSDraggingSession,
            sourceOperationMaskFor context: NSDraggingContext
        ) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .move, .link, .generic] : []
        }
    }
}

/// Where each shelf card sits on screen, which is what Quick Look zooms out
/// of and back into.
///
/// A view is the one thing that knows its own screen frame without a chain of
/// coordinate-space conversions, and the shelf already covers every card with
/// one — so the drag handles double as the register. The table holds them
/// weakly: a card that leaves the shelf drops out of it without being told.
enum ShelfCardFrames {
    private static let views = NSMapTable<NSURL, NSView>.strongToWeakObjects()

    static func register(_ view: NSView, for url: URL) {
        views.setObject(view, forKey: url as NSURL)
    }

    /// `.zero` for a card that is not on screen — off the shelf, or on a
    /// panel that has folded away since. Quick Look reads that as "nowhere to
    /// zoom from" and fades instead, which is the right picture for a file
    /// whose card is not visible.
    static func screenFrame(for url: URL) -> NSRect {
        guard let view = views.object(forKey: url as NSURL),
              let window = view.window, window.isVisible, view.superview != nil else { return .zero }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }
}
