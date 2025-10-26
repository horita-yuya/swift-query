import SwiftUI

public struct Boundary<Content: View, Value: Sendable>: View {
    @Binding private var observer: QueryObserver<Value>
    private let content: (Value) -> Content
    private let fallback: (() -> AnyView)?
    private let errorFallback: ((Error) -> AnyView)?

    @_disfavoredOverload
    public init(
        _ observer: Binding<QueryObserver<Value>>,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self._observer = observer
        self.content = content
        self.fallback = nil
        self.errorFallback = nil
    }

    @_disfavoredOverload
    public init(
        _ observer: Binding<QueryObserver<Value>>,
        @ViewBuilder content: @escaping (Value) -> Content,
        @ViewBuilder fallback: @escaping () -> some View
    ) {
        self._observer = observer
        self.content = content
        self.fallback = { AnyView(fallback()) }
        self.errorFallback = nil
    }

    @_disfavoredOverload
    public init(
        _ observer: Binding<QueryObserver<Value>>,
        @ViewBuilder content: @escaping (Value) -> Content,
        @ViewBuilder fallback: @escaping () -> some View,
        @ViewBuilder errorFallback: @escaping (Error) -> some View
    ) {
        self._observer = observer
        self.content = content
        self.fallback = { AnyView(fallback()) }
        self.errorFallback = { error in AnyView(errorFallback(error)) }
    }
    
    public var body: some View {
        if let value = observer.box.data {
            content(value)
        } else if let error = observer.box.error, let errorFallback = errorFallback {
            errorFallback(error)
        } else if let fallback = fallback {
            fallback()
        } else {
            // This is required because onAppear or task is not called in EmptyView
            ProgressView()
        }
    }
}
