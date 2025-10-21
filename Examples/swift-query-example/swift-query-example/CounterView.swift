import SwiftUI
import SwiftQuery

struct ServerResponse: Sendable {
    let id: String
    let value: Int
}

private final actor ServerDatabase {
    fileprivate static let shared = ServerDatabase()
    
    var value: Int = 5
    
    func add5() {
        value += 5
    }
}

struct CounterView: View {
    @UseQuery<ServerResponse> var response
    @State private var showBottomSheet = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.blue.opacity(0.1), .purple.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                VStack(spacing: 8) {
                    Text("Main View")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)

                    Text("Server returns value: 5")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }

                VStack(spacing: 24) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 24)
                            .fill(.ultraThinMaterial)
                            .shadow(color: .black.opacity(0.1), radius: 20, x: 0, y: 10)

                        Boundary($response) { response in
                            VStack(spacing: 8) {
                                Text("\(response.value)")
                                    .font(.system(size: 96, weight: .bold, design: .rounded))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.blue, .purple],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                Text("ID: \(response.id)")
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        } fallback: {
                            ProgressView()
                                .scaleEffect(1.5)
                        } errorFallback: { error in
                            VStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.red)
                                Text(error.localizedDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .query($response, queryKey: "server-response", options: QueryOptions(staleTime: 0)) {
                            try await Task.sleep(for: .milliseconds(300))
                            let value = await ServerDatabase.shared.value
                            return ServerResponse(id: "id", value: value)
                        }
                    }
                    .frame(height: 200)
                }
                .padding(32)
            }
        }
        .sheet(isPresented: $showBottomSheet) {
            StaleWhileRevalidateSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .overlay(alignment: .bottomTrailing) {
            Button {
                showBottomSheet = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Cache Demo")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
            }
            .padding(24)
        }
    }
}

struct StaleWhileRevalidateSheet: View {
    @UseQuery<ServerResponse> var response
    @State private var fetchTimestamp: Date?
    @State private var showSecondSheet = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.orange.opacity(0.1), .pink.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Stale-While-Revalidate")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    VStack(spacing: 4) {
                        Text("Server returns value: 10")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.orange)

                        Text("Shows stale value (5) instantly, then updates to fresh value (10)")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                }
                .padding(.top, 20)

                VStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.ultraThinMaterial)
                            .shadow(color: .black.opacity(0.05), radius: 15, x: 0, y: 5)

                        Boundary($response) { response in
                            VStack(spacing: 8) {
                                Text("\(response.value)")
                                    .font(.system(size: 72, weight: .bold, design: .rounded))
                                    .foregroundStyle(
                                        LinearGradient(
                                            colors: [.orange, .pink],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )

                                Text("ID: \(response.id)")
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)

                                VStack(spacing: 4) {
                                    if let timestamp = fetchTimestamp {
                                        Text("Fetched at \(timestamp.formatted(date: .omitted, time: .standard))")
                                            .font(.system(size: 12, weight: .medium, design: .rounded))
                                            .foregroundStyle(.tertiary)
                                    } else {
                                        Text("Fetched at 00:00:00 AM")
                                            .font(.system(size: 12, weight: .medium, design: .rounded))
                                            .foregroundStyle(.tertiary)
                                            .opacity(0)
                                    }
                                }
                                .frame(height: 16)
                            }
                            .frame(height: 140)
                        } fallback: {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .scaleEffect(1.5)
                                Text("Loading...")
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(height: 140)
                        } errorFallback: { error in
                            VStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.red)
                                Text(error.localizedDescription)
                                    .font(.system(size: 12, weight: .medium, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(height: 140)
                        }
                        .query($response, queryKey: "server-response", options: QueryOptions(staleTime: 0)) {
                            let startTime = Date()

                            await ServerDatabase.shared.add5()
                            let value = await ServerDatabase.shared.value
                            try await Task.sleep(for: .milliseconds(1000))

                            fetchTimestamp = startTime

                            return ServerResponse(id: "id", value: value)
                        }
                    }
                    .frame(height: 200)

                    VStack(spacing: 12) {
                        InfoRow(
                            icon: "server.rack",
                            title: "Shared Cache",
                            description: "Both views use same query key but fetch different values"
                        )

                        InfoRow(
                            icon: "clock.badge.checkmark",
                            title: "Stale Time: 0",
                            description: "Data is always stale, triggers immediate revalidation"
                        )

                        InfoRow(
                            icon: "arrow.triangle.2.circlepath",
                            title: "Stale-While-Revalidate",
                            description: "Shows stale value (5) instantly, then updates to fresh (10) after 1s"
                        )
                    }
                    .padding(.horizontal, 20)
                }

                Spacer()

                Button {
                    showSecondSheet = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Open Second Sheet")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.1), radius: 10, x: 0, y: 5)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showSecondSheet) {
            SecondBottomSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

struct SecondBottomSheet: View {
    @UseQuery<ServerResponse> var response
    @State private var fetchTimestamp: Date?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.green.opacity(0.1), .cyan.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("Second Bottom Sheet")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)

                    VStack(spacing: 4) {
                        Text("Server returns value: 15")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.green)

                        Text("Demonstrates third query using same cache")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                }
                .padding(.top, 20)

                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.05), radius: 15, x: 0, y: 5)

                    Boundary($response) { response in
                        VStack(spacing: 8) {
                            Text("\(response.value)")
                                .font(.system(size: 72, weight: .bold, design: .rounded))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.green, .cyan],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )

                            Text("ID: \(response.id)")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)

                            VStack(spacing: 4) {
                                if let timestamp = fetchTimestamp {
                                    Text("Fetched at \(timestamp.formatted(date: .omitted, time: .standard))")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.tertiary)
                                } else {
                                    Text("Fetched at 00:00:00 AM")
                                        .font(.system(size: 12, weight: .medium, design: .rounded))
                                        .foregroundStyle(.tertiary)
                                        .opacity(0)
                                }
                            }
                            .frame(height: 16)
                        }
                        .frame(height: 140)
                    } fallback: {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Loading...")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .frame(height: 140)
                    } errorFallback: { error in
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.red)
                            Text(error.localizedDescription)
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                        .frame(height: 140)
                    }
                    .query($response, queryKey: "server-response", options: QueryOptions(staleTime: 0)) {
                        let startTime = Date()

                        await ServerDatabase.shared.add5()
                        let value = await ServerDatabase.shared.value
                        try await Task.sleep(for: .milliseconds(1000))

                        fetchTimestamp = startTime

                        return ServerResponse(id: "id", value: value)
                    }
                }
                .frame(height: 200)
                .padding(.horizontal, 20)

                Spacer()
            }
        }
    }
}

struct InfoRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)

                Text(description)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

