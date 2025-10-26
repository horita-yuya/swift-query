import Foundation

actor QueryBatchExecutor {
    static let shared = QueryBatchExecutor()
    private var queues: [QueryKey: [Task<Void, Never>]] = [:]

    @inline(__always)
    func batchExecution(queryKey: QueryKey, debounce: TimeInterval = 0.1, perform: @escaping @Sendable () async -> Void) async -> Void {
        var queue = queues[queryKey, default: []]
        let firstTask = queue.first

        let task = Task<Void, Never> {
            do {
                try await Task.sleep(nanoseconds: UInt64(debounce * 1_000_000_000))
                
                if let firstTask {
                    _ = await firstTask.result
                } else {
                    await perform()
                }
            } catch {}
        }

        queue.append(task)
        queues[queryKey, default: []] = queue
        await task.value
        
        queues[queryKey] = []
    }
}

