# swift-query

A Data and State Manager library that brings [TanStack Query's](https://github.com/TanStack/query) powerful data fetching and caching patterns to SwiftUI. Manage asynchronous queries with automatic caching, invalidation, and UI updates.

## Installation

### Swift Package Manager

Add swift-query to your project using Xcode:

1. File > Add Package Dependencies...
2. Enter the repository URL: `https://github.com/horita-yuya/swift-query`
3. Select the version you want to use

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/horita-yuya/swift-query.git", from: "1.0.1")
]
```

Then add `SwiftQuery` to your target dependencies:

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "SwiftQuery", package: "swift-query")
    ]
)
```

**Platform Requirements:**
- iOS 26+
- macOS 15+
- Swift 6.2+

## Motivation

In SwiftUI, fetching data from APIs often leads to repetitive boilerplate code. You need to:
- Manage loading states manually with `@State` variables
- Handle errors and show appropriate UI
- Prevent duplicate network requests when views re-render
- Cache data to avoid unnecessary fetches
- Invalidate stale data and refetch when needed

**swift-query** solves these problems by providing a declarative, composable way to fetch and cache data with built-in support for:
- **Automatic caching** - Data is cached by query keys and reused across views
- **Stale-while-revalidate** - Show cached data instantly while fetching fresh data in the background
- **Request deduplication** - Multiple views requesting the same data share a single network call
- **Cache invalidation** - Easily invalidate and refetch data after mutations
- **Loading and error states** - Built-in UI patterns for handling async states

## Quick Example

Here's the problem swift-query solves. Without it, you'd write:

```swift
struct UserView: View {
    @State private var user: User?
    @State private var isLoading = false
    @State private var error: Error?

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let error {
                Text("Error: \(error.localizedDescription)")
            } else if let user {
                Text(user.name)
            }
        }
        .task {
            isLoading = true
            do {
                user = try await fetchUser()
            } catch {
                self.error = error
            }
            isLoading = false
        }
    }
}
```

With swift-query, it becomes:

```swift
import SwiftQuery

struct UserView: View {
    @UseQuery<User> var user

    var body: some View {
        Boundary($user) { user in
            Text(user.name)
        } fallback: {
            ProgressView()
        } errorFallback: { error in
            Text("Error: \(error.localizedDescription)")
        }
        .query($user, queryKey: "user") {
            try await fetchUser()
        }
    }
}
```

The data is automatically cached. If another view uses the same query key, it gets the cached data instantly - no duplicate requests!

**Note:** Applications often define a custom `Boundary` initializer via extension with default `fallback` and `errorFallback` views. This makes your code even simpler:

```swift
// Define once in your app
extension Boundary {
    init(
        _ value: Binding<QueryObserver<Value>>,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.init(value, content: content) {
            // Default loading view
            ProgressView()
                .scaleEffect(1.5)
        } errorFallback: { error in
            // Default error view
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.red)
                Text(error.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// Then use it everywhere
struct UserView: View {
    @UseQuery<User> var user

    var body: some View {
        Boundary($user) { user in
            Text(user.name)
        }
        .query($user, queryKey: "user") {
            try await fetchUser()
        }
    }
}
```

Much cleaner! The rest of the examples below use the custom `Boundary` initializer for simplicity.

## Practical Examples

### 1. Basic Query with Cache

Fetch user data and cache it for 60 seconds:

```swift
struct ProfileView: View {
    @UseQuery<User> var user

    var body: some View {
        Boundary($user) { user in
            VStack {
                AsyncImage(url: URL(string: user.avatarURL))
                Text(user.name)
                    .font(.headline)
                Text(user.email)
                    .font(.subheadline)
            }
        }
        .query($user, queryKey: ["user", userId], options: QueryOptions(staleTime: 60)) {
            try await api.fetchUser(id: userId)
        }
    }
}
```

### 2. List with Shared Cache

Multiple views sharing the same query key automatically share the cached data:

```swift
struct PostListView: View {
    @UseQuery<[Post]> var posts

    var body: some View {
        List {
            Boundary($posts) { posts in
                ForEach(posts) { post in
                    NavigationLink(value: post) {
                        PostRow(post: post)
                    }
                }
            }
        }
        .query($posts, queryKey: "posts", options: QueryOptions(staleTime: 30)) {
            try await api.fetchPosts()
        }
    }
}

struct PostRow: View {
    let post: Post
    @UseQuery<PostDetails> var details

    var body: some View {
        Boundary($details) { details in
            VStack(alignment: .leading) {
                Text(details.title)
                    .font(.headline)
                Text("\(details.likes) likes")
                    .font(.caption)
            }
        }
        .query($details, queryKey: ["post", post.id], options: QueryOptions(staleTime: 60)) {
            try await api.fetchPostDetails(id: post.id)
        }
    }
}
```

### 3. Mutations with Cache Invalidation

Update data and automatically invalidate related queries:

```swift
struct EditProfileView: View {
    @UseQuery<User> var user
    @UseMutation var updateUser
    @State private var name = ""

    var body: some View {
        Form {
            Boundary($user) { user in
                TextField("Name", text: $name)
                    .onAppear { name = user.name }

                Button("Save") {
                    Task {
                        await updateUser.asyncPerform {
                            try await api.updateUser(id: user.id, name: name)
                        } onCompleted: { queryClient in
                            // Invalidate user cache to trigger refetch
                            await queryClient.invalidate(["user", user.id])
                        }
                    }
                }
                .disabled(updateUser.box.isRunning)
            }
        }
        .query($user, queryKey: ["user", userId]) {
            try await api.fetchUser(id: userId)
        }
    }
}
```

### 4. Dependent Queries

Fetch data that depends on another query's result:

```swift
struct UserPostsView: View {
    @UseQuery<User> var user
    @UseQuery<[Post]> var posts

    var body: some View {
        VStack {
            Boundary($user) { user in
                Text(user.name)
                    .font(.headline)

                Boundary($posts) { posts in
                    List(posts) { post in
                        PostRow(post: post)
                    }
                }
                .query($posts, queryKey: ["user-posts", user.id]) {
                    // This query only runs after user data is available
                    try await api.fetchUserPosts(userId: user.id)
                }
            }
        }
        .query($user, queryKey: ["user", userId]) {
            try await api.fetchUser(id: userId)
        }
    }
}
```

### 5. Completion Callbacks

React to successful query completion:

```swift
struct DashboardView: View {
    @UseQuery<DashboardData> var dashboard
    @State private var showWelcome = false

    var body: some View {
        Boundary($dashboard) { data in
            ScrollView {
                DashboardContent(data: data)
            }
        }
        .query($dashboard, queryKey: "dashboard") {
            try await api.fetchDashboard()
        } onCompleted: { data in
            // Track analytics, show notifications, etc.
            if data.isFirstLogin {
                showWelcome = true
            }
        }
        .alert("Welcome!", isPresented: $showWelcome) {
            Button("Get Started") { }
        }
    }
}
```

### 6. Stale-While-Revalidate Pattern

Show cached data immediately while fetching fresh data in the background:

```swift
struct NewsView: View {
    @UseQuery<[Article]> var articles

    var body: some View {
        List {
            Boundary($articles) { articles in
                ForEach(articles) { article in
                    ArticleRow(article: article)
                }
            }
        }
        .query($articles, queryKey: "news", options: QueryOptions(staleTime: 0)) {
            // staleTime: 0 means data is always stale
            // Shows cached articles instantly, then fetches fresh data
            try await api.fetchNews()
        }
        .refreshable {
            await QueryClient.shared.invalidate("news")
        }
    }
}
```

## Key Concepts

### Query Keys
Query keys uniquely identify queries. Use strings or string arrays:
- `queryKey: "users"` - Simple key
- `queryKey: ["user", userId]` - Compound key for specific resources

### Stale Time
Controls how long data is considered fresh:
- `staleTime: 60` - Fresh for 60 seconds
- `staleTime: 0` - Always stale (always revalidate in background)

### Boundary Pattern
The `Boundary` component handles three states:
- **Success**: Closure receives the data
- **Loading**: Shows `fallback` view
- **Error**: Shows `errorFallback` view with the error

## License

MIT License
