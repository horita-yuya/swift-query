import SwiftUI
import Foundation
import os

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

struct CacheEntry<Value: Sendable>: Sendable {
    var data: Value?
    var error: Error?
    var readAt: Date
    var updatedAt: Date
    
    init(
        data: Value?,
        error: Error?,
        readAt: Date,
        updatedAt: Date
    ) {
        self.data = data
        self.error = error
        self.readAt = readAt
        self.updatedAt = updatedAt
    }
}

actor QueryClientStore: Sendable {
    private var watchers: [QueryKey: [UUID: AsyncStream<Void>.Continuation]] = [:]
    private var cache: [QueryKey: Any] = [:]
    
    func streams(queryKey: QueryKey) -> [UUID: AsyncStream<Void>.Continuation]? {
        watchers[queryKey]
    }
    
    fileprivate func storeStream(queryKey: QueryKey, id: UUID, continuation: AsyncStream<Void>.Continuation) {
        watchers[queryKey, default: [:]][id] = continuation
    }
    
    func removeStream(queryKey: QueryKey, id: UUID) {
        watchers[queryKey]?[id] = nil
    }
    
    func entry<Value>(queryKey: QueryKey, as type: Value.Type) -> CacheEntry<Value>? {
        cache[queryKey] as? CacheEntry<Value>
    }
    
    @discardableResult
    func withEntry<Value>(
        queryKey: QueryKey,
        as type: Value.Type,
        now: Date,
        handler: (inout CacheEntry<Value>) async -> (Bool, Result<Value, Error>)
    ) async -> (isFresh: Bool, result: Result<Value, Error>) {
        if var entry = cache[queryKey] as? CacheEntry<Value> {
            let result = await handler(&entry)
            cache[queryKey] = entry
            return result
        } else {
            var entry = CacheEntry<Value>(
                data: nil,
                error: nil,
                readAt: now,
                updatedAt: now
            )
            let result = await handler(&entry)
            cache[queryKey] = entry
            return result
        }
    }
    
    func removeEntry(queryKey: QueryKey) {
        cache.removeValue(forKey: queryKey)
    }
}

public final class QueryClient: Sendable {
    internal static let shared = QueryClient()
    internal let store = QueryClientStore()
    fileprivate let clock: Clock
    
    init(clock: Clock = ClockImpl()) {
        self.clock = clock
    }
    
    @inline(__always)
    public func invalidate(_ queryKey: QueryKey, fileId: StaticString = #fileID) async {
        SwiftQueryLogger.d(
            "Invalidating cache",
            metadata: [
                "queryKey": queryKey,
                "View": fileId
            ]
        )
        await store.removeEntry(queryKey: queryKey)
        
        if let streams = await store.streams(queryKey: queryKey) {
            for (_, continuation) in streams {
                continuation.yield(())
            }
        }
    }
    
    @inline(__always)
    func createSyncStream(queryKey: QueryKey) async -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        await store.storeStream(queryKey: queryKey, id: id, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.store.removeStream(queryKey: queryKey, id: id)
            }
        }
        return stream
    }
    
    @inline(__always)
    func fetch<Value: Sendable>(
        queryKey: QueryKey,
        options: QueryOptions,
        forceRefresh: Bool,
        fileId: StaticString,
        queryFn: @escaping @Sendable () async throws -> Value
    ) async -> (isFresh: Bool, result: Result<Value, Error>) {
        let clock = clock
        let now = clock.now()
        return await store.withEntry(queryKey: queryKey, as: Value.self, now: now) { entry in
            if !forceRefresh, let value = entry.data {
                let lastReadAt = entry.readAt
                entry.readAt = now
                SwiftQueryLogger.d(
                    "Hit from swiftquery",
                    metadata: [
                        "queryKey": queryKey,
                        "View": fileId
                    ]
                )
                
                let isFresh = now.timeIntervalSince(lastReadAt) < options.staleTime
                
                return (isFresh, .success(value))
                
            } else {
                SwiftQueryLogger.d(
                    "\(forceRefresh ? "Refresh" : "Miss") from swiftquery - fetching",
                    metadata: [
                        "queryKey": queryKey,
                        "View": fileId
                    ]
                )
                
                do {
                    let value = try await queryFn()
                    let now = clock.now()
                    entry.data = value
                    entry.error = nil
                    entry.readAt = now
                    entry.updatedAt = now
                    return (true, .success(value))
                } catch {
                    entry.data = nil
                    entry.error = error
                    entry.readAt = now
                    entry.updatedAt = now
                    return (true, .failure(error))
                }
            }
        }
    }
}

public struct QueryBox<Value: Sendable>: Sendable {
    var data: Value?
    var isLoading: Bool = false
    var error: Error?
}

@MainActor
@Observable
public final class QueryObserver<Value: Sendable>: Sendable {
    internal var box: QueryBox<Value>
    internal var queryKey: QueryKey? {
        didSet {
            if let queryKey {
                subscribe(queryKey: queryKey)
            }
        }
    }
    
    @ObservationIgnored
    internal var task: Task<Void, Never>?
    private let queryClient: QueryClient
    
    deinit {
        task?.cancel()
    }
    
    init(
        queryKey: QueryKey?,
        queryClient: QueryClient,
    ) {
        self.box = QueryBox<Value>()
        self.queryKey = queryKey
        self.queryClient = queryClient
        
        if let queryKey {
            subscribe(queryKey: queryKey)
        }
    }
    
    func subscribe(queryKey: QueryKey) {
        let queryClient = queryClient
        self.task?.cancel()
        self.task = Task { [weak self] in
            let now = queryClient.clock.now()
            await self?.syncStateWithCache(queryKey: queryKey, now: now)
            
            for await _ in await queryClient.createSyncStream(queryKey: queryKey) {
                await self?.syncStateWithCache(queryKey: queryKey, now: now)
            }
        }
    }
    
    func syncStateWithCache(queryKey: QueryKey, now: Date) async {
        if let cacheValue = await queryClient.store.entry(queryKey: queryKey, as: Value.self) {
            box.data = cacheValue.data
            box.error = nil
        }
    }
}

@MainActor
@propertyWrapper
public struct UseQuery<Value: Sendable>: DynamicProperty {
    @State private var observer: QueryObserver<Value>
    
    public var wrappedValue: Value? {
        observer.box.data
    }
    
    public var projectedValue: Binding<QueryObserver<Value>> {
        $observer
    }
    
    public init(_ queryKey: QueryKey? = nil) {
        self.observer = QueryObserver<Value>(
            queryKey: queryKey,
            queryClient: QueryClient.shared,
        )
    }
}

public extension View {
    func query<Value: Sendable>(
        _ observer: Binding<QueryObserver<Value>>,
        queryKey: QueryKey,
        options: QueryOptions = .init(),
        fileId: StaticString = #fileID,
        queryFn: @escaping @Sendable () async throws -> Value,
        onCompleted: ((Value) -> Void)? = nil
    ) -> some View {
        modifier(
            QueryModifier(
                observer: observer,
                queryKey: queryKey,
                options: options,
                fileId: fileId,
                queryClient: QueryClient.shared,
                batchExecutor: BatchExecutor.shared,
                queryFn: queryFn,
                onCompleted: onCompleted
            )
        )
    }
}

struct QueryModifier<Value: Sendable>: ViewModifier {
    @Binding var observer: QueryObserver<Value>
    
    private let queryKey: QueryKey
    private let options: QueryOptions
    private let fileId: StaticString
    private let queryClient: QueryClient
    private let batchExecutor: BatchExecutor
    private let queryFn: @Sendable () async throws -> Value
    private let onCompleted: ((Value) -> Void)?
    
    init(
        observer: Binding<QueryObserver<Value>>,
        queryKey: QueryKey,
        options: QueryOptions,
        fileId: StaticString,
        queryClient: QueryClient,
        batchExecutor: BatchExecutor,
        queryFn: @Sendable @escaping () async throws -> Value,
        onCompleted: ((Value) -> Void)?
    ) {
        self._observer = observer
        self.queryKey = queryKey
        self.options = options
        self.fileId = fileId
        self.queryClient = queryClient
        self.batchExecutor = batchExecutor
        self.queryFn = queryFn
        self.onCompleted = onCompleted
    }

    func body(content: Content) -> some View {
        content
            .task(id: queryKey) {
                if observer.queryKey != queryKey {
                    observer.queryKey = queryKey
                }
                await fetch(queryKey: queryKey, fileId: fileId)
            }
            .onAppear {
                if options.refetchOnAppear {
                    Task {
                        await fetch(queryKey: queryKey, fileId: fileId)
                    }
                }
            }
    }
    
    @inline(__always)
    func fetch(queryKey: QueryKey, fileId: StaticString) async {
        await batchExecutor.batchExecution(queryKey: queryKey) {
            SwiftQueryLogger.d(
                "Batch executing fetch",
                metadata: [
                    "queryKey": queryKey,
                    "View": fileId,
                ]
            )
            
            let (isFresh, result) = await queryClient.fetch(
                queryKey: queryKey,
                options: options,
                forceRefresh: false,
                fileId: fileId,
                queryFn: queryFn
            )
            
            let streams = await queryClient.store.streams(queryKey: queryKey)?.values.map { $0 } ?? []
            switch result {
            case .success(let value):
                await MainActor.run {
                    observer.box.data = value
                    observer.box.error = nil
                    observer.box.isLoading = false

                    if isFresh {
                        onCompleted?(value)
                    }
                }
                for continuation in streams {
                    continuation.yield(())
                }
                
            case .failure(let error):
                await MainActor.run {
                    observer.box.error = error
                    observer.box.isLoading = false
                }
            }
            
            if !isFresh {
                let (_, result) = await queryClient.fetch(
                    queryKey: queryKey,
                    options: options,
                    forceRefresh: true,
                    fileId: fileId,
                    queryFn: queryFn
                )
                
                switch result {
                case .success(let value):
                    await MainActor.run {
                        observer.box.data = value
                        observer.box.error = nil
                        
                        // onCompleted can be called twice, but this feature can be changed in future.
                        onCompleted?(value)
                    }
                    for continuation in streams {
                        continuation.yield(())
                    }
                case .failure:
                    // Second try is for updating cache for new data.
                    // It is convenient to not override existing data with error.
                    break
                }
            }
        }
    }
}

    
public struct Boundary<Content: View, Value: Sendable>: View {
    @Binding private var observer: QueryObserver<Value>
    private let content: (Value) -> Content
    private let fallback: (() -> AnyView)?
    private let errorFallback: ((Error) -> AnyView)?

    @_disfavoredOverload
    public init(
        _ observer: Binding<QueryObserver<Value>>,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self._observer = observer
        self.content = content
        self.fallback = nil
        self.errorFallback = nil
    }

    @_disfavoredOverload
    public init(
        _ observer: Binding<QueryObserver<Value>>,
        @ViewBuilder content: @escaping (Value) -> Content,
        @ViewBuilder fallback: @escaping () -> some View
    ) {
        self._observer = observer
        self.content = content
        self.fallback = { AnyView(fallback()) }
        self.errorFallback = nil
    }

    @_disfavoredOverload
    public init(
        _ observer: Binding<QueryObserver<Value>>,
        @ViewBuilder content: @escaping (Value) -> Content,
        @ViewBuilder fallback: @escaping () -> some View,
        @ViewBuilder errorFallback: @escaping (Error) -> some View
    ) {
        self._observer = observer
        self.content = content
        self.fallback = { AnyView(fallback()) }
        self.errorFallback = { error in AnyView(errorFallback(error)) }
    }
    
    public var body: some View {
        if let value = observer.box.data {
            content(value)
        } else if let error = observer.box.error, let errorFallback = errorFallback {
            errorFallback(error)
        } else if let fallback = fallback {
            fallback()
        } else {
            // This is required because onAppear or task is not called in EmptyView
            ProgressView()
        }
    }
}

actor BatchExecutor {
    static let shared = BatchExecutor()
    private var queues: [QueryKey: [Task<Void, Never>]] = [:]

    @inline(__always)
    func batchExecution(queryKey: QueryKey, debounce: TimeInterval = 0.1, perform: @escaping @Sendable () async -> Void) async -> Void {
        var queue = queues[queryKey, default: []]
        let firstTask = queue.first

        let task = Task<Void, Never> {
            do {
                try await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
                
                if let firstTask {
                    _ = await firstTask.result
                } else {
                    await perform()
                }
            } catch {}
        }

        queue.append(task)
        queues[queryKey, default: []] = queue
        await task.value
        
        queues[queryKey] = []
    }
}
