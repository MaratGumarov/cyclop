import SwiftUI
import Translation

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

    @FocusState private var focused: Bool
    @State private var configuration: TranslationSession.Configuration?
    /// Measured once, off the layout path. See `body`.
    @State private var paneSize: CGSize = .zero
    /// Which side the language list is standing in for, while it is open.
    @State private var picking: Side?

    private enum Side { case source, target }

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
        .padding(.top, 2)
        .overlay {
            if let side = picking { picker(side) }
        }
        // One task for both the text and the retry counter: a keystroke
        // cancels the pending sleep, so only a pause actually translates.
        .task(id: translator.request) { await schedule() }
        .translationTask(configuration) { session in
            await translator.run(session)
        }
        .onAppear { focused = wantsKeyboard }
        .onChange(of: wantsKeyboard) { _, wants in focused = wants }
    }

    // MARK: - Left

    private func source(_ font: CGFloat) -> some View {
        column {
            languageButton(translator.route.source, side: .source)
            Spacer(minLength: 4)
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
                // The list covers the pane but not the keyboard: the field
                // still holds focus underneath, so Escape arrives here either
                // way and has to close whichever of the two is open.
                .onKeyPress(.escape) {
                    if picking != nil {
                        withAnimation(Theme.contentAnimation) { picking = nil }
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
            // The arrows lead the right column, which puts them within a few
            // points of the middle of the pane — between the two languages,
            // where every translator has always put them.
            Button { withAnimation(Theme.contentAnimation) { translator.swap() } } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
            .help(localized("Swap languages"))

            languageButton(translator.route.target, side: .target)
            Spacer(minLength: 4)
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
                    if translator.needsDownload {
                        Button("Translation Languages…") { Translator.openLanguageSettings() }
                    }
                    Button("Retry") { translator.retry() }
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

    private func column<Header: View, Content: View>(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                header()
            }
            .frame(height: 14)

            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Languages

    /// The heading doubles as the control: the name of the language is the
    /// obvious thing to click when one wants a different language, and a pane
    /// this small has nowhere to put a button that only says "change this".
    private func languageButton(_ language: Locale.Language, side: Side) -> some View {
        Button {
            withAnimation(Theme.contentAnimation) {
                picking = picking == side ? nil : side
            }
        } label: {
            HStack(spacing: 3) {
                Text(Translator.name(language).uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 6, weight: .bold))
            }
            .foregroundStyle(picking == side ? .white : Theme.tertiary)
        }
        .buttonStyle(.plain)
    }

    /// The list fills the pane rather than dropping out of the heading as a
    /// menu would. The panel folds away the moment the pointer leaves it, and a
    /// menu of twenty languages hangs well below its edge — reaching for an
    /// entry would pull the panel out from under the list.
    private func picker(_ side: Side) -> some View {
        let current = side == .source ? translator.route.source : translator.route.target
        return VStack(alignment: .leading, spacing: 8) {
            // Built rather than written as a literal, so it has to be looked
            // up by hand — `Text` only localises what it is handed verbatim.
            Text(localized(side == .source ? "Translate from" : "Translate into"))
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.tertiary)

            ScrollView(showsIndicators: false) {
                LazyVGrid(
                    // Four across: the twenty-one languages macOS translates
                    // then stand six rows deep, which is about as much as the
                    // pane holds — three columns would put a third of the list
                    // below the fold.
                    columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4),
                    alignment: .leading,
                    spacing: 2
                ) {
                    ForEach(translator.languages, id: \.minimalIdentifier) { language in
                        languageCell(language, side: side, current: current)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black)
        )
        .transition(.opacity)
    }

    private func languageCell(_ language: Locale.Language, side: Side, current: Locale.Language) -> some View {
        let selected = language.minimalIdentifier == current.minimalIdentifier
        return Button {
            withAnimation(Theme.contentAnimation) { picking = nil }
            switch side {
            case .source: translator.choose(source: language)
            case .target: translator.choose(target: language)
            }
        } label: {
            Text(Translator.title(language))
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? .white : Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Theme.surface : .clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Scheduling

    private func schedule() async {
        let text = translator.trimmed
        guard !text.isEmpty else {
            configuration = nil
            translator.clear()
            return
        }
        // Wait out the typing: a word is a handful of keystrokes, and a session
        // per letter would be both wasteful and visibly jumpy.
        try? await Task.sleep(for: .milliseconds(320))
        guard !Task.isCancelled else { return }

        let route = translator.route
        if var current = configuration, current.source == route.source, current.target == route.target {
            // Same pair, different text. The modifier only re-runs when the
            // configuration changes, and invalidating is how one says "again".
            current.invalidate()
            configuration = current
        } else {
            configuration = TranslationSession.Configuration(source: route.source, target: route.target)
        }
    }
}
