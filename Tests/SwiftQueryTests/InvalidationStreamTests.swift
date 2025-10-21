import Foundation
import Testing
@testable import SwiftQuery

@Suite struct InvalidationStreamTests {
    @Test func invalidation_yields_event() async {
        let client = QueryClient()
        let key: QueryKey = ["users"]

        let stream = await client.createInvalidationStream(for: key)
        var it = stream.makeAsyncIterator()

        await client.invalidate(key)
        #expect(await it.next() != nil)
    }
}
