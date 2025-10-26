import Foundation

actor QueryClientStore: Sendable {
    private var watchers: [QueryKey: [UUID: AsyncStream<Void>.Continuation]] = [:]
    private var cache: [QueryKey: Any] = [:]
    
    func syncCacheStreams(queryKey: QueryKey) -> [UUID: AsyncStream<Void>.Continuation]? {
        watchers[queryKey]
    }
    
    func storeSyncCacheStream(queryKey: QueryKey, id: UUID, continuation: AsyncStream<Void>.Continuation) {
        watchers[queryKey, default: [:]][id] = continuation
    }
    
    func removeSyncCacheStream(queryKey: QueryKey, id: UUID) {
        watchers[queryKey]?[id] = nil
    }
    
    func entry<Value>(queryKey: QueryKey, as type: Value.Type) -> QueryCacheEntry<Value>? {
        cache[queryKey] as? QueryCacheEntry<Value>
    }
    
    @discardableResult
    func withEntry<Value>(
        queryKey: QueryKey,
        as type: Value.Type,
        now: Date,
        handler: (inout QueryCacheEntry<Value>, Bool) async -> (Bool, Result<Value, Error>)
    ) async -> (isFresh: Bool, result: Result<Value, Error>) {
        if var entry = cache[queryKey] as? QueryCacheEntry<Value> {
            let result = await handler(&entry, false)
            cache[queryKey] = entry
            return result
        } else {
            var entry = QueryCacheEntry<Value>(
                data: nil,
                error: nil,
                readAt: now,
                updatedAt: now
            )
            
            // Be careful to Actor reentrancy
            let result = await handler(&entry, true)
            cache[queryKey] = entry
            return result
        }
    }
    
    func removeEntry(queryKey: QueryKey) {
        cache.removeValue(forKey: queryKey)
    }
}
