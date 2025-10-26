# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

swift-query is a Swift Package Manager library that provides TanStack Query-like data fetching and caching for SwiftUI applications. It manages asynchronous queries with automatic caching, invalidation, and UI updates.

## Development Commands

### Building
```bash
swift build
```

### Running Tests
```bash
# Run all tests
swift test

# Run a specific test suite
swift test --filter QueryClientFetchTests

# Run a single test
swift test --filter QueryClientFetchTests.firstFetchStoresCache_andSecondFetchHitsFreshCache
```

### Platform Requirements
- iOS 26+
- macOS 15+
- Swift 6.2+

## Architecture

### Core Components

**QueryKey** (Sources/SwiftQuery/QueryKey.swift)
- Public struct representing query identifiers
- Implements `Equatable`, `Hashable`, `Sendable`, `ExpressibleByArrayLiteral`, `ExpressibleByStringLiteral`, `CustomStringConvertible`
- Contains `parts: [String]` array for hierarchical keys
- Supports string literals: `"users"` or array literals: `["user", userId]`
- `description` property returns parts joined by "/" for logging

**QueryOptions** (Sources/SwiftQuery/QueryOptions.swift)
- Configuration struct for query behavior
- `staleTime: TimeInterval` - How long cached data is fresh (default: 0)
- `gcTime: TimeInterval` - Garbage collection time (default: 300, not yet implemented)
- `refetchOnAppear: Bool` - Whether to refetch on view appearance (default: true)

**QueryCacheEntry<Value>** (Sources/SwiftQuery/QueryCacheEntry.swift)
- Internal struct holding cached data and metadata
- Contains `data: Value?`, `error: Error?`
- Tracks `updatedAt: Date` for staleness calculations (no longer uses `readAt`)
- Not exposed publicly; managed by QueryClientStore

**QueryClientStore** (Sources/SwiftQuery/QueryClientStore.swift)
- Actor-based storage layer for thread-safe cache management
- Manages two types of streams: invalidation streams and sync cache streams
- Key methods:
  - `syncCacheStreams(queryKey:)` - Get sync cache stream continuations for a query
  - `storeSyncCacheStream(queryKey:id:continuation:)` - Store a sync cache stream continuation
  - `removeSyncCacheStream(queryKey:id:)` - Remove a sync cache stream
  - `invalidationStreams(queryKey:)` - Get invalidation stream continuations for a query
  - `storeInvalidationStream(queryKey:id:continuation:)` - Store an invalidation stream continuation
  - `removeInvalidationStream(queryKey:id:)` - Remove an invalidation stream
  - `entry(queryKey:as:)` - Read cache entry
  - `withEntry(queryKey:as:now:handler:)` - Atomic cache read/update
  - `removeEntry(queryKey:)` - Clear cache
- Data: `invalidationContinuations: [QueryKey: [UUID: AsyncStream<Void>.Continuation]]`, `syncCacheContinuations: [QueryKey: [UUID: AsyncStream<Void>.Continuation]]`, `cache: [QueryKey: Any]`

**QueryClient** (Sources/SwiftQuery/QueryClient.swift)
- Singleton cache manager (`QueryClient.shared`)
- Injectable `clock: Clock` for testability
- Uses `OSAllocatedUnfairLock<[QueryKey: Task<any Sendable, Error>]>` for in-flight request deduplication
- Key methods:
  - `invalidate(_:fileId:)` - Clear cache and notify all invalidation streams
  - `createSyncStream(queryKey:)` - Create sync cache stream for watching cache updates
  - `createInvalidationStream(queryKey:)` - Create invalidation stream for watching cache invalidations
  - `fetch(queryKey:options:forceRefresh:fileId:queryFn:)` - Core fetch with caching
- Returns `(isFresh: Bool, result: Result<Value, Error>)` from fetch
- Freshness check: `now.timeIntervalSince(entry.updatedAt) < options.staleTime`
- In-flight request deduplication: if a request is already running for a query key, subsequent requests wait for the same task instead of making new ones

**QueryBox<Value>** (Sources/SwiftQuery/QueryBox.swift)
- Public struct for query state container
- Contains `data: Value?`, `isLoading: Bool`, `error: Error?`
- Conforms to `Sendable`

**QueryObserver<Value>** (Sources/SwiftQuery/QueryObserver.swift)
- MainActor-isolated, `@Observable` class for query state management
- Contains `box: QueryBox<Value>` for UI binding
- `queryKey: QueryKey?` property with didSet observer that triggers subscription
- Subscribes to sync cache streams via `subscribe(queryKey:)`
- When cache is synced, calls `syncStateWithCache(queryKey:now:)` to update UI
- Cleans up streams on deinit by canceling task

**UseQuery<Value>** (Sources/SwiftQuery/UseQuery.swift)
- Property wrapper for query state in views
- Wraps `@State private var observer: QueryObserver<Value>`
- `wrappedValue: Value?` - Direct data access
- `projectedValue: Binding<QueryObserver<Value>>` - Access to observer for `.query()` modifier
- Accepts optional initial `queryKey` in initializer
- Provides `query()` view extension method that attaches `QueryModifier`

**QueryModifier<Value>** (Sources/SwiftQuery/UseQuery.swift)
- ViewModifier implementing fetch lifecycle
- Orchestrates stale-while-revalidate pattern
- First fetch returns immediately with cache/loading
- Second fetch runs in background if data is not fresh
- Background fetch errors are silently ignored
- Uses QueryBatchExecutor to deduplicate concurrent requests
- Lifecycle: `.task(id: queryKey)` updates observer's queryKey if changed and calls `fetch()` and `subscribe()`, and `.onAppear` with `refetchOnAppear` option
- On successful fetch, calls `onCompleted` callback and yields to all sync cache stream watchers
- `onCompleted` can be called twice: once for cached data (if fresh) and once for refreshed data
- `subscribe()` method listens to invalidation stream and refetches on invalidation

**Boundary<Content, Value>** (Sources/SwiftQuery/QueryBoundary.swift)
- Conditional view renderer for query states
- Three overloads: content-only, content+fallback, content+fallback+errorFallback
- All marked with `@_disfavoredOverload` to allow custom extensions to take precedence
- Renders based on: data exists → content, error exists → errorFallback, loading → fallback
- Default fallback is `ProgressView()`

**QueryBatchExecutor** (Sources/SwiftQuery/QueryBatchExecutor.swift)
- Actor deduplicating concurrent requests for same query key
- Singleton instance (`QueryBatchExecutor.shared`)
- Tracks tasks per query key in queue
- Default 0.1s debounce window to collect concurrent requests
- All queued requests resolve after first task completes
- Clears queue after execution completes

**QueryError** (Sources/SwiftQuery/QueryError.swift)
- Internal enum for library-specific errors
- `inFlightCastError` - Error when casting in-flight task result fails

**SwiftQueryLogger** (Sources/SwiftQuery/SwiftQueryLogger.swift)
- Internal enum for debug logging
- Uses `os.Logger` with subsystem "com.horitayuya.swift-query"
- `d(_ message:, metadata:)` - Debug logging method (only logs in DEBUG builds)
- Logs query operations like cache hits, misses, invalidations, and batch executions

### Data Flow

#### Query Execution Flow:
1. View declares: `@UseQuery<User> var user`
2. View uses: `Boundary($user) { ... }.query($user, queryKey: ...) { ... }`
3. `.query()` modifier attaches `QueryModifier` to view
4. `.task(id: queryKey)` triggers when queryKey changes:
   - Sets `observer.queryKey` if it changed (triggers subscription via didSet in QueryObserver)
   - Calls `fetch(queryKey:fileId:)` to initiate data fetching
   - Calls `subscribe(queryKey:fileId:)` to listen for invalidations
5. `.onAppear` triggers if `refetchOnAppear: true`:
   - Calls `fetch(queryKey:fileId:)` in a Task
6. `QueryModifier.fetch()`:
   - Calls `batchExecutor.batchExecution()` to deduplicate concurrent requests
   - Calls `queryClient.fetch(forceRefresh: false)`:
     - Checks in-flight tasks first; waits for existing task if one exists
     - If cache exists and not forced: checks freshness using `now.timeIntervalSince(entry.updatedAt) < options.staleTime`
     - If cache fresh: returns (`isFresh: true`, cached data)
     - If cache stale: returns (`isFresh: false`, cached data)
     - If cache missing or forced: fetches new data, stores in cache, returns (`isFresh: true`, new data)
   - Gets all sync cache stream continuations for this query
   - On success: updates `observer.box.data`, `observer.box.error`, and `observer.box.isLoading`, yields to all sync cache stream watchers, calls `onCompleted` if `isFresh`
   - On failure: updates `observer.box.error` and `observer.box.isLoading`
   - If `!isFresh`, runs second fetch in background with `forceRefresh: true`:
     - On success: updates `observer.box.data` and `observer.box.error`, yields to sync cache stream watchers, calls `onCompleted`
     - On failure: silently ignores error (stale-while-revalidate)
7. `QueryModifier.subscribe(queryKey:fileId:)` listens to invalidation stream:
   - Creates invalidation stream via `queryClient.createInvalidationStream()`
   - On each invalidation event, calls `fetch()` to refetch data
   - Cancels when task is cancelled
8. `QueryObserver.subscribe(queryKey:)` creates sync cache stream:
   - Cancels previous task if exists
   - Syncs state with cache immediately via `syncStateWithCache()`
   - Listens for sync cache events and syncs state on each event
9. When cache invalidated via `queryClient.invalidate()`:
   - Cache entry removed from store
   - All invalidation stream continuations yield `()` to signal watchers
   - All `QueryModifier.subscribe()` tasks wake and call `fetch()` to refetch
10. `Boundary` renders content based on `observer.box` state

#### Cache Invalidation Flow:
1. Call `await queryClient.invalidate(queryKey)`
2. Remove cache entry from `QueryClientStore`
3. Get all invalidation stream continuations for the query key
4. Each invalidation continuation yields `()` to signal watchers
5. All `QueryModifier.subscribe()` tasks wake and call `fetch()` to refetch data
6. `observer.box` updates, triggering UI redraw

### Key Patterns

**Stale-While-Revalidate**
- `staleTime`: How long cached data is considered fresh (default: 0)
- Freshness check: `now.timeIntervalSince(entry.updatedAt) < staleTime` (Sources/SwiftQuery/QueryClient.swift:79)
- When data is stale but cached:
  1. First fetch returns cached value immediately (`isFresh: false`)
  2. Second fetch runs in background to get fresh data (Sources/SwiftQuery/UseQuery.swift:139-165)
  3. Background fetch updates cache and UI on success
  4. Background fetch errors are silently ignored to preserve stale data (Sources/SwiftQuery/UseQuery.swift:160-164)

**Request Deduplication via In-Flight Tasks**
- QueryClient maintains `OSAllocatedUnfairLock<[QueryKey: Task<any Sendable, Error>]>` for in-flight request tracking (Sources/SwiftQuery/QueryClient.swift:8)
- When fetch is called and a task is already running for the query key:
  1. Subsequent requests wait for the existing task (Sources/SwiftQuery/QueryClient.swift:85-113)
  2. All requests share the result of the single execution
  3. Task is removed from in-flight map after completion (Sources/SwiftQuery/QueryClient.swift:121-123, 132-134)
- Prevents duplicate network calls at QueryClient level (lower level than QueryBatchExecutor)

**Request Deduplication via QueryBatchExecutor**
- Concurrent requests for same query key are batched together at view level (Sources/SwiftQuery/QueryBatchExecutor.swift)
- First request waits for debounce window (default 0.1s) to collect more requests
- All requests in the batch share the result of a single execution
- Queue is cleared after execution completes
- Prevents duplicate fetches when multiple views mount simultaneously

**Stream Types**
There are two types of streams in swift-query:

1. **Sync Cache Streams** - Used by QueryObserver to stay in sync with cache
   - Each query key can have multiple sync cache stream watchers (different QueryObservers)
   - Uses `AsyncStream<Void>` to notify all watchers when cache is updated
   - Watchers registered via `createSyncStream(queryKey:)` (Sources/SwiftQuery/QueryClient.swift:34-44)
   - Stream continuations stored in `QueryClientStore.syncCacheContinuations`
   - Automatic cleanup on termination handler (Sources/SwiftQuery/QueryClient.swift:38-42)
   - Each observer has a unique UUID to prevent conflicts

2. **Invalidation Streams** - Used by QueryModifier to refetch on invalidation
   - Each query key can have multiple invalidation stream watchers (different QueryModifiers)
   - Uses `AsyncStream<Void>` to notify all watchers when cache is invalidated
   - Watchers registered via `createInvalidationStream(queryKey:)` (Sources/SwiftQuery/QueryClient.swift:47-57)
   - Stream continuations stored in `QueryClientStore.invalidationContinuations`
   - Automatic cleanup on termination handler (Sources/SwiftQuery/QueryClient.swift:51-55)
   - Each modifier has a unique UUID to prevent conflicts

### Testing Utilities

**Clock Protocol** (Sources/SwiftQuery/Clock.swift:3-5)
- Protocol for injectable time source: `func now() -> Date`
- Default implementation: `ClockImpl` returns `Date()`
- Enables deterministic testing by injecting mock clocks
- `QueryClient` accepts custom clock in init

**TestClock** (Tests/SwiftQueryTests/TestClock.swift:5-17)
- Mock Clock implementation for deterministic testing
- Thread-safe via `OSAllocatedUnfairLock`
- `set(now:)` method to control time in tests
- Example usage:
  ```swift
  let clock = TestClock()
  let client = QueryClient(clock: clock)
  clock.set(now: date.addingTimeInterval(60))
  ```

**Test Patterns**
- Use `@Suite` for test groups, `@Test` for individual tests
- Test function names in snake_case (e.g., `firstFetchStoresCache_andSecondFetchHitsFreshCache`)
- Actor-based counters/flags for tracking concurrent executions
- See QueryClientFetchTests.swift, BatchExecutorTests.swift for examples

## Usage Pattern

### Basic Query
```swift
struct MyView: View {
    @UseQuery<User> var user

    var body: some View {
        Boundary($user) { user in
            Text(user.name)
        } fallback: {
            ProgressView()
        } errorFallback: { error in
            Text("Error: \(error)")
        }
        .query($user, queryKey: ["user", userId], options: QueryOptions(staleTime: 60)) {
            try await fetchUser(userId)
        } onCompleted: { user in
            print("Loaded \(user.name)")
        }
    }
}
```

### Custom Boundary Extension (Recommended)
```swift
// Define once in your app
extension Boundary {
    init(
        _ value: Binding<QueryObserver<Value>>,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.init(value, content: content) {
            ProgressView().scaleEffect(1.5)
        } errorFallback: { error in
            VStack {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(error.localizedDescription)
            }
        }
    }
}

// Then use everywhere
struct MyView: View {
    @UseQuery<User> var user

    var body: some View {
        Boundary($user) { user in
            Text(user.name)
        }
        .query($user, queryKey: ["user", userId]) {
            try await fetchUser(userId)
        }
    }
}
```

## Mutations

**MutationBox** (Sources/SwiftQuery/MutationBox.swift)
- Public struct for mutation state
- Contains `public internal(set) var isRunning: Bool` and `public internal(set) var error: Error?`
- Conforms to `Sendable`

**MutationClient** (Sources/SwiftQuery/MutationClient.swift)
- MainActor-isolated struct for executing write operations
- Wraps `@Binding private var box: MutationBox` for state updates
- Holds reference to `QueryClient` for cache invalidation
- `isLoading: Bool` computed property that returns `box.isRunning`
- Key methods:
  - `asyncPerform(_ mutationFn:, onCompleted:) -> Result<Void, Error>` - Void mutation, onCompleted receives `QueryClient`
  - `asyncPerform<T>(_ operation:, onCompleted:) -> Result<T, Error>` - Typed mutation returning value, onCompleted receives value and `QueryClient`
  - `reset()` - Clear error and loading state
- Both `asyncPerform` methods are `@discardableResult`
- `onCompleted` callback for void mutation is async: `@Sendable (QueryClient) async -> Void`
- `onCompleted` callback for typed mutation is sync: `@Sendable (T, QueryClient) -> Void`

**UseMutation** (Sources/SwiftQuery/UseMutation.swift)
- Property wrapper for mutations in views
- MainActor-isolated struct conforming to `DynamicProperty`
- `@State private var box = MutationBox()` for state management
- `wrappedValue: MutationClient` - Access to mutation client
- `projectedValue: Binding<MutationBox>` - Access to state binding via `$box`

### Usage Example
```swift
struct EditView: View {
    @UseQuery<User> var user
    @UseMutation var updateUser

    var body: some View {
        Boundary($user) { user in
            Button("Update") {
                Task {
                    await updateUser.asyncPerform {
                        try await api.updateUser(id: user.id, name: "New Name")
                    } onCompleted: { queryClient in
                        // Invalidate cache to trigger refetch
                        await queryClient.invalidate(["user", user.id])
                    }
                }
            }
            .disabled(updateUser.isLoading)

            if let error = $updateUser.error {
                Text("Error: \(error)")
            }
        }
        .query($user, queryKey: ["user", userId]) {
            try await api.fetchUser(id: userId)
        }
    }
}
```

# CODE STYLE
## TEST
- Use swift-testing
- Group by @Suite
- Each @Test func name MUST be snakecase.
