import Foundation

/// One `UserKeyMapping` entry, usages packed as `page << 32 | usage` the way IOKit stores them.
struct HIDKeyMapping: Hashable, Sendable {
    let source: UInt64
    let destination: UInt64

    static let capsLock: UInt64 = 0x7_0000_0039
    static let f18: UInt64 = 0x7_0000_006D

    static let capsLockToF18 = HIDKeyMapping(source: capsLock, destination: f18)

    static let sourceKey = "HIDKeyboardModifierMappingSrc"
    static let destinationKey = "HIDKeyboardModifierMappingDst"

    /// Reads `hidutil property --get UserKeyMapping`; nil when the output is neither unset nor a list.
    static func mappings(fromHIDUtilOutput output: String) -> [HIDKeyMapping]? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "(null)" { return [] }
        guard let data = trimmed.data(using: .utf8),
            let list = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [Any]
        else { return nil }
        return list.compactMap { entry in
            guard let entry = entry as? [String: Any],
                let source = usage(entry[sourceKey]),
                let destination = usage(entry[destinationKey])
            else { return nil }
            return HIDKeyMapping(source: source, destination: destination)
        }
    }

    /// The `hidutil property --set` argument that installs exactly `mappings`.
    static func hidutilArgument(for mappings: [HIDKeyMapping]) -> String {
        let entries = mappings.map {
            #"{"\#(sourceKey)":\#($0.source),"\#(destinationKey)":\#($0.destination)}"#
        }
        return #"{"UserKeyMapping":["# + entries.joined(separator: ",") + "]}"
    }

    /// Entries this mapping would push out: the same source pointing anywhere else.
    func displaced(in existing: [HIDKeyMapping]) -> [HIDKeyMapping] {
        existing.filter { $0.source == source && $0 != self }
    }

    func replacingSource(in existing: [HIDKeyMapping]) -> [HIDKeyMapping] {
        existing.filter { $0.source != source } + [self]
    }

    /// Hands the source back to `original`, unless someone else has remapped it since.
    func restoring(_ original: [HIDKeyMapping], in existing: [HIDKeyMapping]) -> [HIDKeyMapping] {
        guard existing.filter({ $0.source == source }) == [self] else { return existing }
        return existing.filter { $0.source != source } + original
    }

    // The old-style plist hidutil prints carries every number as a decimal string.
    private static func usage(_ value: Any?) -> UInt64? {
        switch value {
        case let string as String: return UInt64(string)
        case let number as NSNumber: return number.uint64Value
        default: return nil
        }
    }
}
