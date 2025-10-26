import SwiftUI

@propertyWrapper
@MainActor
public struct UseMutation: DynamicProperty {
    @State private var box = MutationBox()
    private let client: QueryClient

    public init() {
        self.client = QueryClient.shared
    }

    public var wrappedValue: MutationClient {
        MutationClient(box: $box, queryClient: client)
    }

    public var projectedValue: Binding<MutationBox> { $box }
}
