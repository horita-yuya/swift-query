import SwiftUI

@MainActor
@Observable
public final class QueryObserver<Value: Sendable>: Sendable {
    internal var box: QueryBox<Value>
    internal var queryKey: QueryKey? {
        didSet {
            if let queryKey {
                subscribe(queryKey: queryKey)
            }
        }
    }
    
    @ObservationIgnored
    internal var task: Task<Void, Never>?
    private let queryClient: QueryClient
    
    deinit {
        task?.cancel()
    }
    
    init(
        queryKey: QueryKey?,
        queryClient: QueryClient,
    ) {
        self.box = QueryBox<Value>()
        self.queryKey = queryKey
        self.queryClient = queryClient
        
        if let queryKey {
            subscribe(queryKey: queryKey)
        }
    }
    
    func subscribe(queryKey: QueryKey) {
        let queryClient = queryClient
        self.task?.cancel()
        self.task = Task { [weak self] in
            let now = queryClient.clock.now()
            await self?.syncStateWithCache(queryKey: queryKey, now: now)
            
            for await _ in await queryClient.createSyncStream(queryKey: queryKey) {
                if Task.isCancelled {
                    return
                }
                await self?.syncStateWithCache(queryKey: queryKey, now: now)
            }
        }
    }
    
    func syncStateWithCache(queryKey: QueryKey, now: Date) async {
        if let cacheValue = await queryClient.store.entry(queryKey: queryKey, as: Value.self) {
            box.data = cacheValue.data
            box.error = nil
        }
    }
}
