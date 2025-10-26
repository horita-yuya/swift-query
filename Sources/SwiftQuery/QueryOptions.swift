import Foundation

public struct QueryOptions: Equatable, Hashable, Sendable {
    public var staleTime: TimeInterval
    // TODO: gc is not implemented
    public var gcTime: TimeInterval
    public var refetchOnAppear: Bool
    
    public init(staleTime: TimeInterval = 0, gcTime: TimeInterval = 300, refetchOnAppear: Bool = true) {
        self.staleTime = staleTime
        self.gcTime = gcTime
        self.refetchOnAppear = refetchOnAppear
    }
}
