import SwiftUI

@MainActor
@propertyWrapper
public struct UseQuery<Value: Sendable>: DynamicProperty {
    @State private var observer: QueryObserver<Value>
    
    public var wrappedValue: Value? {
        observer.box.data
    }
    
    public var projectedValue: Binding<QueryObserver<Value>> {
        $observer
    }
    
    public init(_ queryKey: QueryKey? = nil) {
        self.observer = QueryObserver<Value>(
            queryKey: queryKey,
            queryClient: QueryClient.shared,
        )
    }
}

public extension View {
    func query<Value: Sendable>(
        _ observer: Binding<QueryObserver<Value>>,
        queryKey: QueryKey,
        options: QueryOptions = .init(),
        fileId: StaticString = #fileID,
        queryFn: @escaping @Sendable () async throws -> Value,
        onCompleted: ((Value) -> Void)? = nil
    ) -> some View {
        modifier(
            QueryModifier(
                observer: observer,
                queryKey: queryKey,
                options: options,
                fileId: fileId,
                queryClient: QueryClient.shared,
                batchExecutor: QueryBatchExecutor.shared,
                queryFn: queryFn,
                onCompleted: onCompleted
            )
        )
    }
    
    func query<Value: Sendable>(
        queryKey: QueryKey,
        options: QueryOptions = .init(),
        fileId: StaticString = #fileID,
        queryFn: @escaping @Sendable () async throws -> Value,
        onCompleted: ((Value) -> Void)? = nil
    ) -> some View {
        let observer = QueryObserver<Value>(
            queryKey: nil,
            queryClient: QueryClient.shared,
        )
        return modifier(
            QueryModifier(
                observer: .init(get: { observer }, set: { _ in }),
                queryKey: queryKey,
                options: options,
                fileId: fileId,
                queryClient: QueryClient.shared,
                batchExecutor: QueryBatchExecutor.shared,
                queryFn: queryFn,
                onCompleted: onCompleted
            )
        )
    }
}

struct QueryModifier<Value: Sendable>: ViewModifier {
    @Binding var observer: QueryObserver<Value>
    
    private let queryKey: QueryKey
    private let options: QueryOptions
    private let fileId: StaticString
    private let queryClient: QueryClient
    private let batchExecutor: QueryBatchExecutor
    private let queryFn: @Sendable () async throws -> Value
    private let onCompleted: ((Value) -> Void)?
    
    init(
        observer: Binding<QueryObserver<Value>>,
        queryKey: QueryKey,
        options: QueryOptions,
        fileId: StaticString,
        queryClient: QueryClient,
        batchExecutor: QueryBatchExecutor,
        queryFn: @Sendable @escaping () async throws -> Value,
        onCompleted: ((Value) -> Void)?
    ) {
        self._observer = observer
        self.queryKey = queryKey
        self.options = options
        self.fileId = fileId
        self.queryClient = queryClient
        self.batchExecutor = batchExecutor
        self.queryFn = queryFn
        self.onCompleted = onCompleted
    }

    func body(content: Content) -> some View {
        content
            .task(id: queryKey) {
                if observer.queryKey != queryKey {
                    observer.queryKey = queryKey
                }
                await fetch(queryKey: queryKey, fileId: fileId)
                await subscribe(queryKey: queryKey, fileId: fileId)
            }
            .onAppear {
                if options.refetchOnAppear {
                    Task {
                        await fetch(queryKey: queryKey, fileId: fileId)
                    }
                }
            }
    }
    
    @inline(__always)
    func fetch(queryKey: QueryKey, fileId: StaticString) async {
        await batchExecutor.batchExecution(queryKey: queryKey) {
            SwiftQueryLogger.d(
                "Batch executing fetch",
                metadata: [
                    "queryKey": queryKey,
                    "View": fileId,
                ]
            )
            
            let (isFresh, result) = await queryClient.fetch(
                queryKey: queryKey,
                options: options,
                forceRefresh: false,
                fileId: fileId,
                queryFn: queryFn
            )
            
            let syncCacheStreams = await queryClient.store.syncCacheStreams(queryKey: queryKey)?.values.map { $0 } ?? []
            switch result {
            case .success(let value):
                await MainActor.run {
                    observer.box.data = value
                    observer.box.error = nil
                    observer.box.isLoading = false

                    if isFresh {
                        onCompleted?(value)
                    }
                }
                for continuation in syncCacheStreams {
                    continuation.yield(())
                }
                
            case .failure(let error):
                await MainActor.run {
                    observer.box.error = error
                    observer.box.isLoading = false
                }
            }
            
            if !isFresh {
                let (_, result) = await queryClient.fetch(
                    queryKey: queryKey,
                    options: options,
                    forceRefresh: true,
                    fileId: fileId,
                    queryFn: queryFn
                )
                
                switch result {
                case .success(let value):
                    await MainActor.run {
                        observer.box.data = value
                        observer.box.error = nil
                        
                        // onCompleted can be called twice, but this feature can be changed in future.
                        onCompleted?(value)
                    }
                    for continuation in syncCacheStreams {
                        continuation.yield(())
                    }
                case .failure:
                    // Second try is for updating cache for new data.
                    // It is convenient to not override existing data with error.
                    break
                }
            }
        }
    }
    
    @inline(__always)
    func subscribe(queryKey: QueryKey, fileId: StaticString) async {
        let invalidationStream = await queryClient.createInvalidationStream(queryKey: queryKey)
        for await _ in invalidationStream {
            if Task.isCancelled {
                return
            }
            await fetch(queryKey: queryKey, fileId: fileId)
        }
    }
}
