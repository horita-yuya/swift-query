import Foundation
import Testing
import SwiftUI
@testable import SwiftQuery

@Suite struct QueryObserverTests {
    @Test func when_observer_deinit_task_is_cancelled() async {
        let testClock = TestClock()
        let client = QueryClient(clock: testClock)
        
        var observer: QueryObserver<Int>? = await QueryObserver(
            queryKey: ["1"],
            queryClient: client
        )
        let task = Task {
            try? await Task.sleep(for: .seconds(3))
            return
        }
        await MainActor.run { observer?.task = task }
        #expect(!task.isCancelled)
        await MainActor.run { observer = nil }
        #expect(task.isCancelled)
    }

    @Test func value_is_updated_by_sync_stream() async throws {
        let testClock = TestClock()
        let client = QueryClient(clock: testClock)
        let queryKey = UUID().uuidString
        
        let observer: QueryObserver<Int> = await QueryObserver(
            queryKey: [queryKey],
            queryClient: client
        )
        try await Task.sleep(for: .milliseconds(1))
        let stream = await client.store.syncCacheStreams(queryKey: [queryKey])
        
        await MainActor.run {
            observer.box.data = 1
        }
        #expect(await observer.box.data == 1)
        
        await client.store.withEntry(queryKey: [queryKey], as: Int.self, now: testClock.now()) { entry, _ in
            entry.data = 2
            return (false, .success(2))
        }
        try await Task.sleep(for: .milliseconds(1))
        #expect(await observer.box.data == 1)
        stream!.values.forEach { $0.yield() }
        try await Task.sleep(for: .milliseconds(1))
        #expect(await observer.box.data == 2)
    }
}
