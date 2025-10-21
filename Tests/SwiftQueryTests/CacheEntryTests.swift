import Foundation
import Testing
@testable import SwiftQuery

@Suite struct CacheEntryTests {
    @Test func expiry_and_freshness() async {
        let now = Date()
        let e = CacheEntry<Int>(
            data: nil, error: nil, inFlight: nil, metadata: .init(readAt: now, updatedAt: now)
        )
        #expect(await !e.isFresh(staleTime: 0, now: now))
        #expect(await e.isFresh(staleTime: 1, now: now))
        #expect(await e.isFresh(staleTime: 2, now: now))

        await e.metadata.updateUpdatedAt(now.addingTimeInterval(-1))
        #expect(await !e.isFresh(staleTime: 0, now: now))
        #expect(await !e.isFresh(staleTime: 1, now: now))
        #expect(await e.isFresh(staleTime: 2, now: now))
    }
}
