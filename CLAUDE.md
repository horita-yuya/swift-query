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

**QueryKey** (Sources/SwiftQuery/Query.swift:9-26)
- Public struct representing query identifiers
- Implements `Equatable`, `Hashable`, `Sendable`, `ExpressibleByArrayLiteral`, `ExpressibleByStringLiteral`, `CustomStringConvertible`
- Contains `parts: [String]` array for hierarchical keys
- Supports string literals: `"users"` or array literals: `["user", userId]`
- `description` property returns parts joined by "/" for logging

**QueryOptions** (Sources/SwiftQuery/Query.swift:28-39)
- Configuration struct for query behavior
- `staleTime: TimeInterval` - How long cached data is fresh (default: 0)
- `gcTime: TimeInterval` - Garbage collection time (default: 300, not yet implemented)
- `refetchOnAppear: Bool` - Whether to refetch on view appearance (default: true)

**CacheEntry<Value>** (Sources/SwiftQuery/Query.swift:41-58)
- Internal struct holding cached data and metadata
- Contains `data: Value?`, `error: Error?`
- Tracks `readAt: Date` and `updatedAt: Date` for staleness calculations
- Not exposed publicly; managed by QueryClientStore

**QueryClientStore** (Sources/SwiftQuery/Query.swift:60-109)
- Actor-based storage layer for thread-safe cache management
- Manages watchers (invalidation streams) and cache entries
- Key methods:
  - `streams(queryKey:)` - Get watchers for a query
  - `storeStream(queryKey:id:continuation:)` - Store a watcher continuation
  - `removeStream(queryKey:id:)` - Remove a watcher
  - `entry(queryKey:as:)` - Read cache entry
  - `withEntry(queryKey:as:now:handler:)` - Atomic cache read/update
  - `removeEntry(queryKey:)` - Clear cache
- Data: `watchers: [QueryKey: [UUID: AsyncStream<Void>.Continuation]]`, `cache: [QueryKey: Any]`

**QueryClient** (Sources/SwiftQuery/Query.swift:111-241)
- Singleton cache manager (`QueryClient.shared`)
- Injectable `clock: Clock` for testability
- Uses `OSAllocatedUnfairLock<[QueryKey: Task<any Sendable, Error>]>` for in-flight request deduplication
- Key methods:
  - `invalidate(_:fileId:)` - Clear cache and notify watchers
  - `createSyncStream(queryKey:)` - Create invalidation stream
  - `fetch(queryKey:options:forceRefresh:fileId:queryFn:)` - Core fetch with caching
- Returns `(isFresh: Bool, result: Result<Value, Error>)` from fetch
- Updates `entry.readAt` on cache hits to track freshness
- In-flight request deduplication: if a request is already running for a query key, subsequent requests wait for the same task instead of making new ones

**QueryBox<Value>** (Sources/SwiftQuery/Query.swift:243-247)
- Observable state container binding query data to UI
- Contains `data: Value?`, `isLoading: Bool`, `error: Error?`

**QueryObserver<Value>** (Sources/SwiftQuery/Query.swift:249-301)
- MainActor-isolated, `@Observable` class for query state management
- Contains `box: QueryBox<Value>` for UI binding
- `queryKey: QueryKey?` property with didSet observer that triggers subscription
- Subscribes to invalidation streams via `subscribe(queryKey:)`
- When cache invalidated, calls `syncStateWithCache(queryKey:now:)` to update UI
- Cleans up streams on deinit by canceling task

**UseQuery<Value>** (Sources/SwiftQuery/Query.swift:303-322)
- Property wrapper for query state in views
- Wraps `@State private var observer: QueryObserver<Value>`
- `wrappedValue: Value?` - Direct data access
- `projectedValue: Binding<QueryObserver<Value>>` - Access to observer for `.query()` modifier
- Accepts optional initial `queryKey` in initializer

**QueryModifier<Value>** (Sources/SwiftQuery/Query.swift:348-467)
- ViewModifier implementing fetch lifecycle
- Orchestrates stale-while-revalidate pattern
- First fetch returns immediately with cache/loading
- Second fetch runs in background if data is not fresh
- Background fetch errors are silently ignored
- Uses BatchExecutor to deduplicate concurrent requests
- Lifecycle: `.task(id: queryKey)` updates observer's queryKey if changed, and `.onAppear` with `refetchOnAppear` option
- On successful fetch, calls `onCompleted` callback and yields to all watchers
- `onCompleted` can be called twice: once for cached data (if fresh) and once for refreshed data

**Boundary<Content, Value>** (Sources/SwiftQuery/Query.swift:470-524)
- Conditional view renderer for query states
- Three overloads: content-only, content+fallback, content+fallback+errorFallback
- All marked with `@_disfavoredOverload` to allow custom extensions to take precedence
- Renders based on: data exists → content, error exists → errorFallback, loading → fallback
- Default fallback is `ProgressView()`

**BatchExecutor** (Sources/SwiftQuery/Query.swift:526-553)
- Actor deduplicating concurrent requests for same query key
- Tracks tasks per query key in queue
- Default 0.1s debounce window to collect concurrent requests
- All queued requests resolve after first task completes
- Clears queue after execution completes

### Data Flow

#### Query Execution Flow:
1. View declares: `@UseQuery<User> var user`
2. View uses: `Boundary($user) { ... }.query($user, queryKey: ...) { ... }`
3. `.query()` modifier attaches `QueryModifier` to view
4. `.task(id: queryKey)` triggers when queryKey changes:
   - Sets `observer.queryKey` if it changed (triggers subscription via didSet)
   - Calls `fetch(queryKey:fileId:)`
5. `.onAppear` triggers if `refetchOnAppear: true`:
   - Calls `fetch(queryKey:fileId:)` in a Task
6. `QueryModifier.fetch()`:
   - Calls `batchExecutor.batchExecution()` to deduplicate concurrent requests
   - Calls `queryClient.fetch(forceRefresh: false)`:
     - Checks in-flight tasks first; waits for existing task if one exists
     - If cache exists and not forced: updates `entry.readAt` and returns cached data
     - If cache fresh: returns (`isFresh: true`, cached data)
     - If cache stale: returns (`isFresh: false`, cached data)
     - If cache missing or forced: fetches new data, stores in cache, returns (`isFresh: true`, new data)
   - On success: updates `observer.box.data` and `observer.box.error`, yields to all watchers, calls `onCompleted` if `isFresh`
   - On failure: updates `observer.box.error`
   - If `!isFresh`, runs second fetch in background with `forceRefresh: true`:
     - On success: updates `observer.box.data`, yields to watchers, calls `onCompleted`
     - On failure: silently ignores error (stale-while-revalidate)
7. `QueryObserver.subscribe(queryKey:)` creates invalidation stream:
   - Cancels previous task if exists
   - Syncs state with cache immediately
   - Listens for invalidation events and syncs state on each event
8. When cache invalidated via `queryClient.invalidate()`:
   - Cache entry removed from store
   - All watchers' continuations yield `()`
   - All subscribed `QueryObserver` instances call `syncStateWithCache()` to update UI
9. `Boundary` renders content based on `observer.box` state

#### Cache Invalidation Flow:
1. Call `await queryClient.invalidate(queryKey)`
2. Remove cache entry from `QueryClientStore`
3. Get all watchers (stream continuations) for the query key
4. Each continuation yields `()` to signal watchers
5. All `QueryObserver` tasks wake and call `syncStateWithCache()`
6. `observer.box` updates, triggering UI redraw

### Key Patterns

**Stale-While-Revalidate**
- `staleTime`: How long cached data is considered fresh (default: 0)
- Freshness check: `(now - entry.readAt) < staleTime` (Sources/SwiftQuery/Query.swift:174)
- When data is stale but cached:
  1. First fetch returns cached value immediately (`isFresh: false`)
  2. Second fetch runs in background to get fresh data (Sources/SwiftQuery/Query.swift:438-464)
  3. Background fetch updates cache and UI on success
  4. Background fetch errors are silently ignored to preserve stale data (Sources/SwiftQuery/Query.swift:459-463)

**Request Deduplication via In-Flight Tasks**
- QueryClient maintains `OSAllocatedUnfairLock<[QueryKey: Task<any Sendable, Error>]>` for in-flight request tracking (Sources/SwiftQuery/Query.swift:114)
- When fetch is called and a task is already running for the query key:
  1. Subsequent requests wait for the existing task (Sources/SwiftQuery/Query.swift:180-192)
  2. All requests share the result of the single execution
  3. Task is removed from in-flight map after completion (Sources/SwiftQuery/Query.swift:216-218, 228-230)
- Prevents duplicate network calls at QueryClient level (lower level than BatchExecutor)

**Request Deduplication via BatchExecutor**
- Concurrent requests for same query key are batched together at view level (Sources/SwiftQuery/Query.swift:526-553)
- First request waits for debounce window (default 0.1s) to collect more requests
- All requests in the batch share the result of a single execution
- Queue is cleared after execution completes (Sources/SwiftQuery/Query.swift:551)
- Prevents duplicate fetches when multiple views mount simultaneously

**Invalidation Streams**
- Each query key can have multiple watchers (different views observing same data)
- Uses `AsyncStream<Void>` to notify all watchers when cache is invalidated
- Watchers registered via `createSyncStream(queryKey:)` (Sources/SwiftQuery/Query.swift:140-150)
- Stream continuations stored in `QueryClientStore.watchers`
- Automatic cleanup on `QueryObserver` deinit via continuation termination handler (Sources/SwiftQuery/Query.swift:144-148)
- Each observer has a unique UUID to prevent conflicts (Sources/SwiftQuery/Query.swift:141)

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

**MutationBox** (Sources/SwiftQuery/Mutation.swift:4-7)
- Public struct for mutation state
- Contains `public fileprivate(set) var isRunning: Bool` and `public fileprivate(set) var error: Error?`
- Conforms to `Sendable`

**MutationController** (Sources/SwiftQuery/Mutation.swift:9-68)
- MainActor-isolated struct for executing write operations
- Wraps `@Binding private var box: MutationBox` for state updates
- `isLoading: Bool` computed property that returns `box.isRunning`
- Key methods:
  - `asyncPerform(_ mutationFn:, onCompleted:) -> Result<Void, Error>` - Void mutation, onCompleted receives `QueryClient`
  - `asyncPerform<T>(_ operation:, onCompleted:) -> Result<T, Error>` - Typed mutation returning value, onCompleted receives value and `QueryClient`
  - `reset()` - Clear error and loading state
- Both `asyncPerform` methods are `@discardableResult`
- `onCompleted` callback for void mutation is async: `@Sendable (QueryClient) async -> Void`
- `onCompleted` callback for typed mutation is sync: `@Sendable (T, QueryClient) -> Void`

**UseMutation** (Sources/SwiftQuery/Mutation.swift:70-85)
- Property wrapper for mutations in views
- MainActor-isolated struct conforming to `DynamicProperty`
- `@State private var box = MutationBox()` for state management
- `wrappedValue: MutationController` - Access to controller
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
