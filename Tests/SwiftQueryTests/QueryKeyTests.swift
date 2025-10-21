import Foundation
import Testing
@testable import SwiftQuery

@Suite struct QueryKeyTests {
    @Test func array_literal_accepts_any_and_joins_by_slash() {
        let key: QueryKey = ["users", 123, UUID(uuidString: "00000000-0000-0000-0000-000000000000")!]
        #expect(key.parts == ["users", "123", "00000000-0000-0000-0000-000000000000"])
        #expect(key.description == "users/123/00000000-0000-0000-0000-000000000000")
    }

    @Test func string_literal_single_part() {
        let key: QueryKey = "users"
        #expect(key.parts == ["users"])
        #expect(key.description == "users")
    }
}
