import os

enum SwiftQueryLogger {
    private static let logger = Logger(subsystem: "com.horitayuya.swift-query", category: "swift-query")
    
    @inline(__always)
    static func d(_ message: String,
                  metadata: [String: CustomStringConvertible] = [:]) {
#if DEBUG
        var log = "\(message)"
        for (k, v) in metadata.sorted(by: { $0.key < $1.key }) {
            log.append(" [\(k): \(v)]")
        }
        logger.debug("\(log, privacy: .public)")
#endif
    }
}
