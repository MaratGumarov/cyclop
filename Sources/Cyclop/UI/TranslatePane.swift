import SwiftUI

/// Two columns, the way every translator is laid out: source on the left,
/// result on the right. The left one sits on a surface — that is the whole
/// signal that it can be typed into, since a caret only shows up once there
/// is something in it.
struct TranslatePane: View {
    @ObservedObject var translator: Translator
    /// Whether the panel holds the keyboard. Drops to false when the user
    /// clicks into another app, and the field follows it — the caret has to
    /// stop blinking here when it has genuinely gone elsewhere.
    @Binding var wantsKeyboard: Bool
    /// Where the key is entered. The pane knows it is missing; only the panel
    /// knows how to get to the tab that takes it.
    var openSettings: () -> Void

    /// Which end of the pair the language list is open for, if either.
    private enum Side { case source, target }

    @FocusState private var focused: Bool
    @State private var picking: Side?
    /// Measured once, off the layout path. See `body`.
    @State private var paneSize: CGSize = .zero

    /// Largest first. Four rungs, far enough apart that a change is always a
    /// deliberate-looking drop rather than a wobble.
    private let ladder: [CGFloat] = [27, 20, 15, 11]

    var body: some View {
        let font = fontSize(in: paneSize)
        HStack(alignment: .top, spacing: 10) {
            source(font)
            result(font)
        }
        // Measured from a background layer rather than by wrapping the content
        // in a GeometryReader. Wrapped, the type size depends on a measurement
        // that depends on the very text being sized, so every wrap onto a new
        // line costs a second layout pass — which is exactly the hitch one sees
        // at the moment a line breaks. The panel never changes size, so this
        // reads once and then stays put.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { paneSize = proxy.size }
                    .onChange(of: proxy.size) { _, new in paneSize = new }
            }
        )
        // The list covers the pane rather than dropping out of the header.
        // A menu is a window of its own, and it would hang below a panel that
        // closes the moment the pointer leaves it — so the pointer would have
        // to leave the panel to reach the language it came for.
        .overlay {
            if let picking {
                languages(for: picking)
                    .transition(.opacity)
            }
        }
        .animation(Theme.contentAnimation, value: picking)
        .padding(.top, 2)
        // One task for the text, the pair and the retry counter: a keystroke
        // cancels the pending sleep, so only a pause actually translates.
        .task(id: translator.request) { await schedule() }
        .onAppear { focused = wantsKeyboard }
        .onChange(of: wantsKeyboard) { _, wants in focused = wants }
    }

    // MARK: - Left

    private func source(_ font: CGFloat) -> some View {
        column {
            title(translator.source.name) { picking = picking == .source ? nil : .source }
        } accessory: {
            Button { translator.swap() } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help(localized("Swap languages"))

            if !translator.input.isEmpty {
                Button { translator.reset() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
            }
        } content: {
            // A `TextField(axis: .vertical)` grows to fit its text, and growing
            // means reporting a new intrinsic size, which invalidates layout
            // all the way to the root of the panel — once per wrapped line,
            // which is precisely when the hitch showed. An editor takes the
            // rectangle it is given and re-wraps inside it, so a new line
            // costs nothing outside its own bounds.
            TextEditor(text: $translator.input)
                .textEditorStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                .font(.system(size: font))
                .foregroundStyle(.white)
                // Grey rather than the system accent: the caret has to say
                // where typing lands without being the brightest thing in a
                // panel that is mostly dark and mostly still.
                .tint(Theme.secondary)
                .focused($focused)
                // The editor insets its text by a few points of its own; pull
                // that back so the first character lines up with the title.
                .padding(.leading, -5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .contentShape(Rectangle())
                .onKeyPress(.escape) {
                    // The list first: Escape closes what is on top of the
                    // pane before it throws away what is in it.
                    if picking != nil {
                        picking = nil
                    } else {
                        translator.reset()
                    }
                    return .handled
                }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.surface)
        )
    }

    // MARK: - Right

    private func result(_ font: CGFloat) -> some View {
        column {
            title(translator.target.name) { picking = picking == .target ? nil : .target }
        } accessory: {
            if !translator.output.isEmpty {
                CopyButton { translator.copyOutput() }
            }
        } content: {
            outcome(font)
        }
        .padding(10)
    }

    @ViewBuilder
    private func outcome(_ font: CGFloat) -> some View {
        if let failure = translator.failure {
            VStack(alignment: .leading, spacing: 6) {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    if translator.needsKey {
                        Button(localized("Settings")) { openSettings() }
                    }
                    Button(localized("Retry")) { translator.retry() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if !translator.output.isEmpty {
            ScrollView(showsIndicators: false) {
                Text(translator.output)
                    .font(.system(size: font))
                    .foregroundStyle(.white)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            // Nothing while it works. The translation lands in a fraction of a
            // second, so a status would be a word that flashes up and leaves —
            // more movement in the column than the result it announces.
            Color.clear
        }
    }

    // MARK: - Languages

    private func languages(for side: Side) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text((side == .source ? localized("Translate from") : localized("Translate into")).uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.tertiary)
                Spacer(minLength: 4)
                Button { picking = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
            }
            .frame(height: 14)

            ScrollView(showsIndicators: false) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 104), spacing: 4)],
                    alignment: .leading,
                    spacing: 4
                ) {
                    ForEach(Translator.languages) { language in
                        entry(language, side: side)
                    }
                }
            }
        }
        .padding(10)
        // Opaque, not a blur: the pane underneath is text, and text showing
        // through a list of language names is unreadable at this size.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.94))
        )
    }

    private func entry(_ language: Translator.Language, side: Side) -> some View {
        let current = side == .source ? translator.source : translator.target
        let isCurrent = language == current
        return Button {
            choose(language, for: side)
        } label: {
            Text(language.name)
                .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isCurrent ? Color.white : Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isCurrent ? Theme.surfaceHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Picking the language the other side already holds turns the pair round
    /// rather than leaving both ends on the same language, which translates
    /// nothing.
    private func choose(_ language: Translator.Language, for side: Side) {
        let other = side == .source ? translator.target : translator.source
        if language == other {
            translator.swap()
        } else if side == .source {
            translator.source = language
        } else {
            translator.target = language
        }
        picking = nil
    }

    // MARK: - Type size
    //
    // A word should read like a headline and a paragraph has to fit, so the
    // size has to move — but it moves in steps, not continuously. Sizing the
    // type to the exact text length means every keystroke re-breaks every line
    // for a fraction of a point nobody asked for, and that reads as the text
    // shaking rather than as anything smooth. One decisive drop, rarely, is
    // both calmer to look at and easier to trust.

    /// What the text actually gets to occupy inside one column: half the pane
    /// minus the gap, minus the padding, minus the title row above it.
    private func textArea(in size: CGSize) -> CGSize {
        CGSize(
            width: max(40, (size.width - 10) / 2 - 20),
            height: max(40, size.height - 40)
        )
    }

    /// The largest rung the text still fits on. Both columns share it, computed
    /// from whichever side is longer — sides set at different scales stop
    /// looking like a pair.
    private func fontSize(in size: CGSize) -> CGFloat {
        let count = CGFloat(max(translator.trimmed.count, translator.output.count))
        // Before the first measurement lands there is nothing to fit type to,
        // and the pane is empty anyway.
        guard count > 0, size.width > 0, size.height > 0 else { return ladder[0] }
        // A glyph runs about half its point size wide and 1.3 of it tall with
        // leading, so roughly `area / (0.76 · s²)` characters fit at size `s`.
        // The 0.95 keeps the last line from being the one that overflows.
        let area = textArea(in: size)
        let usable = area.width * area.height * 0.95
        return ladder.first { count <= usable / (0.76 * $0 * $0) } ?? ladder[ladder.count - 1]
    }

    // MARK: - Shared

    /// The column heading, which is also the button that opens the list. The
    /// chevron is what says so — a name alone would read as a label.
    private func title(_ name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(name.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .black))
            }
            .foregroundStyle(Theme.tertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func column<Title: View, Accessory: View, Content: View>(
        @ViewBuilder title: () -> Title,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                title()
                Spacer(minLength: 4)
                accessory()
            }
            .frame(height: 14)

            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Scheduling

    private func schedule() async {
        guard !translator.trimmed.isEmpty else {
            translator.clear()
            return
        }
        // Wait out the typing: a word is a handful of keystrokes, and a request
        // per letter would be both wasteful and visibly jumpy.
        try? await Task.sleep(for: .milliseconds(320))
        guard !Task.isCancelled else { return }
        await translator.translate()
    }
}
