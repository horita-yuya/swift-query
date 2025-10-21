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

        let task = Task { @MainActor in
            let box = QueryBox<String>()
            let modifier = QueryModifier<String>(
                box: .constant(box),
                queryKey: key,
                options: QueryOptions(staleTime: 60),
                fileId: #fileID,
                queryClient: client,
                batchExecutor: BatchExecutor(),
                queryFn: {
                    await fetchCount.inc()
                    return "test_value"
                },
                onCompleted: nil
            )

            await modifier.subscribe(queryKey: key)
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        task.cancel()

        try? await Task.sleep(nanoseconds: 100_000_000)

        let initialCount = await fetchCount.value

        await client.invalidate(key)

        try? await Task.sleep(nanoseconds: 100_000_000)

        let finalCount = await fetchCount.value

        #expect(initialCount == finalCount)
    }

    @Test func subscribe_does_not_self_trigger_on_fetch() async {
        let client = QueryClient()
        let key: QueryKey = ["posts", "1"]
        let fetchCount = Counter()
        let gate = Gate()

        let task = Task { @MainActor in
            let box = QueryBox<String>()
            let modifier = QueryModifier<String>(
                box: .constant(box),
                queryKey: key,
                options: QueryOptions(staleTime: 0),
                fileId: #fileID,
                queryClient: client,
                batchExecutor: BatchExecutor(),
                queryFn: {
                    await fetchCount.inc()
                    await gate.signal()
                    return "post_data"
                },
                onCompleted: nil
            )

            await modifier.subscribe(queryKey: key)
        }

        await gate.wait()

        try? await Task.sleep(nanoseconds: 200_000_000)

        let count = await fetchCount.value

        #expect(count == 1)

        task.cancel()
    }

    @Test func subscribe_only_refetches_on_explicit_invalidation() async {
        let client = QueryClient()
        let key: QueryKey = ["data", "bounded"]
        let fetchCount = Counter()
        let firstGate = Gate()
        let secondGate = Gate()

        let task = Task { @MainActor in
            let box = QueryBox<Int>()
            let modifier = QueryModifier<Int>(
                box: .constant(box),
                queryKey: key,
                options: QueryOptions(staleTime: 60),
                fileId: #fileID,
                queryClient: client,
                batchExecutor: BatchExecutor(),
                queryFn: {
                    let current = await fetchCount.value
                    await fetchCount.inc()

                    if current == 0 {
                        await firstGate.signal()
                    } else if current == 1 {
                        await secondGate.signal()
                    }

                    return current + 1
                },
                onCompleted: nil
            )

            await modifier.subscribe(queryKey: key)
        }

        await firstGate.wait()
        #expect(await fetchCount.value == 1)

        await client.invalidate(key)
        await secondGate.wait()

        #expect(await fetchCount.value == 2)

        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(await fetchCount.value == 2)

        task.cancel()
    }

    @Test func subscribe_bounded_execution_with_multiple_invalidations() async {
        let client = QueryClient()
        let key: QueryKey = ["bounded", "test"]
        let fetchCount = Counter()
        let gates = (0..<5).map { _ in Gate() }

        let task = Task { @MainActor in
            let box = QueryBox<String>()
            let modifier = QueryModifier<String>(
                box: .constant(box),
                queryKey: key,
                options: QueryOptions(staleTime: 0),
                fileId: #fileID,
                queryClient: client,
                batchExecutor: BatchExecutor(),
                queryFn: {
                    let current = await fetchCount.value
                    await fetchCount.inc()

                    if current < gates.count {
                        await gates[current].signal()
                    }

                    return "value_\(current)"
                },
                onCompleted: nil
            )

            await modifier.subscribe(queryKey: key)
        }

        await gates[0].wait()
        #expect(await fetchCount.value == 1)

        for i in 1..<5 {
            await client.invalidate(key)
            await gates[i].wait()
            #expect(await fetchCount.value == i + 1)
        }

        #expect(await fetchCount.value == 5)

        task.cancel()
    }

    @Test func multiple_subscribers_do_not_cause_loops() async {
        let client = QueryClient()
        let key: QueryKey = ["shared", "resource"]
        let fetchCount = Counter()
        let gate = Gate()
        let batchExecutor = BatchExecutor()

        // Create 3 concurrent subscribers
        let tasks = (0..<3).map { _ in
            Task { @MainActor in
                let box = QueryBox<String>()
                let modifier = QueryModifier<String>(
                    box: .constant(box),
                    queryKey: key,
                    options: QueryOptions(staleTime: 60),
                    fileId: #fileID,
                    queryClient: client,
                    batchExecutor: batchExecutor,
                    queryFn: {
                        await fetchCount.inc()
                        await gate.signal()
                        return "shared_data"
                    },
                    onCompleted: nil
                )

                await modifier.subscribe(queryKey: key)
            }
        }

        await gate.wait()

        try? await Task.sleep(nanoseconds: 200_000_000)

        let count = await fetchCount.value

        #expect(count == 1)

        for task in tasks {
            task.cancel()
        }
    }

    @Test func subscribe_stops_responding_after_cancellation() async {
        let client = QueryClient()
        let key: QueryKey = ["cleanup", "test"]
        let fetchCount = Counter()

        let task = Task { @MainActor in
            let box = QueryBox<String>()
            let modifier = QueryModifier<String>(
                box: .constant(box),
                queryKey: key,
                options: QueryOptions(staleTime: 60),
                fileId: #fileID,
                queryClient: client,
                batchExecutor: BatchExecutor(),
                queryFn: {
                    await fetchCount.inc()
                    return "cleanup_value"
                },
                onCompleted: nil
            )

            await modifier.subscribe(queryKey: key)
        }

        try? await Task.sleep(nanoseconds: 150_000_000)

        let countBeforeCancel = await fetchCount.value
        #expect(countBeforeCancel == 1)

        task.cancel()

        try? await Task.sleep(nanoseconds: 200_000_000)

        await client.invalidate(key)

        try? await Task.sleep(nanoseconds: 200_000_000)

        let countAfterCancel = await fetchCount.value
        #expect(countAfterCancel == countBeforeCancel)
    }

    @Test func subscribe_does_not_create_circular_invalidation() async {
        let client = QueryClient()
        let key: QueryKey = ["circular", "check"]
        let fetchCount = Counter()
        let invalidationCount = Counter()

        let task = Task { @MainActor in
            let box = QueryBox<String>()
            let modifier = QueryModifier<String>(
                box: .constant(box),
                queryKey: key,
                options: QueryOptions(staleTime: 0),
                fileId: #fileID,
                queryClient: client,
                batchExecutor: BatchExecutor(),
                queryFn: {
                    await fetchCount.inc()
                    return "no_circular_value"
                },
                onCompleted: nil
            )

            await modifier.subscribe(queryKey: key)
        }

        try? await Task.sleep(nanoseconds: 150_000_000)

        let initialFetch = await fetchCount.value
        #expect(initialFetch == 1)

        await invalidationCount.inc()
        await client.invalidate(key)

        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(await fetchCount.value == 2)
        #expect(await invalidationCount.value == 1)

        await invalidationCount.inc()
        await client.invalidate(key)

        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(await fetchCount.value == 3)
        #expect(await invalidationCount.value == 2)

        task.cancel()
    }
}
