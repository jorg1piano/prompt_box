import Foundation

public enum Paths {
    /// Tabs, history and deleted text.
    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PromptBox", isDirectory: true)
    }

    /// The single draft from before tabs; moved into the first tab on launch.
    public static var draft: URL { support.appendingPathComponent("draft.rtfd", isDirectory: true) }
    public static var tabs: URL { support.appendingPathComponent("tabs", isDirectory: true) }
    public static var history: URL { support.appendingPathComponent("history", isDirectory: true) }
    public static var deleted: URL { support.appendingPathComponent("deleted", isDirectory: true) }

    /// Images pasted into a terminal as paths. Lives in Caches because "Application Support" has a
    /// space in it, and a path with a space breaks when a terminal agent parses it.
    public static var images: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("no.devda.PromptBox/images", isDirectory: true)
    }
}
