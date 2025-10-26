public struct MutationBox: Sendable {
    public internal(set) var isRunning: Bool = false
    public internal(set) var error: Error?
}

