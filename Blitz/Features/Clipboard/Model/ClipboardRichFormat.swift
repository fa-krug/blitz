import Foundation

/// A styled flavour kept beside a text entry's plain text, as a file the store owns.
enum ClipboardRichFormat: String, CaseIterable, Sendable {
    case rtf = "public.rtf"
    case html = "public.html"

    /// Past this a flavour is dropped and the entry keeps only its plain text.
    static let maxBytes = 1_000_000

    var fileExtension: String {
        switch self {
        case .rtf: "rtf"
        case .html: "html"
        }
    }

    var title: String {
        switch self {
        case .rtf: "Rich Text"
        case .html: "HTML"
        }
    }
}
