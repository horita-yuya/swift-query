import SwiftUI

@MainActor
@propertyWrapper
public struct UseQueryClient {
    @State private var client: QueryClient = QueryClient.shared
    
    public init() {}
    
    public var wrappedValue: QueryClient {
        client
    }
    
    public var projectedValue: Never {
        fatalError("UseQueryClient does not have a projected value.")
    }
}
