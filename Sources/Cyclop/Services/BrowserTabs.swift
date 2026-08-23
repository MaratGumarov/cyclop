import Foundation

/// AppleScript that raises the browser tab whose title contains the text.
///
/// Safari and the Chromium family speak nearly the same dictionary and differ
/// only in how a tab is made current; Arc has its own verb. Anything else
/// gets nil and stays at "the browser is frontmost", which is still a step.
enum BrowserTabs {
    static func selectScript(bundleID: String, titleContains needle: String) -> String? {
        let escaped = needle
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let select: String
        switch bundleID {
        case "com.apple.Safari":
            select = "set current tab of w to t"
        case "company.thebrowser.Browser":
            select = "tell t to select"
        case let id where id.hasPrefix("com.google.Chrome")
            || ["com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "org.chromium.Chromium"].contains(id):
            select = "set active tab index of w to i"
        default:
            return nil
        }
        let name = bundleID == "com.apple.Safari" ? "name" : "title"
        return """
        tell application id "\(bundleID)"
            repeat with w in windows
                set i to 0
                repeat with t in tabs of w
                    set i to i + 1
                    if \(name) of t contains "\(escaped)" then
                        \(select)
                        set index of w to 1
                        return true
                    end if
                end repeat
            end repeat
        end tell
        return false
        """
    }
}
