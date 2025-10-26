import Foundation
import Testing
@testable import SwiftQuery

private extension QueryModifier {
    init(
        queryKey: QueryKey,
        queryClient: QueryClient,
        options: QueryOptions,
        batchExecutor: QueryBatchExecutor,
        queryFn: @Sendable @escaping () async throws -> Value,
    ) {
        let observer: QueryObserver<Value> = QueryObserver(queryKey: queryKey, queryClient: queryClient)
        
        self.init(
            observer: .init(get: { observer }, set: { _ in }),
            queryKey: queryKey,
            options: options,
            fileId: "",
            queryClient: queryClient,
            batchExecutor: batchExecutor,
            queryFn: queryFn,
            onCompleted: nil
        )
    }
}

@Suite struct QueryModifierTests {
    actor Counter {
        private(set) var value = 0
        func inc() { value += 1 }
    }
    
    @Test func array_literal_accepts_any_and_joins_by_slash() async throws {
        let clock = TestClock()
        let queryKey: QueryKey = ["a"]
        let client = QueryClient(clock: clock)
        let executor = QueryBatchExecutor()
        
        let mod = await QueryModifier(
            queryKey: queryKey,
            queryClient: client,
            options: .init(),
            batchExecutor: executor,
            queryFn: { 1 },
        )
        
        #expect(await mod.observer.box.data == nil)
        await mod.fetch(queryKey: queryKey, fileId: "")
        try await Task.sleep(for: .milliseconds(1))
        #expect(await mod.observer.box.data == 1)
    }
    
    @Test func refetch_when_cache_is_stale() async throws {
        let clock = TestClock()
        let queryKey: QueryKey = ["a"]
        let client = QueryClient(clock: clock)
        let executor = QueryBatchExecutor()
        let counter = Counter()
        
        let mod = await QueryModifier(
            queryKey: queryKey,
            queryClient: client,
            options: .init(staleTime: 1),
            batchExecutor: executor,
            queryFn: {
                await counter.inc()
                return await counter.value
            },
        )
        
        let now = clock.now()
        #expect(await mod.observer.box.data == nil)
        
        // Miss cache
        await mod.fetch(queryKey: queryKey, fileId: "")
        try await Task.sleep(for: .milliseconds(1))
        #expect(await mod.observer.box.data == 1)
        
        // Hit cache - within stale time
        await mod.fetch(queryKey: queryKey, fileId: "")
        try await Task.sleep(for: .milliseconds(1))
        #expect(await mod.observer.box.data == 1)
        
        // Hit cache but stale, refresh
        clock.set(now: now.addingTimeInterval(1))
        await mod.fetch(queryKey: queryKey, fileId: "")
        try await Task.sleep(for: .milliseconds(1))
        #expect(await mod.observer.box.data == 2)
    }
    
    @Test func state_has_refreshed_value_after_invalidation() async throws {
        // TODO: Impl
    }
}
