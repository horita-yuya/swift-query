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

**QueryClient** (Sources/SwiftQuery/Query.swift:118)
- Singleton cache manager (`QueryClient.shared`)
- Handles all fetch operations with deduplication via in-flight task tracking
- Thread-safe cache using `OSAllocatedUnfairLock`
- Supports cache invalidation with stream-based notifications

**QueryClientStore** (Sources/SwiftQuery/Query.swift:87)
- Actor-based storage layer
- Manages watchers (invalidation streams) and cache entries
- Nonisolated access to cache for performance

**CacheEntry** (Sources/SwiftQuery/Query.swift:58)
- Contains `data`, `error`, and `inFlight` task
- Tracks `metadata` (readAt/updatedAt) for staleness calculations
- `isFresh()` determines if data needs refetching based on `staleTime`

**BatchExecutor** (Sources/SwiftQuery/Query.swift:453)
- Debounces concurrent requests for the same query key
- Prevents duplicate fetches when multiple views request same data simultaneously
- Default 0.1s debounce window

### Data Flow

1. **Query Execution**: View uses `@UseQuery` property wrapper + `.query()` modifier
2. **Cache Check**: QueryClient checks for fresh cached data or in-flight requests
3. **Fetch Strategy**:
   - If stale data exists, returns it immediately then refetches in background
   - If no data, shows loading state and fetches
4. **Invalidation**: `QueryClient.invalidate()` removes cache and notifies all watchers
5. **Re-render**: Watchers trigger re-execution, updating bound `QueryBox`

### Key Patterns

**Stale-While-Revalidate**
- `staleTime`: How long cached data is considered fresh (default: 0)
- When data is stale but exists, it's returned immediately while a background refetch occurs
- Second fetch updates cache but doesn't override UI with errors (Sources/SwiftQuery/Query.swift:393-397)

**In-Flight Request Deduplication**
- Concurrent fetches for same key share the same `Task` (Sources/SwiftQuery/Query.swift:182-201)
- Prevents redundant network requests
- All callers wait for the shared task to complete

**Invalidation Streams**
- Each query can have multiple watchers (different views)
- `AsyncStream<Void>` notifies all watchers when cache is invalidated
- Watchers automatically clean up on termination (Sources/SwiftQuery/Query.swift:148-152)

### Testing Utilities

**Clock Protocol** (Sources/SwiftQuery/Clock.swift:3)
- Protocol for time-based operations
- Enables deterministic testing by injecting mock clocks
- QueryClient accepts custom clock in init

**Test Actors**
- Use actor-based counters and gates for concurrency testing
- See BatchExecutorTests.swift and QueryTests.swift for patterns

## Usage Pattern

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

## Mutations

**UseMutation** (Sources/SwiftQuery/Mutation.swift:67)
- Property wrapper for write operations
- Provides `MutationController` with `asyncPerform()` methods
- Callback receives `QueryClient` for manual invalidation after mutations

```swift
@UseMutation var updateUser

Button("Update") {
    Task {
        await updateUser.asyncPerform {
            try await api.updateUser(...)
        } onCompleted: { queryClient in
            await queryClient.invalidate(["user", userId])
        }
    }
}
```

# CODE STYLE
## TEST
- Use swift-testing
- Group by @Suite
- Each @Test func name MUST be snakecase.
