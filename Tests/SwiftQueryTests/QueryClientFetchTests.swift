import Foundation
import Testing
@testable import SwiftQuery

@Suite struct QueryClientFetchTests {
    actor Counter {
        private(set) var value = 0
        func inc() { value += 1 }
    }
    
    @Test func stale_time_0_expiration() async throws {
        let clock = TestClock()
        let client = QueryClient(clock: clock)
        let queryKey: QueryKey = ["user", 1]
        let options = QueryOptions(staleTime: 0, gcTime: 300, refetchOnAppear: true)

        let (f1, r1) = await client.fetch(queryKey: queryKey, options: options, forceRefresh: false, fileId: "") {
            return "Alice"
        }
        
        #expect(try r1.get() == "Alice")
        // Miss cache
        #expect(f1 == true)
        
        let (f2, r2) = await client.fetch(queryKey: queryKey, options: options, forceRefresh: false, fileId: "") {
            return "Alice"
        }
        
        #expect(try r2.get() == "Alice")
        // Hit cache & staleTime is 0
        #expect(f2 == false)
    }
    
    @Test func stale_time_elapsed_expiration() async throws {
        let now = Date()
        let clock = TestClock()
        clock.set(now: now)
        
        let client = QueryClient(clock: clock)
        let queryKey: QueryKey = ["user", 1]
        let options = QueryOptions(staleTime: 1, gcTime: 300, refetchOnAppear: true)

        let (f1, r1) = await client.fetch(queryKey: queryKey, options: options, forceRefresh: false, fileId: "") {
            return "Alice"
        }
        
        #expect(try r1.get() == "Alice")
        // Miss cache
        #expect(f1 == true)
        
        let (f2, r2) = await client.fetch(queryKey: queryKey, options: options, forceRefresh: false, fileId: "") {
            return "Alice"
        }
        
        #expect(try r2.get() == "Alice")
        // Hit cache & staleTime is 1
        #expect(f2 == true)
        
        clock.set(now: now.addingTimeInterval(1))
        
        let (f3, r3) = await client.fetch(queryKey: queryKey, options: options, forceRefresh: false, fileId: "") {
            return "Alice"
        }
        
        #expect(try r3.get() == "Alice")
        // Miss cache & staleTime is 1
        #expect(f3 == false)
    }

    @Test func first_fetch_stores_cache_and_second_fetch_hits_fresh_cache() async throws {
        let client = QueryClient()
        let calls = Counter()

        let queryKey: QueryKey = ["user", 1]
        let options = QueryOptions(staleTime: 60, gcTime: 300, refetchOnAppear: true)

        let (f1, r1) = await client.fetch(queryKey: queryKey, options: options, forceRefresh: false, fileId: "") {
            await calls.inc()
            return "Alice"
        }
        #expect(try r1.get() == "Alice")
        #expect(f1 == true)

        let (f2, r2) = await client.fetch(queryKey: queryKey, options: options, forceRefresh: false, fileId: "") {
            await calls.inc()
            return "Bob"
        }
        // This behavior is expected because staleTime has not expired, so the cached value "Alice" is returned.
        // This means remote fetch is not called because cache is still fresh.
        #expect(try r2.get() == "Alice")
        #expect(f2 == true)

        #expect(await calls.value == 1)

        let cached: String? = await client.store.entry(queryKey: queryKey, as: String.self)?.data
        #expect(cached == "Alice")
    }

    @Test func fetch_failure_propagates_and_stores_error() async {
        struct E: Error, Equatable {}
        let client = QueryClient()
        let queryKey: QueryKey = ["fail", "case"]
        
        @Sendable func fetch() async throws -> Int {
            throw E()
        }

        let (_, result) = await client.fetch(queryKey: queryKey, options: .init(), forceRefresh: false, fileId: "") {
            try await fetch()
        }
        
        do {
            _ = try result.get()
            Issue.record("should have thrown")
        } catch {
            #expect(error is E)
        }
        
        let cachedError = await client.store.entry(queryKey: queryKey, as: Int.self)?.error
        #expect(cachedError is E)
    }
}
