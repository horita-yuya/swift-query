import Foundation
import Testing
@testable import SwiftQuery

@Suite struct InvalidationStreamTests {
    @Test func invalidation_yields_event() async {
        let client = QueryClient()
        let queryKey: QueryKey = ["users"]

        let stream = await client.createInvalidationStream(queryKey: queryKey)
        var it = stream.makeAsyncIterator()

        await client.invalidate(queryKey)
        #expect(await it.next() != nil)
    }
}
