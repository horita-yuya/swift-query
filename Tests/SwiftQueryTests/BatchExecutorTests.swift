import Foundation
import Testing
@testable import SwiftQuery

@Suite struct BatchExecutorTests {
    actor Counter {
        private(set) var value = 0
        func inc() { value += 1 }
    }
    
    actor Flag {
        private(set) var value = false
        func set(_ v: Bool) { value = v }
        func get() -> Bool { value }
    }
    
    actor Gate {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        
        func wait() async {
            await withCheckedContinuation { cc in
                waiters.append(cc)
            }
        }
        
        func open() {
            let cs = waiters
            waiters.removeAll()
            cs.forEach { $0.resume() }
        }
    }

    @Test
    func multiple_call_into_single_call() async {
        let exec = QueryBatchExecutor()
        let key: QueryKey = ["test", "single"]
        let runs = Counter()

        let perform = { @Sendable in
            try? await Task.sleep(nanoseconds: 30_000_000)
            await runs.inc()
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = await exec.batchExecution(queryKey: key, debounce: 0.05, perform: perform)
                }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
        }

        let count = await runs.value
        #expect(count == 1)
    }

    @Test
    func other_calls_resolved_after_first_call_resolved() async {
        let exec = QueryBatchExecutor()
        let key: QueryKey = ["test", "ordering"]

        let gate = Gate()
        let entered = Flag()
        let completed2 = Flag()
        let runs = Counter()

        let perform = { @Sendable in
            await entered.set(true)
            await gate.wait()
            try? await Task.sleep(nanoseconds: 10_000_000)
            await runs.inc()
        }

        async let t1: Void = exec.batchExecution(queryKey: key, debounce: 0.05, perform: perform)
        async let t2: Void = {
            _ = await exec.batchExecution(queryKey: key, debounce: 0.05, perform: perform)
            await completed2.set(true)
        }()

        try? await Task.sleep(nanoseconds: 80_000_000)

        #expect(await entered.value == true)
        #expect(await completed2.value == false)

        await gate.open()

        _ = await (t1, t2)

        #expect(await completed2.value == true)
        #expect(await runs.value == 1)
    }
}
