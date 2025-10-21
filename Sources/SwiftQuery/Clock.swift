import Foundation

protocol Clock: Sendable {
    func now() -> Date
}

final class ClockImpl: Clock {
    @inline(__always)
    func now() -> Date {
        Date()
    }
}
