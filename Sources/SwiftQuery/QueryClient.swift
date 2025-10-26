import SwiftUI
import Foundation
import os

public final class QueryClient: Sendable {
    internal static let shared = QueryClient()
    internal let store = QueryClientStore()
    private let inFlightTasks: OSAllocatedUnfairLock<[QueryKey: Task<any Sendable, Error>]> = .init(initialState: [:])
    internal let clock: Clock
    
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
        await store.markEntryAsStale(queryKey: queryKey)
        
        if let streams = await store.syncCacheStreams(queryKey: queryKey) {
            for (_, continuation) in streams {
                continuation.yield(())
            }
        }
    }
    
    @inline(__always)
    func createSyncStream(queryKey: QueryKey) async -> AsyncStream<Void> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        await store.storeSyncCacheStream(queryKey: queryKey, id: id, continuation: continuation)
        continuation.onTermination = { [weak self] _ in
            Task {
                await self?.store.removeSyncCacheStream(queryKey: queryKey, id: id)
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
        return await store.withEntry(queryKey: queryKey, as: Value.self, now: now) { entry, isNew in
            if !forceRefresh, let value = entry.data {
                SwiftQueryLogger.d(
                    "Hit from swiftquery",
                    metadata: [
                        "queryKey": queryKey,
                        "View": fileId
                    ]
                )
                
                let isFresh = now.timeIntervalSince(entry.updatedAt) < options.staleTime
                
                return (isFresh, .success(value))
                
            } else {
                do {
                    let inFlightTask = inFlightTasks.withLock {
                        let task = $0[queryKey]
                        
                        if let task {
                            SwiftQueryLogger.d(
                                "InFlight from swiftquery - waiting for already running fetch",
                                metadata: [
                                    "queryKey": queryKey,
                                    "View": fileId
                                ]
                            )
                            
                            return task
                        } else {
                            SwiftQueryLogger.d(
                                "\(forceRefresh ? "Refresh" : "Miss") from swiftquery - fetching",
                                metadata: [
                                    "queryKey": queryKey,
                                    "View": fileId
                                ]
                            )
                            
                            let newTask = Task<any Sendable, Error> {
                                try await queryFn()
                            }
                            $0[queryKey] = newTask
                            return newTask
                        }
                    }
                    
                    let value = if let value = try await inFlightTask.value as? Value {
                        value
                    } else {
                        throw QueryError.inFlightCastError
                    }
                    
                    inFlightTasks.withLock {
                        $0[queryKey] = nil
                    }
                    
                    let now = clock.now()
                    entry.data = value
                    entry.error = nil
                    entry.updatedAt = now
                    return (true, .success(value))
                    
                } catch {
                    inFlightTasks.withLock {
                        $0[queryKey] = nil
                    }
                    
                    entry.data = nil
                    entry.error = error
                    entry.updatedAt = now
                    return (true, .failure(error))
                }
            }
        }
    }
}
