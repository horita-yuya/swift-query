import Foundation

public struct QueryOptions: Equatable, Hashable, Sendable {
    public var staleTime: TimeInterval
    public var gcTime: TimeInterval
    public var refetchOnAppear: Bool
    
    public init(staleTime: TimeInterval = 0, refetchOnAppear: Bool = true) {
        self.staleTime = staleTime
        // TODO: gc is not implemented
        self.gcTime = 300
        self.refetchOnAppear = refetchOnAppear
    }
}
