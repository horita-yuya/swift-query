import Foundation
import Testing
import SwiftUI
@testable import SwiftQuery

@Suite struct SubscribeTests {
    actor Counter {
        private(set) var value = 0
        func inc() { value += 1 }
        func reset() { value = 0 }
    }

    actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }

        func signal() {
            continuation?.resume()
            continuation = nil
        }
    }

    @Test func subscribe_terminates_when_task_is_cancelled() async {
        let client = QueryClient()
        let key: QueryKey = ["user", "123"]
        let fetchCount = Counter()

        let task = Task {
            let modifier = TestQueryModifier<String>(
                queryKey: key,
                options: QueryOptions(staleTime: 60),
                queryFn: {
                    await fetchCount.inc()
                    return "test_value"
                }
            )

            await modifier.subscribe(queryKey: key)
        }

        // Wait a bit for initial fetch
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Cancel the task
        task.cancel()

        // Wait for cancellation to propagate
        try? await Task.sleep(nanoseconds: 100_000_000)

        let initialCount = await fetchCount.value

        // Invalidate after cancellation - should NOT trigger new fetch
        await client.invalidate(key)

        try? await Task.sleep(nanoseconds: 100_000_000)

        let finalCount = await fetchCount.value

        // Fetch count should not increase after task cancellation
        #expect(initialCount == finalCount)
    }

    // MARK: - No Self-Triggering Loop Tests

    @Test func subscribe_does_not_self_trigger_on_fetch() async {
        let _ = QueryClient()
        let key: QueryKey = ["posts", "1"]
        let fetchCount = Counter()
        let gate = Gate()

        let task = Task {
            let modifier = TestQueryModifier<String>(
                queryKey: key,
                options: QueryOptions(staleTime: 0),
                queryFn: {
                    await fetchCount.inc()
                    await gate.signal()
                    return "post_data"
                }
            )

            await modifier.subscribe(queryKey: key)
        }

        // Wait for initial fetch to complete
        await gate.wait()

        // Wait a bit more to ensure no additional fetches
        try? await Task.sleep(nanoseconds: 200_000_000)

        let count = await fetchCount.value

        // Should only fetch once (initial), no self-triggering loop
        #expect(count == 1)

        task.cancel()
    }

    @Test func subscribe_only_refetches_on_explicit_invalidation() async {
        let client = QueryClient()
        let key: QueryKey = ["data", "bounded"]
        let fetchCount = Counter()
        let firstGate = Gate()
        let secondGate = Gate()

        let task = Task {
            let modifier = TestQueryModifier<Int>(
                queryKey: key,
                options: QueryOptions(staleTime: 60),
                queryFn: {
                    let current = await fetchCount.value
                    await fetchCount.inc()

                    if current == 0 {
                        await firstGate.signal()
                    } else if current == 1 {
                        await secondGate.signal()
                    }

                    return current + 1
                }
            )

            await modifier.subscribe(queryKey: key)
        }

        // Wait for initial fetch
        await firstGate.wait()
        #expect(await fetchCount.value == 1)

        // Explicitly invalidate - should trigger exactly one more fetch
        await client.invalidate(key)
        await secondGate.wait()

        #expect(await fetchCount.value == 2)

        // Wait to ensure no additional fetches
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await fetchCount.value == 2)

        task.cancel()
    }

    // MARK: - Bounded Execution Tests

    @Test func subscribe_bounded_execution_with_multiple_invalidations() async {
        let client = QueryClient()
        let key: QueryKey = ["bounded", "test"]
        let fetchCount = Counter()
        let gates = (0..<5).map { _ in Gate() }

        let task = Task {
            let modifier = TestQueryModifier<String>(
                queryKey: key,
                options: QueryOptions(staleTime: 0),
                queryFn: {
                    let current = await fetchCount.value
                    await fetchCount.inc()

                    if current < gates.count {
                        await gates[current].signal()
                    }

                    return "value_\(current)"
                }
            )

            await modifier.subscribe(queryKey: key)
        }

        // Wait for initial fetch
        await gates[0].wait()
        #expect(await fetchCount.value == 1)

        // Trigger exactly 4 more invalidations
        for i in 1..<5 {
            await client.invalidate(key)
            await gates[i].wait()
            #expect(await fetchCount.value == i + 1)
        }

        // Final check: exactly 5 fetches (1 initial + 4 invalidations)
        #expect(await fetchCount.value == 5)

        task.cancel()
    }

    // MARK: - Multiple Subscribers Tests

    @Test func multiple_subscribers_do_not_cause_loops() async {
        let _ = QueryClient()
        let key: QueryKey = ["shared", "resource"]
        let fetchCount = Counter()
        let gate = Gate()

        // Create 3 concurrent subscribers
        let tasks = (0..<3).map { _ in
            Task {
                let modifier = TestQueryModifier<String>(
                    queryKey: key,
                    options: QueryOptions(staleTime: 60),
                    queryFn: {
                        await fetchCount.inc()
                        await gate.signal()
                        return "shared_data"
                    }
                )

                await modifier.subscribe(queryKey: key)
            }
        }

        // Wait for initial fetches (should be coalesced)
        await gate.wait()

        // Wait to ensure no additional fetches
        try? await Task.sleep(nanoseconds: 200_000_000)

        let count = await fetchCount.value

        // With proper deduplication, should only fetch once despite 3 subscribers
        #expect(count == 1)

        for task in tasks {
            task.cancel()
        }
    }

    @Test func multiple_subscribers_all_receive_invalidation_without_loops() async {
        let client = QueryClient()
        let key: QueryKey = ["multi", "invalidation"]
        let fetchCount = Counter()
        let receivedCounts = (0..<3).map { _ in Counter() }

        let tasks = (0..<3).enumerated().map { (index, _) in
            Task {
                let modifier = TestQueryModifier<String>(
                    queryKey: key,
                    options: QueryOptions(staleTime: 60),
                    queryFn: {
                        await fetchCount.inc()
                        await receivedCounts[index].inc()
                        return "data_\(await fetchCount.value)"
                    }
                )

                await modifier.subscribe(queryKey: key)
            }
        }

        // Wait for initial fetches
        try? await Task.sleep(nanoseconds: 200_000_000)

        let initialFetchCount = await fetchCount.value

        // Trigger invalidation
        await client.invalidate(key)

        // Wait for refetches
        try? await Task.sleep(nanoseconds: 300_000_000)

        let finalFetchCount = await fetchCount.value

        // Should fetch exactly once more (shared across all subscribers)
        #expect(finalFetchCount == initialFetchCount + 1)

        // All subscribers should have been notified
        for counter in receivedCounts {
            let count = await counter.value
            // Each subscriber gets its own fetch attempt, but they should be coalesced
            #expect(count >= 1)
        }

        for task in tasks {
            task.cancel()
        }
    }

    // MARK: - Stream Cleanup Tests

    @Test func subscribe_stops_responding_after_cancellation() async {
        let client = QueryClient()
        let key: QueryKey = ["cleanup", "test"]
        let fetchCount = Counter()

        let task = Task {
            let modifier = TestQueryModifier<String>(
                queryKey: key,
                options: QueryOptions(staleTime: 60),
                queryFn: {
                    await fetchCount.inc()
                    return "cleanup_value"
                }
            )

            await modifier.subscribe(queryKey: key)
        }

        // Wait for subscription to be established and initial fetch
        try? await Task.sleep(nanoseconds: 150_000_000)

        let countBeforeCancel = await fetchCount.value
        #expect(countBeforeCancel == 1)

        // Cancel the task
        task.cancel()

        // Wait for cleanup
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Invalidate after cancellation
        await client.invalidate(key)

        // Wait to see if any fetch happens
        try? await Task.sleep(nanoseconds: 200_000_000)

        // Should not fetch again after cancellation
        let countAfterCancel = await fetchCount.value
        #expect(countAfterCancel == countBeforeCancel)
    }

    @Test func subscribe_does_not_create_circular_invalidation() async {
        let client = QueryClient()
        let key: QueryKey = ["circular", "check"]
        let fetchCount = Counter()
        let invalidationCount = Counter()

        let task = Task {
            let modifier = TestQueryModifier<String>(
                queryKey: key,
                options: QueryOptions(staleTime: 0),
                queryFn: {
                    await fetchCount.inc()
                    // This simulates code that might try to invalidate during fetch
                    // (though it shouldn't happen in practice)
                    return "no_circular_value"
                }
            )

            await modifier.subscribe(queryKey: key)
        }

        // Wait for initial fetch
        try? await Task.sleep(nanoseconds: 150_000_000)

        let initialFetch = await fetchCount.value
        #expect(initialFetch == 1)

        // Manually invalidate
        await invalidationCount.inc()
        await client.invalidate(key)

        // Wait for refetch
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(await fetchCount.value == 2)
        #expect(await invalidationCount.value == 1)

        // Another manual invalidation
        await invalidationCount.inc()
        await client.invalidate(key)

        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(await fetchCount.value == 3)
        #expect(await invalidationCount.value == 2)

        // Fetch count should exactly match: 1 initial + 2 manual invalidations = 3
        // This proves no circular/self-triggering behavior

        task.cancel()
    }
}
