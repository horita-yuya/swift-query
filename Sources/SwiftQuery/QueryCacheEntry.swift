import Foundation

struct QueryCacheEntry<Value: Sendable>: Sendable {
    var data: Value?
    var error: Error?
    var readAt: Date
    var updatedAt: Date
    
    init(
        data: Value?,
        error: Error?,
        readAt: Date,
        updatedAt: Date
    ) {
        self.data = data
        self.error = error
        self.readAt = readAt
        self.updatedAt = updatedAt
    }
}
