import Foundation

/// What a flat selection index resolves to. Section headers aren't selectable and take no index.
enum PaletteRow: Equatable {
    case calculator
    case element(section: Int, offset: Int)
}

/// A screen's visible row order: the calculator card at index 0 when present, then each section.
struct PaletteRowIndex: Equatable {
    let hasCalculator: Bool
    let sectionCounts: [Int]

    init(hasCalculator: Bool = false, sectionCounts: [Int]) {
        self.hasCalculator = hasCalculator
        self.sectionCounts = sectionCounts
    }

    var count: Int { (hasCalculator ? 1 : 0) + sectionCounts.reduce(0, +) }

    /// The selection the screen actually highlights: out-of-range values clamp into the results.
    func clamped(_ selection: Int) -> Int {
        count == 0 ? 0 : min(max(selection, 0), count - 1)
    }

    func row(at index: Int) -> PaletteRow? {
        guard index >= 0, index < count else { return nil }
        if hasCalculator, index == 0 { return .calculator }
        var offset = hasCalculator ? index - 1 : index
        for (section, sectionCount) in sectionCounts.enumerated() {
            if offset < sectionCount { return .element(section: section, offset: offset) }
            offset -= sectionCount
        }
        return nil
    }

    /// The inverse of `row(at:)` — where a screen puts the highlight after its own list moves.
    func index(section: Int, offset: Int) -> Int? {
        guard sectionCounts.indices.contains(section), offset >= 0,
            offset < sectionCounts[section]
        else { return nil }
        let preceding = sectionCounts[..<section].reduce(0, +)
        return (hasCalculator ? 1 : 0) + preceding + offset
    }

    /// Where each section begins, the card counting as one; an empty section begins nowhere.
    var sectionStarts: [Int] {
        var starts = hasCalculator ? [0] : []
        var next = hasCalculator ? 1 : 0
        for sectionCount in sectionCounts where sectionCount > 0 {
            starts.append(next)
            next += sectionCount
        }
        return starts
    }

    /// ⌘↓ — nil from inside the last section, which has no next one to land on.
    static func nextSectionStart(after selection: Int, in starts: [Int]) -> Int? {
        starts.first { $0 > selection }
    }

    /// ⌘↑ — the head of the selection's own section, or the previous head when already there.
    static func currentOrPreviousSectionStart(before selection: Int, in starts: [Int]) -> Int? {
        starts.last { $0 < selection }
    }

    /// ⌥↑/↓ — a page of `delta` rows, stopping at either end rather than wrapping.
    static func page(from selection: Int, by delta: Int, count: Int) -> Int {
        count == 0 ? 0 : min(max(selection + delta, 0), count - 1)
    }
}
