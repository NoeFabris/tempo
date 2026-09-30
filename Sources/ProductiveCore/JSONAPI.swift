import Foundation

/// A loosely typed JSON value, used for JSON:API attributes and meta.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        default: return nil
        }
    }

    public var int: Int? {
        switch self {
        case .number(let n): return Int(n)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
}

public struct ResourceIdentifier: Codable, Equatable, Sendable {
    public let type: String
    public let id: String

    public init(type: String, id: String) {
        self.type = type
        self.id = id
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        // Some APIs send numeric ids; accept both.
        if let s = try? c.decode(String.self, forKey: .id) { id = s }
        else { id = String(try c.decode(Int.self, forKey: .id)) }
    }
}

public enum RelationshipData: Decodable, Sendable {
    case none
    case one(ResourceIdentifier)
    case many([ResourceIdentifier])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .none }
        else if let many = try? c.decode([ResourceIdentifier].self) { self = .many(many) }
        else { self = .one(try c.decode(ResourceIdentifier.self)) }
    }
}

public struct Relationship: Decodable, Sendable {
    public let data: RelationshipData?

    private enum CodingKeys: String, CodingKey { case data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if !c.contains(.data) { data = nil }
        else if try c.decodeNil(forKey: .data) { data = RelationshipData.none }
        else { data = try c.decode(RelationshipData.self, forKey: .data) }
    }
}

public struct Resource: Decodable, Sendable {
    public let id: String
    public let type: String
    public let attributes: [String: JSONValue]
    public let relationships: [String: Relationship]

    private enum CodingKeys: String, CodingKey { case id, type, attributes, relationships }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let ident = try ResourceIdentifier(from: decoder)
        id = ident.id
        type = ident.type
        attributes = try c.decodeIfPresent([String: JSONValue].self, forKey: .attributes) ?? [:]
        relationships = try c.decodeIfPresent([String: Relationship].self, forKey: .relationships) ?? [:]
    }

    public subscript(attribute key: String) -> JSONValue? {
        if case .null? = attributes[key] { return nil }
        return attributes[key]
    }

    public func related(_ key: String) -> ResourceIdentifier? {
        if case .one(let ident)? = relationships[key]?.data { return ident }
        return nil
    }
}

public struct Document: Decodable, Sendable {
    public let data: [Resource]
    public let included: [Resource]
    public let meta: [String: JSONValue]

    private enum CodingKeys: String, CodingKey { case data, included, meta }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let many = try? c.decode([Resource].self, forKey: .data) { data = many }
        else if let one = try? c.decode(Resource.self, forKey: .data) { data = [one] }
        else { data = [] }
        included = try c.decodeIfPresent([Resource].self, forKey: .included) ?? []
        meta = try c.decodeIfPresent([String: JSONValue].self, forKey: .meta) ?? [:]
    }

    public var totalPages: Int? { meta["total_pages"]?.int }
}

/// Looks up resources from `data` and `included` by type and id.
public struct ResourceIndex: Sendable {
    private var byKey: [String: Resource] = [:]

    public init(_ resources: [Resource]) {
        for r in resources { byKey["\(r.type)/\(r.id)"] = r }
    }

    public func resource(_ ident: ResourceIdentifier?) -> Resource? {
        guard let ident else { return nil }
        return byKey["\(ident.type)/\(ident.id)"]
    }
}
