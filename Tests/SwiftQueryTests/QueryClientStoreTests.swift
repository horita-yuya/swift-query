import Foundation
import Testing
import SwiftUI
@testable import SwiftQuery

@Suite struct QueryClientStoreTests {
    @Test func updated_entry_is_cached() async {
        let testClock = TestClock()
        let queryKey = UUID().uuidString
        
        let store = QueryClientStore()
        #expect(await store.entry(queryKey: [queryKey], as: Int.self) == nil)
        
        await store.withEntry(queryKey: [queryKey], as: Int.self, now: testClock.now()) { entry, _ in
            entry.data = 123
            return (false, .success(123))
        }
        
        #expect(await store.entry(queryKey: [queryKey], as: Int.self)?.data == 123)
    }
}

