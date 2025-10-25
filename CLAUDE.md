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

**QueryKey** (Sources/SwiftQuery/Query.swift:5-22)
- Public struct representing query identifiers
- Implements `Equatable`, `Hashable`, `Sendable`, `ExpressibleByArrayLiteral`, `ExpressibleByStringLiteral`
- Contains `parts: [String]` array for hierarchical keys
- Supports string literals: `"users"` or array literals: `["user", userId]`

**QueryOptions** (Sources/SwiftQuery/Query.swift:24-35)
- Configuration struct for query behavior
- `staleTime: TimeInterval` - How long cached data is fresh (default: 0)
- `gcTime: TimeInterval` - Garbage collection time (default: 300, not yet implemented)
- `refetchOnAppear: Bool` - Whether to refetch on view appearance (default: true)

**CacheEntry<Value>** (Sources/SwiftQuery/Query.swift:37-54)
- Internal struct holding cached data and metadata
- Contains `data: Value?`, `error: Error?`
- Tracks `readAt: Date` and `updatedAt: Date` for staleness calculations
- Not exposed publicly; managed by QueryClientStore

**QueryClientStore** (Sources/SwiftQuery/Query.swift:56-103)
- Actor-based storage layer for thread-safe cache management
- Manages watchers (invalidation streams) and cache entries
- Key methods:
  - `streams(queryKey:)` - Get watchers for a query
  - `withEntry(queryKey:as:now:handler:)` - Atomic cache read/update
  - `removeEntry(queryKey:)` - Clear cache
- Data: `watchers: [QueryKey: [UUID: AsyncStream<Void>.Continuation]]`, `cache: [QueryKey: Any]`

**QueryClient** (Sources/SwiftQuery/Query.swift:105-198)
- Singleton cache manager (`QueryClient.shared`)
- Injectable `clock: Clock` for testability
- Key methods:
  - `invalidate(_:fileId:)` - Clear cache and notify watchers
  - `createSyncStream(queryKey:)` - Create invalidation stream
  - `fetch(queryKey:options:forceRefresh:fileId:queryFn:)` - Core fetch with caching
- Returns `(isFresh: Bool, result: Result<Value, Error>)` from fetch
- Updates `entry.readAt` on cache hits to track freshness

**QueryBox<Value>** (Sources/SwiftQuery/Query.swift:200-204)
- Observable state container binding query data to UI
- Contains `data: Value?`, `isLoading: Bool`, `error: Error?`

**QueryObserver<Value>** (Sources/SwiftQuery/Query.swift:206-258)
- MainActor-isolated observable for query state management
- Contains `box: QueryBox<Value>` for UI binding
- Subscribes to invalidation streams via `subscribe(queryKey:)`
- When cache invalidated, calls `syncStateWithCache()` to update UI
- Cleans up streams on deinit

**UseQuery<Value>** (Sources/SwiftQuery/Query.swift:260-279)
- Property wrapper for query state in views
- Wraps `@State private var observer: QueryObserver<Value>`
- `wrappedValue: Value?` - Direct data access
- `projectedValue: Binding<QueryObserver<Value>>` - Access to observer for `.query()` modifier

**QueryModifier<Value>** (Sources/SwiftQuery/Query.swift:305-424)
- ViewModifier implementing fetch lifecycle
- Orchestrates stale-while-revalidate pattern
- First fetch returns immediately with cache/loading
- Second fetch runs in background if data is stale
- Background fetch errors are silently ignored
- Uses BatchExecutor to deduplicate concurrent requests
- Lifecycle: `.task(id: queryKey)` and `.onAppear` hooks

**Boundary<Content, Value>** (Sources/SwiftQuery/Query.swift:427-481)
- Conditional view renderer for query states
- Three overloads: content-only, content+fallback, content+fallback+errorFallback
- Renders based on: data exists → content, error exists → errorFallback, loading → fallback
- Default fallback is `ProgressView()`

**BatchExecutor** (Sources/SwiftQuery/Query.swift:483-510)
- Actor deduplicating concurrent requests for same query key
- Tracks tasks per query key in queue
- Default 0.1s debounce window to collect concurrent requests
- All queued requests resolve after first task completes

### Data Flow

#### Query Execution Flow:
1. View declares: `@UseQuery<User> var user`
2. View uses: `Boundary($user) { ... }.query($user, queryKey: ...) { ... }`
3. `.query()` modifier attaches `QueryModifier` to view
4. `onAppear` or `.task(id: queryKey)` triggers fetch
5. `QueryModifier.fetch()`:
   - Calls `batchExecutor.batchExecution()` to deduplicate concurrent requests
   - Calls `queryClient.fetch(forceRefresh: false)`:
     - If cache fresh: returns cached data (`isFresh: true`)
     - If cache stale/missing: fetches new data (`isFresh: false`)
   - Updates `observer.box` with data/loading/error state
   - If `!isFresh`, runs second fetch in background with `forceRefresh: true`
   - Background fetch updates cache but silently ignores errors (stale-while-revalidate)
6. `QueryObserver` subscribes to invalidation stream for the query key
7. When cache invalidated, stream yields and `observer.syncStateWithCache()` updates UI
8. `Boundary` renders content based on `observer.box` state

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
- Freshness check: `(now - entry.readAt) < staleTime`
- When data is stale but cached:
  1. First fetch returns cached value immediately (`isFresh: false`)
  2. Second fetch runs in background to get fresh data
  3. Background fetch updates cache and UI on success
  4. Background fetch errors are silently ignored (Sources/SwiftQuery/Query.swift:393-397)

**Request Deduplication via BatchExecutor**
- Concurrent requests for same query key are batched together (Sources/SwiftQuery/Query.swift:483-510)
- First request waits for debounce window (default 0.1s) to collect more requests
- All requests in the batch share the result of a single execution
- Prevents duplicate network calls when multiple views request same data

**Invalidation Streams**
- Each query key can have multiple watchers (different views observing same data)
- Uses `AsyncStream<Void>` to notify all watchers when cache is invalidated
- Watchers registered via `createSyncStream(queryKey:)` (Sources/SwiftQuery/Query.swift:114-123)
- Stream continuations stored in `QueryClientStore.watchers`
- Automatic cleanup on `QueryObserver` deinit via continuation termination handler

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
- Observable state container for mutations
- Contains `isRunning: Bool` and `error: Error?`

**MutationController** (Sources/SwiftQuery/Mutation.swift:10-68)
- Controller for executing write operations
- Key methods:
  - `asyncPerform(_ mutationFn:, onCompleted:)` - Void mutation
  - `asyncPerform<T>(_ operation:, onCompleted:)` - Typed mutation returning value
  - `reset()` - Clear error and loading state
- `onCompleted` callback receives `QueryClient` for manual cache invalidation

**UseMutation** (Sources/SwiftQuery/Mutation.swift:70-85)
- Property wrapper for mutations in views
- `wrappedValue: MutationController` - Access to controller
- `projectedValue: Binding<MutationBox>` - Access to state binding

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
            .disabled(updateUser.box.isRunning)

            if let error = updateUser.box.error {
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
