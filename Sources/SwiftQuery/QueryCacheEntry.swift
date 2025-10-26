import Foundation

struct QueryCacheEntry<Value: Sendable>: Sendable {
    var data: Value?
    var error: Error?
    var updatedAt: Date
    
    init(
        data: Value?,
        error: Error?,
        updatedAt: Date
    ) {
        self.data = data
        self.error = error
        self.updatedAt = updatedAt
    }
}
