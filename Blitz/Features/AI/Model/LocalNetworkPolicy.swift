import Foundation

/// Whether a URL names this Mac or its local network, judged from its spelling alone, never DNS.
enum LocalNetworkPolicy {
    /// Names reserved for private use, besides `localhost` and `.local` itself.
    private static let localSuffixes = [".localhost", ".local", ".home.arpa", ".internal"]

    static func isLocal(_ url: URL) -> Bool {
        isLocal(host: url.host(percentEncoded: false) ?? "")
    }

    /// An empty host counts as local: whatever a resolver makes of it, it is not the internet.
    static func isLocal(host: String) -> Bool {
        var name = host.lowercased()
        if name.hasPrefix("["), name.hasSuffix("]") { name = String(name.dropFirst().dropLast()) }
        while name.hasSuffix(".") { name.removeLast() }
        guard !name.isEmpty, name != "localhost" else { return true }
        if localSuffixes.contains(where: name.hasSuffix) { return true }
        if let address = ipv4(name) { return isLocal(ipv4: address) }
        if let address = ipv6(name) { return isLocal(ipv6: address) }
        return false
    }

    /// Every spelling `inet_aton` takes, as the resolver does: `127.1`, `0x7f.0.0.1`, `2130706433`.
    static func ipv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        var values: [UInt64] = []
        for part in parts {
            guard let value = number(part) else { return nil }
            values.append(value)
        }
        let leading = values.dropLast()
        guard leading.allSatisfy({ $0 <= 255 }), let last = values.last,
            last < UInt64(1) << (32 - 8 * leading.count)
        else { return nil }
        let high = leading.enumerated().reduce(UInt64(0)) { $0 | $1.element << (24 - 8 * $1.offset) }
        return UInt32(high | last)
    }

    private static func number(_ part: Substring) -> UInt64? {
        let lower = part.lowercased()
        let (digits, radix) =
            if lower.hasPrefix("0x") {
                (lower.dropFirst(2), 16)
            } else if lower.count > 1, lower.hasPrefix("0") {
                (lower.dropFirst(), 8)
            } else {
                (Substring(lower), 10)
            }
        guard !digits.isEmpty, digits.count <= 12, let value = UInt64(digits, radix: radix),
            value <= UInt64(UInt32.max)
        else { return nil }
        return value
    }

    /// The zone of a link-local address (`fe80::1%en0`) is dropped; the prefix alone decides.
    static func ipv6(_ text: String) -> [UInt8]? {
        let address = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        guard address.contains(":") else { return nil }
        var parsed = in6_addr()
        guard inet_pton(AF_INET6, address, &parsed) == 1 else { return nil }
        return withUnsafeBytes(of: parsed) { Array($0) }
    }

    /// Unspecified, loopback, link-local, RFC 1918 and the shared range carriers and VPNs use.
    static func isLocal(ipv4 address: UInt32) -> Bool {
        let ranges: [(network: UInt32, bits: UInt32)] = [
            (0x0000_0000, 8), (0x0A00_0000, 8), (0x7F00_0000, 8), (0xA9FE_0000, 16),
            (0xAC10_0000, 12), (0xC0A8_0000, 16), (0x6440_0000, 10)
        ]
        return ranges.contains { address & ~(UInt32.max >> $0.bits) == $0.network }
    }

    /// Unspecified, loopback, ULA `fc00::/7`, link- and site-local, and IPv4 carried inside.
    static func isLocal(ipv6 bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0] & 0xFE == 0xFC { return true }
        if bytes[0] == 0xFE, bytes[1] & 0x80 == 0x80 { return true }
        let embedded = bytes[12...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let isCompatible = bytes[..<12].allSatisfy { $0 == 0 }
        let isMapped = bytes[..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
        let isTranslated = bytes[..<12].elementsEqual([0, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0])
        return (isCompatible || isMapped || isTranslated) && isLocal(ipv4: embedded)
    }
}
