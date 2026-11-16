import Foundation

enum NoteWordCount {
    /// ICU word boundaries, so Markdown markers and punctuation are not words and CJK still splits.
    static func count(in source: String) -> Int {
        let text = source as NSString
        var count = 0
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: text.length),
            options: [.byWords, .substringNotRequired]
        ) { _, _, _, stop in
            count += 1
            if Task.isCancelled { stop.pointee = true }
        }
        return count
    }
}
