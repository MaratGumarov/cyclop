import AppKit

/// What the translate tab holds: the pair of languages, the text on both
/// sides, and the last thing that went wrong. The translating itself is
/// `Gemini`'s.
@MainActor
final class Translator: ObservableObject {
    /// A language the panel offers. The code is ISO 639-1, which is both what
    /// `Locale` names for the picker and what the model is told to work in.
    struct Language: Identifiable, Hashable {
        let code: String
        var id: String { code }

        /// "Русский", "English" — in the language the panel itself is in, not
        /// the system's: those two can differ, and a column headed in one
        /// language above a button worded in another reads as a mistake.
        var name: String {
            Locale(identifier: appLanguage).localizedString(forLanguageCode: code)?.sentenceCased
                ?? code.uppercased()
        }

        /// What the model is told. English names, because that is the language
        /// the instruction around them is written in.
        var englishName: String {
            Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        }
    }

    /// Not a capability list — a model translates anything — but a menu, and a
    /// menu is only useful while it stays short enough to look through. These
    /// are the languages this panel is plausibly pointed at, sorted by the
    /// name they show under.
    static let languages: [Language] = [
        "ar", "az", "be", "bg", "cs", "da", "de", "el", "en", "es", "et", "fa",
        "fi", "fr", "he", "hi", "hr", "hu", "hy", "id", "it", "ja", "ka", "kk",
        "ko", "ky", "lt", "lv", "nl", "no", "pl", "pt", "ro", "ru", "sk", "sl",
        "sr", "sv", "th", "tr", "tt", "uk", "uz", "vi", "zh",
    ]
    .map(Language.init(code:))
    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

    static func language(_ code: String?) -> Language? {
        guard let code else { return nil }
        return languages.first { $0.code == code }
    }

    /// Keyed by the pane's debounced task: a change to any part of it is a new
    /// request. The counter is what makes a retry of unchanged text one too.
    struct Request: Equatable {
        var text: String
        var source: String
        var target: String
        var attempt: Int
    }

    @Published var input = ""
    @Published private(set) var output = ""
    @Published private(set) var failure: String?
    /// The failure is a missing or refused key, which is a thing the user can
    /// go and fix — so the pane offers the way to Settings.
    @Published private(set) var needsKey = false

    @Published var source: Language { didSet { save() } }
    @Published var target: Language { didSet { save() } }

    private var attempt = 0

    private static let sourceKey = "translateSource"
    private static let targetKey = "translateTarget"

    init() {
        let defaults = UserDefaults.standard
        source = Self.language(defaults.string(forKey: Self.sourceKey)) ?? Language(code: "en")
        target = Self.language(defaults.string(forKey: Self.targetKey)) ?? Language(code: "ru")
    }

    var request: Request {
        Request(text: trimmed, source: source.code, target: target.code, attempt: attempt)
    }

    var trimmed: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Both sides turn around at once, text included. Turning only the
    /// languages would leave the box holding text in what has just become the
    /// target language, and the next translation would be a no-op — the swap
    /// is pressed precisely when the pair was the wrong way round, and the
    /// answer already on screen is the thing to carry on from.
    func swap() {
        let wasSource = source
        source = target
        target = wasSource
        if !output.isEmpty {
            input = output
            output = ""
        }
    }

    func retry() {
        attempt += 1
    }

    func clear() {
        output = ""
        failure = nil
        needsKey = false
    }

    func reset() {
        input = ""
        clear()
    }

    func translate() async {
        let text = trimmed
        guard !text.isEmpty else { clear(); return }
        do {
            let translated = try await Gemini.translate(text, from: source.englishName, to: target.englishName)
            guard !Task.isCancelled else { return }
            output = translated
            failure = nil
            needsKey = false
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            output = ""
            needsKey = (error as? Gemini.Failure)?.needsKey ?? false
            failure = error.localizedDescription
        }
    }

    func copyOutput() {
        guard !output.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(output, forType: .string)
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(source.code, forKey: Self.sourceKey)
        defaults.set(target.code, forKey: Self.targetKey)
    }
}
