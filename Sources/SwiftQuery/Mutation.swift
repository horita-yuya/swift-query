import SwiftUI
import Foundation

public struct MutationBox: Sendable {
    public fileprivate(set) var isRunning: Bool = false
    public fileprivate(set) var error: Error?
}

@MainActor
public struct MutationController {
    @Binding private var box: MutationBox
    private let queryClient: QueryClient
    
    public var isLoading: Bool {
        box.isRunning
    }

    fileprivate init(box: Binding<MutationBox>, queryClient: QueryClient) {
        self._box = box
        self.queryClient = queryClient
    }

    @inline(__always)
    @discardableResult
    public func asyncPerform(
        _ mutationFn: @escaping @Sendable () async throws -> Void,
        onCompleted: (@Sendable (QueryClient) async -> Void)? = nil,
    ) async -> Result<Void, Error> {
        box.isRunning = true
        box.error = nil
        do {
            try await mutationFn()
            await onCompleted?(queryClient)
            box.isRunning = false
            return .success(())
        } catch {
            box.error = error
            box.isRunning = false
            return .failure(error)
        }
    }

    @inline(__always)
    @discardableResult
    public func asyncPerform<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T,
        onCompleted: (@Sendable (T, QueryClient) -> Void)? = nil,
    ) async -> Result<T, Error> {
        box.isRunning = true
        box.error = nil
        do {
            let value = try await operation()
            onCompleted?(value, queryClient)
            box.isRunning = false
            return .success(value)
        } catch {
            box.error = error
            box.isRunning = false
            return .failure(error)
        }
    }

    @inline(__always)
    public func reset() {
        box.isRunning = false
        box.error = nil
    }
}

@propertyWrapper
@MainActor
public struct UseMutation: DynamicProperty {
    @State private var box = MutationBox()
    private let client: QueryClient

    public init() {
        self.client = QueryClient.shared
    }

    public var wrappedValue: MutationController {
        MutationController(box: $box, queryClient: client)
    }

    public var projectedValue: Binding<MutationBox> { $box }
}
