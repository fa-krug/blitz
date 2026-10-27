import Foundation

/// A prop value from the runtime; `node` is an element-valued prop hoisted out of a `__slot`.
enum RenderValue: Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case date(Date)
    case handler(String)
    case array([RenderValue])
    case object([String: RenderValue])
    case node(RenderNode)
    case null

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        case .number(let value):
            // Whole numbers arrive as Doubles; an accessory reading "3.0" would be wrong.
            return value == value.rounded() && value.magnitude < 1e15
                ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .number(let value): return value != 0
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .string(let value): return Double(value)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    var dateValue: Date? {
        if case .date(let date) = self { return date }
        return nil
    }

    var handlerID: String? {
        if case .handler(let id) = self { return id }
        return nil
    }

    var arrayValue: [RenderValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    var objectValue: [String: RenderValue]? {
        if case .object(let values) = self { return values }
        return nil
    }

    var nodeValue: RenderNode? {
        if case .node(let node) = self { return node }
        return nil
    }

    /// A slot prop holding several nodes (`ActionPanel` children hoisted from a submenu) or one.
    var nodesValue: [RenderNode] {
        switch self {
        case .node(let node): return [node]
        case .array(let values): return values.compactMap(\.nodeValue)
        default: return []
        }
    }

    /// Plain-JSON form, for handing a value back to JS unchanged (a Form field's current value).
    var jsonValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .date(let value): return ["$date": ISO8601DateFormatter().string(from: value)]
        case .handler(let id): return ["$fn": id]
        case .array(let values): return values.map(\.jsonValue)
        case .object(let values): return values.mapValues(\.jsonValue)
        case .node: return NSNull()
        case .null: return NSNull()
        }
    }

    /// How host-call arguments cross from the JS thread to the main actor as `Sendable`.
    static func arguments(from json: String) -> [RenderValue] {
        ExtensionRuntime.jsonArray(from: json).map(RenderValue.init(json:))
    }

    init(json: Any) {
        let object = json as AnyObject
        switch CFGetTypeID(object) {
        case CFStringGetTypeID():
            self = .string(unsafeDowncast(object, to: NSString.self) as String)
        // NSNumber erases Bool; CFBoolean identity is the only reliable discriminator.
        case CFBooleanGetTypeID():
            self = .bool(unsafeDowncast(object, to: NSNumber.self).boolValue)
        case CFNumberGetTypeID():
            self = .number(unsafeDowncast(object, to: NSNumber.self).doubleValue)
        case CFArrayGetTypeID():
            self = .array(unsafeDowncast(object, to: NSArray.self).map(RenderValue.init(json:)))
        case CFDictionaryGetTypeID():
            let value = unsafeDowncast(object, to: NSDictionary.self)
            if let handler = value.string("$fn") {
                self = .handler(handler)
            } else if let iso = value.string("$date") {
                self = .date(RenderValue.parseDate(iso) ?? Date())
            } else if let node = RenderNode(json: value), node.isElement {
                self = .node(node)
            } else {
                self = .object(value.renderValues(RenderValue.init(json:)))
            }
        default:
            self = .null
        }
    }

    /// A delta's prop: the value itself, or each item of an array, is an element position.
    fileprivate init(prop json: Any, base: [RenderNode.ID: RenderNode]) throws {
        guard let items = json as? NSArray else {
            self = try RenderValue(position: json, base: base)
            return
        }
        self = .array(try items.map { try RenderValue(position: $0, base: base) })
    }

    /// Below a position nothing is a reference, which the runtime guarantees by sending whole.
    private init(position json: Any, base: [RenderNode.ID: RenderNode]) throws {
        guard let object = json as? NSDictionary, object["$fn"] == nil,
            object["$date"] == nil,
            let node = try RenderNode(position: object, base: base), node.isElement
        else {
            self = RenderValue(json: json)
            return
        }
        self = .node(node)
    }

    /// The format style is `Sendable`, so it can be a shared constant under strict concurrency.
    private static let fractionalISO = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainISO = Date.ISO8601FormatStyle()

    static func parseDate(_ text: String) -> Date? {
        (try? fractionalISO.parse(text)) ?? (try? plainISO.parse(text))
    }
}

/// One node of the tree an extension's React render produced.
struct RenderNode: Sendable, Hashable, Identifiable {
    let id: Int
    let type: String
    let props: [String: RenderValue]
    let children: [RenderNode]
    /// Set only for text nodes (`type == "#text"`).
    let text: String?

    var isText: Bool { type == "#text" }
    /// The discriminator keeping an ordinary prop object from reading as a hoisted slot node.
    var isElement: Bool { !isText && id > 0 }

    init(
        id: Int, type: String, props: [String: RenderValue] = [:], children: [RenderNode] = [],
        text: String? = nil
    ) {
        self.id = id
        self.type = type
        self.props = props
        self.children = children
        self.text = text
    }

    init?(json: [String: Any]) {
        self.init(json: json as NSDictionary)
    }

    init?(json: NSDictionary) {
        // A nil base reads nothing as a reference, so this cannot throw.
        guard let node = try? RenderNode(json: json, base: nil) else { return nil }
        self = node
    }

    /// `base` is set only for a delta, whose `{"$same": id}` at an element position reuses a node.
    fileprivate init?(json: NSDictionary, base: [ID: RenderNode]?) throws {
        guard let type = json.string("type") else { return nil }
        if type == "#text" {
            self.init(id: 0, type: type, text: json.string("text") ?? "")
            return
        }
        guard let id = json.int("id"), let rawProps = json["props"] as? NSDictionary,
            let rawChildren = json["children"] as? NSArray
        else { return nil }
        guard let base else {
            self.init(
                id: id, type: type,
                props: rawProps.renderValues(RenderValue.init(json:)),
                children: rawChildren.compactMap {
                    ($0 as? NSDictionary).flatMap(RenderNode.init(json:))
                })
            return
        }
        self.init(
            id: id, type: type,
            props: try rawProps.renderValues { try RenderValue(prop: $0, base: base) },
            children: try rawChildren.compactMap { try RenderNode(position: $0, base: base) })
    }

    /// An element position in a delta: a reference to the previous tree, or a node of its own.
    fileprivate init?(position json: Any, base: [ID: RenderNode]) throws {
        guard let object = json as? NSDictionary else { return nil }
        if object["$same"] != nil {
            guard let id = object.int("$same"), let node = base[id] else {
                throw RenderTree.DecodeError.missingBase
            }
            self = node
            return
        }
        try self.init(json: object, base: base)
    }

    // MARK: - Prop access

    func string(_ key: String) -> String? {
        props[key]?.stringValue ?? props[key]?.objectValue?["value"]?.stringValue
    }
    func bool(_ key: String) -> Bool? { props[key]?.boolValue }
    func double(_ key: String) -> Double? { props[key]?.doubleValue }
    func date(_ key: String) -> Date? { props[key]?.dateValue }
    func handler(_ key: String) -> String? { props[key]?.handlerID }
    func node(_ key: String) -> RenderNode? { props[key]?.nodeValue }
    func nodes(_ key: String) -> [RenderNode] { props[key]?.nodesValue ?? [] }
    func array(_ key: String) -> [RenderValue] { props[key]?.arrayValue ?? [] }
    func object(_ key: String) -> [String: RenderValue]? { props[key]?.objectValue }

    /// Depth-first search for the first descendant of `type`, following hoisted slot props too.
    func firstDescendant(ofType type: String) -> RenderNode? {
        if self.type == type { return self }
        for child in children {
            if let hit = child.firstDescendant(ofType: type) { return hit }
        }
        for value in props.values {
            for node in value.nodesValue {
                if let hit = node.firstDescendant(ofType: type) { return hit }
            }
        }
        return nil
    }
}

/// The root the runtime pushes after each changing commit: one `__screen` per stack entry.
struct RenderTree: Sendable, Equatable {
    let screens: [RenderNode]

    init(screens: [RenderNode]) {
        self.screens = screens
    }

    enum DecodeError: Error {
        case malformed
        /// A delta named a node the previous tree did not hold, so the runtime must send it whole.
        case missingBase
    }

    init?(json: String) {
        guard let tree = try? RenderTree(json: json, reusing: [:]) else { return nil }
        self = tree
    }

    /// `previous` is `referenceableNodes` of the last tree decoded for this session.
    init(json: String, reusing previous: [RenderNode.ID: RenderNode]) throws(DecodeError) {
        guard let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? NSDictionary,
            let children = root["children"] as? NSArray
        else { throw .malformed }
        let base = root["delta"] as? Bool == true ? previous : nil
        let nodes: [RenderNode]
        do {
            nodes = try children.compactMap { child in
                guard let base else {
                    return (child as? NSDictionary).flatMap(RenderNode.init(json:))
                }
                return try RenderNode(position: child, base: base)
            }
        } catch {
            throw .missingBase
        }
        // A no-view command renders nothing; a view command wraps every screen in `__screen`.
        screens = nodes.filter { $0.type == "__screen" }
    }

    /// Every element at a position the runtime's next delta may refer back to, by id.
    var referenceableNodes: [RenderNode.ID: RenderNode] {
        var nodes: [RenderNode.ID: RenderNode] = [:]
        func walk(_ node: RenderNode) {
            guard node.isElement else { return }
            nodes[node.id] = node
            node.children.forEach(walk)
            for value in node.props.values {
                switch value {
                case .node(let child): walk(child)
                case .array(let items): items.forEach { $0.nodeValue.map(walk) }
                default: break
                }
            }
        }
        screens.forEach(walk)
        return nodes
    }

    /// The screen the palette shows — the top of the navigation stack.
    var active: RenderNode? {
        screens.last { $0.bool("active") == true } ?? screens.last
    }

    /// The single root component of the active screen (a `List`, `Detail`, `Form`, `Grid`, …).
    var activeRoot: RenderNode? {
        active?.children.first { !$0.isText }
    }

    var depth: Int { max(screens.count, 1) }
}

/// A big tree decodes per commit, and Swift's dynamic casts from `Any` cost more than the parse.
extension NSDictionary {
    fileprivate func string(_ key: NSString) -> String? {
        guard let value = object(forKey: key) as AnyObject?,
            CFGetTypeID(value) == CFStringGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: NSString.self) as String
    }

    fileprivate func int(_ key: NSString) -> Int? {
        guard let value = object(forKey: key) as AnyObject?,
            CFGetTypeID(value) == CFNumberGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: NSNumber.self).intValue
    }

    fileprivate func renderValues(
        _ transform: (Any) throws -> RenderValue
    ) rethrows -> [String: RenderValue] {
        var values = [String: RenderValue](minimumCapacity: count)
        for (key, value) in self {
            let key = key as AnyObject
            guard CFGetTypeID(key) == CFStringGetTypeID() else { continue }
            values[unsafeDowncast(key, to: NSString.self) as String] = try transform(value)
        }
        return values
    }
}
