import Foundation
import Testing
@testable import SwiftQuery

@Suite struct QueryClientFetchTests {
    actor Counter {
        private(set) var value = 0
        func inc() { value += 1 }
    }

    @Test func first_fetch_stores_cache_and_second_fetch_hits_fresh_cache() async {
        let client = QueryClient()
        let calls = Counter()

        let key: QueryKey = ["user", 1]
        let options = QueryOptions(staleTime: 60, gcTime: 300, refetchOnAppear: true)

        let (_, r1) = await client.fetch(key: key, options: options, now: Date(), forceRefresh: false, fileId: "") {
            await calls.inc()
            return "Alice"
        }
        #expect(try! r1.get() == "Alice")

        let (_, r2) = await client.fetch(key: key, options: options, now: Date(), forceRefresh: false, fileId: "") {
            await calls.inc()
            return "Bob"
        }
        #expect(try! r2.get() == "Alice")

        #expect(await calls.value == 1)

        let cached: String? = client.value(key)
        #expect(cached == "Alice")
    }

    @Test func fetch_failure_propagates_and_stores_error() async {
        struct E: Error, Equatable {}
        let client = QueryClient()
        let key: QueryKey = ["fail", "case"]

        let (_, result) = await client.fetch(key: key, now: Date(), forceRefresh: false, fileId: "") { throw E() }
        do {
            _ = try result.get()
            Issue.record("should have thrown")
        } catch {
            #expect(error is E)
        }
    }
}
