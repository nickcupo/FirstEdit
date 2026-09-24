import Foundation

extension Strings {
    /// The host's own sentences. **Not one word an extension contributes is
    /// here**: its question, its yes and no words, its badges and its step
    /// labels are read from `ExtConfig` at runtime and never compiled in,
    /// never in a string catalog and never in a fixture (DESIGN.md §2.16).
    ///
    /// These are all the app talking about itself.
    public enum Extensions {
        public static var page: String {
            String(localized: "extension.page", defaultValue: "Page",
                   comment: "What VoiceOver calls the pane an added step draws in, before its own label is known.")
        }
        public static var noPage: String {
            String(localized: "extension.noPage", defaultValue: "This step has no page to show.",
                   comment: "A step was declared but no address for it was.")
        }
        public static var notServed: String {
            String(localized: "extension.notServed", defaultValue: "This page asked for something it is not being served.",
                   comment: "A request outside the origin the page was served from.")
        }
        public static var wentOutside: String {
            String(localized: "extension.wentOutside", defaultValue: "This page tried to open something outside FirstEdit. Nothing was opened.",
                   comment: "A navigation off the local origin, refused.")
        }
        public static var notRunning: String {
            String(localized: "extension.notRunning", defaultValue: "This page is not running inside FirstEdit.",
                   comment: "The bridge was called with nothing behind it.")
        }
        public static var badCall: String {
            String(localized: "extension.badCall", defaultValue: "FirstEdit did not understand what this page asked for.",
                   comment: "A bridge call that does not name one of the three things.")
        }
        public static var noFrames: String {
            String(localized: "extension.noFrames", defaultValue: "This page asked to show frames and named none.",
                   comment: "viewFrames with an empty list.")
        }
        public static var confirmNeedsWords: String {
            String(localized: "extension.confirmNeedsWords",
                   defaultValue: "FirstEdit will not ask a question with no words in it.",
                   comment: "confirmDestructive without a title or a button label.")
        }

        public static var dismissRefusal: String {
            String(localized: "extension.dismissRefusal", defaultValue: "Dismiss",
                   comment: "The x beside a refusal under an added step's page: puts it away.")
        }

        public static var reload: String {
            String(localized: "extension.reload", defaultValue: "Reload This Page", comment: "Context menu item.")
        }
        public static var copy: String {
            String(localized: "extension.copy", defaultValue: "Copy", comment: "Context menu item.")
        }
        public static var selectAll: String {
            String(localized: "extension.selectAll", defaultValue: "Select All", comment: "Context menu item.")
        }
        public static var cancel: String {
            String(localized: "extension.cancel", defaultValue: "Cancel", comment: "The default button on the app's sheet.")
        }
        public static var ok: String {
            String(localized: "extension.ok", defaultValue: "OK", comment: "The page asked something with one answer.")
        }
        public static var done: String {
            String(localized: "extension.done", defaultValue: "Done", comment: "Closes the viewer a page opened.")
        }
        public static var previousFrame: String {
            String(localized: "extension.previousFrame", defaultValue: "Previous Frame", comment: "In the viewer a page opened.")
        }
        public static var nextFrame: String {
            String(localized: "extension.nextFrame", defaultValue: "Next Frame", comment: "In the viewer a page opened.")
        }
        public static var doneHelp: String {
            String(localized: "extension.done.help", defaultValue: "Return, Space or Escape",
                   comment: "The viewer's Done button's help tag: the keys that close it.")
        }
        public static func markHelp(_ label: String, _ key: String) -> String {
            String(localized: "extension.markHelp", defaultValue: "\(label) (\(key))",
                   comment: "A mark's checkbox in the viewer: the step's own words, then the one key that toggles it.")
        }
        public static func ofFrames(_ n: Int, _ total: Int) -> String {
            String(localized: "extension.ofFrames", defaultValue: "\(n) of \(total)",
                   comment: "Where he is in the frames a page asked to show.")
        }
    }
}

extension RefusalOwner {
    /// A page of an added step. It writes its own refusals and nothing else
    /// clears them.
    public static let extensionPage = RefusalOwner("extension.page")
}
