public struct QueryKey: Equatable, Hashable, Sendable, ExpressibleByArrayLiteral, ExpressibleByStringLiteral, CustomStringConvertible {
    public var parts: [String]
    public init(_ parts: [String]) {
        self.parts = parts
    }
    
    public init(arrayLiteral elements: CustomStringConvertible...) {
        self.parts = elements.map { "\($0)" }
    }
    
    public init(stringLiteral value: StringLiteralType) {
        self.parts = [value]
    }
    
    public var description: String {
        parts.joined(separator: "/")
    }
}
