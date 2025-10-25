@testable import SwiftQuery
import Foundation
import os

final class TestClock: Clock {
    private let internalNow = OSAllocatedUnfairLock<Date>(initialState: .init())
    
    init() {}
    
    func now() -> Date {
        internalNow.withLock { $0 }
    }
    
    func set(now: Date) {
        internalNow.withLock { $0 = now }
    }
}
