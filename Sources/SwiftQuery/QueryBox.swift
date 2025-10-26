public struct QueryBox<Value: Sendable>: Sendable {
    var data: Value?
    var isLoading: Bool = false
    var error: Error?
}
