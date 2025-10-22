import SwiftUI
import Foundation
import os

public struct QueryKey: Equatable, Hashable, Sendable, ExpressibleByArrayLiteral, ExpressibleByStringLiteral, CustomStringConvertible {
    public var parts: [String]
    public init(_ parts: [String]) {
        self.parts = parts
    }
    
    public init(arrayLiteral elements: Any...) {
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

final actor CacheMetadata: Sendable {
    var readAt: Date
    var updatedAt: Date
    
    init(
        readAt: Date,
        updatedAt: Date
    ) {
        self.readAt = readAt
        self.updatedAt = updatedAt
    }
    
    func updateReadAt(_ date: Date) {
        self.readAt = date
    }
    
    func updateUpdatedAt(_ date: Date) {
        self.updatedAt = date
    }
}

struct CacheEntry<Value: Sendable>: Sendable {
    var data: Value?
    var error: Error?
    var inFlight: Task<Value, Error>?
    let metadata: CacheMetadata
    
    init(data: Value?, error: Error?, inFlight: Task<Value, Error>?, metadata: CacheMetadata) {
        self.data = data
        self.error = error
        self.inFlight = inFlight
        self.metadata = metadata
    }
    
    // if staleTime is 0, it is marked as stale immediately
    func isFresh(staleTime: TimeInterval, now: Date) async -> Bool {
        let updatedAt = await metadata.updatedAt
        return now.timeIntervalSince(updatedAt) < staleTime
    }
    
    func value(now: Date) async -> Value? {
        if let data {
            await metadata.updateReadAt(now)
            return data
        } else {
            return nil
        }
    }
}

actor QueryClientStore: Sendable {
    private var watchers: [QueryKey: [UUID: AsyncStream<Void>.Continuation]] = [:]
    private let cache = OSAllocatedUnfairLock<[QueryKey: any Sendable]>(initialState: [:])
    
    func streams(forKey key: QueryKey) -> [UUID: AsyncStream<Void>.Continuation]? {
        watchers[key]
    }
    
    func storeStream(forKey key: QueryKey, id: UUID, continuation: AsyncStream<Void>.Continuation) {
        watchers[key, default: [:]][id] = continuation
    }
    
    func removeStream(forKey key: QueryKey, id: UUID) {
        watchers[key]?[id] = nil
    }
    
    nonisolated func entry<Value>(forKey key: QueryKey, as type: Value.Type) -> CacheEntry<Value>? {
        cache.withLock {
            $0[key] as? CacheEntry<Value>
        }
    }
    
    nonisolated func storeEntry<Value>(forKey key: QueryKey, entry: CacheEntry<Value>) {
        cache.withLock { $0[key] = entry }
    }
    
    nonisolated func removeEntry(forKey key: QueryKey) {
        _ = cache.withLock { $0.removeValue(forKey: key) }
    }
}

public final class QueryClient: Sendable {
    internal static let shared = QueryClient()
    fileprivate let store = QueryClientStore()
    fileprivate let clock: Clock
    
    init(clock: Clock = ClockImpl()) {
        self.clock = clock
    }
    
    @inline(__always)
    public func invalidate(_ key: QueryKey, fileId: StaticString = #fileID) async {
        SwiftQueryLogger.d(
            "Invalidating cache",
            metadata: [
                "key": key,
                "View": fileId
            ]
        )
        store.removeEntry(forKey: key)
        
        if let streams = await store.streams(forKey: key) {
            for (_, continuation) in streams {
                continuation.yield(())
            }
        }
    }
    
    @inline(__always)
    func createInvalidationStream(for key: QueryKey) async -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        await store.storeStream(forKey: key, id: id, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task.detached {
                await self?.store.removeStream(forKey: key, id: id)
            }
        }
        return stream
    }
    
    @inline(__always)
    func value<Value: Sendable>(_ key: QueryKey, as type: Value.Type = Value.self) -> Value? {
        let entry = store.entry(forKey: key, as: Value.self)
        return entry?.data
    }
    
    @inline(__always)
    func fetch<Value: Sendable>(
        key: QueryKey,
        options: QueryOptions = .init(),
        now: Date,
        forceRefresh: Bool,
        fileId: StaticString,
        fetcher: @escaping @Sendable () async throws -> Value
    ) async -> (isFresh: Bool, result: Result<Value, Error>) {
        if !forceRefresh, let entry = store.entry(forKey: key, as: Value.self) {
            if let value = await entry.value(now: now) {
                let isFreshed = await entry.isFresh(staleTime: options.staleTime, now: now)
                
                SwiftQueryLogger.d(
                    "Cache hit",
                    metadata: [
                        "key": key,
                        "isFreshed": "\(isFreshed)",
                        "View": fileId
                    ]
                )
                return (isFreshed, .success(value))
            } else if let inFlight = entry.inFlight {
                SwiftQueryLogger.d(
                    "Use inFlight request",
                    metadata: [
                        "key": key,
                        "View": fileId
                    ]
                )
                
                // Treat entry is fresh if data is still in flight
                do {
                    let value = try await inFlight.value
                    await entry.metadata.updateReadAt(clock.now())
                    return (true, .success(value))
                } catch {
                    // We treat entry as fresh even if inFlight fails
                    // Because if this error is not transient, refetching won't help
                    // We can use exponential backoff or other strategies if needed, but this is simpler.
                    return (true, .failure(error))
                }
            }
        }
        
        SwiftQueryLogger.d(
            forceRefresh ? "Force refresh, Ignore cache - fetching" : "Cache miss – fetching",
            metadata: [
                "key": key,
                "forceRefresh": "\(forceRefresh)",
                "View": fileId
            ]
        )
        
        let task = Task<Value, Error> { try await fetcher() }
        // This is not perfectly atomic, but good enough except for strict correctness
        // Storing inFlight task is good for preventing duplicate fetches from unexpected concurrent requests
        // For example,
        // - Fetching user data but throughput of server is low, causing multiple views to request user data simultaneously.
        store.storeEntry(forKey: key, entry: CacheEntry<Value>(
            data: nil,
            error: nil,
            inFlight: task,
            metadata: CacheMetadata(
                readAt: now,
                updatedAt: now
            )
        ))
        
        do {
            let value = try await task.value
            store.storeEntry(forKey: key, entry: CacheEntry<Value>(
                data: value,
                error: nil,
                inFlight: nil,
                metadata: CacheMetadata(
                    readAt: now,
                    updatedAt: now
                )
            ))
            return (true, .success(value))
        } catch {
            store.storeEntry(forKey: key, entry: CacheEntry<Value>(
                data: nil,
                error: error,
                inFlight: nil,
                metadata: CacheMetadata(
                    readAt: now,
                    updatedAt: now
                )
            ))
            return (true, .failure(error))
        }
    }
}

public struct QueryBox<Value: Sendable> {
    var data: Value?
    var isLoading: Bool = false
    var error: Error?
}

@propertyWrapper
public struct UseQuery<Value: Sendable>: DynamicProperty {
    @State private var box: QueryBox<Value>
    
    public var wrappedValue: Value? {
        box.data
    }
    
    public var projectedValue: Binding<QueryBox<Value>> {
        $box
    }
    
    // queryKey of UseQuery is used only for initial value.
    // queryKey can be nil and can be different from query modifier's one.
    // query modifier's one has higher priority.
    // If UseQuery whose query is different from modifier's one and pass it to modifier's Binding, it will be updated.
    // Even if the queryKey is different.
    public init(_ queryKey: QueryKey? = nil) {
        if let queryKey, let value = QueryClient.shared.value(queryKey, as: Value.self) {
            self.box = QueryBox<Value>(
                data: value,
                isLoading: false,
                error: nil
            )
        } else {
            self.box = QueryBox<Value>()
        }
    }
}

public extension View {
    func query<Value: Sendable>(
        _ box: Binding<QueryBox<Value>>,
        queryKey: QueryKey,
        options: QueryOptions = .init(),
        fileId: StaticString = #fileID,
        queryFn: @escaping @Sendable () async throws -> Value,
        onCompleted: ((Value) -> Void)? = nil
    ) -> some View {
        modifier(
            QueryModifier(
                box: box,
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
    @Binding var box: QueryBox<Value>
    
    let queryKey: QueryKey
    let options: QueryOptions
    let fileId: StaticString
    let queryClient: QueryClient
    let batchExecutor: BatchExecutor
    let queryFn: @Sendable () async throws -> Value
    let onCompleted: ((Value) -> Void)?

    func body(content: Content) -> some View {
        content
            .task(id: queryKey) {
                await subscribe(queryKey: queryKey)
            }
            .onAppear {
                if options.refetchOnAppear {
                    let now = queryClient.clock.now()
                    Task {
                        await run(queryKey: queryKey, showLoading: true, now: now, fileId: fileId, streams: [])
                    }
                }
            }
    }
    
    @inline(__always)
    func subscribe(queryKey: QueryKey) async {
        let now = queryClient.clock.now()
        let streams = await queryClient.store.streams(forKey: queryKey)?.values.map { $0 } ?? []
        await run(queryKey: queryKey, showLoading: true, now: now, fileId: fileId, streams: streams)
        let stream = await queryClient.createInvalidationStream(for: queryKey)
        for await _ in stream {
            await run(queryKey: queryKey, showLoading: false, now: now, fileId: fileId, streams: streams)
            if let value = queryClient.value(queryKey, as: Value.self) {
                box.data = value
                box.error = nil
                box.isLoading = false
            }
        }
    }
    
    @inline(__always)
    func run(queryKey: QueryKey, showLoading: Bool, now: Date, fileId: StaticString, streams: [AsyncStream<Void>.Continuation]) async {
        await batchExecutor.batchExecution(queryKey: queryKey) {
            SwiftQueryLogger.d(
                "Fetching cache/remote",
                metadata: [
                    "key": queryKey,
                    "View": fileId,
                ]
            )
            
            if showLoading {
                await MainActor.run {
                    box.isLoading = true
                }
            }
            let (isFresh, result) = await queryClient.fetch(
                key: queryKey,
                options: options,
                now: now,
                forceRefresh: false,
                fileId: fileId,
                fetcher: queryFn
            )
            
            for continuation in streams {
                continuation.yield(())
            }
            
            await MainActor.run {
                switch result {
                case .success(let value):
                    box.data = value
                    box.error = nil
                    onCompleted?(value)
                case .failure(let error):
                    box.error = error
                }
                box.isLoading = false
            }
            
            if !isFresh {
                let (_, result) = await queryClient.fetch(
                    key: queryKey,
                    options: options,
                    now: now,
                    forceRefresh: true,
                    fileId: fileId,
                    fetcher: queryFn
                )
                
                await MainActor.run {
                    switch result {
                    case .success(let value):
                        box.data = value
                        box.error = nil
                        
                        // onCompleted can be called twice, but this feature can be changed in future.
                        onCompleted?(value)
                    case .failure:
                        // Second try is for updating cache for new data.
                        // It is convenient to not override existing data with error.
                        break
                    }
                }
            }
        }
        
        for continuation in streams {
            continuation.yield(())
        }
    }
}

    
public struct Boundary<Content: View, Value: Sendable>: View {
    @Binding private var box: QueryBox<Value>
    private let content: (Value) -> Content
    private let fallback: (() -> AnyView)?
    private let errorFallback: ((Error) -> AnyView)?

    @_disfavoredOverload
    public init(
        _ box: Binding<QueryBox<Value>>,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self._box = box
        self.content = content
        self.fallback = nil
        self.errorFallback = nil
    }

    @_disfavoredOverload
    public init(
        _ box: Binding<QueryBox<Value>>,
        @ViewBuilder content: @escaping (Value) -> Content,
        @ViewBuilder fallback: @escaping () -> some View
    ) {
        self._box = box
        self.content = content
        self.fallback = { AnyView(fallback()) }
        self.errorFallback = nil
    }

    @_disfavoredOverload
    public init(
        _ box: Binding<QueryBox<Value>>,
        @ViewBuilder content: @escaping (Value) -> Content,
        @ViewBuilder fallback: @escaping () -> some View,
        @ViewBuilder errorFallback: @escaping (Error) -> some View
    ) {
        self._box = box
        self.content = content
        self.fallback = { AnyView(fallback()) }
        self.errorFallback = { error in AnyView(errorFallback(error)) }
    }
    
    public var body: some View {
        if let value = box.data {
            content(value)
        } else if let error = box.error, let errorFallback = errorFallback {
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
