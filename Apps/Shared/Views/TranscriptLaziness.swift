import SwiftUI

/// Draws the chat's blocks only near the screen; the rest are clear space of the height
/// they last had (`NearScreen`), so the scroller's knob keeps its size and place.
///
/// Every row built and kept made each frame of a scroll walk the whole chat's view graph:
/// in a long chat 35–100 ms a frame on the user's Mac, with the app's own code under 2% of
/// it (Instruments, 2026-10-21). A lazy stack draws only what is near the screen too, but
/// guesses the height of the rows it has not drawn yet and corrects the guess as they come
/// in, so the knob jumped every few lines (`TranscriptStack`). Here each block is drawn at
/// least once, when the chat builds it (`TranscriptWindow`), and keeps the height it had.
///
/// What a row remembers that changes its height (a fold opened) lives in `RowMemory`, not
/// in the row, so a block drawn again comes back as it was left.
@MainActor @Observable final class TranscriptLaziness {
    /// The column's width once a resize has settled. A block last drawn at another width
    /// is drawn again to take its height at this one.
    private(set) var settledWidth: CGFloat?
    @ObservationIgnored private var pendingWidth: Task<Void, Never>?

    /// How far above and below the visible area a block starts to be drawn: before it
    /// scrolls in.
    nonisolated static let margin: CGFloat = 1200
    /// How far a drawn block goes before it is cleared again: farther than `margin`, so a
    /// scroll back and forth over a few lines does not draw the same rows again and again.
    nonisolated static let keepMargin: CGFloat = 2400
    /// How long the width stays put before a resize counts as settled.
    nonisolated static let settleDelay = Duration.milliseconds(300)

    /// The column's width changed (a resize, a turn to landscape).
    func widthChanged(_ width: CGFloat) {
        if settledWidth == nil {
            settledWidth = width
            return
        }
        pendingWidth?.cancel()
        pendingWidth = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.settledWidth = width
        }
    }
}

/// What the rows of one chat remember about themselves while they are not drawn
/// (`TranscriptLaziness`): the folds the user opened or closed, by the fold's key.
@MainActor @Observable final class RowMemory {
    private var values: [String: Any] = [:]

    /// What was saved under `key`, if anything was (a saved nil included).
    func saved<Value>(_ key: String, as type: Value.Type = Value.self) -> Saved<Value>? {
        values[key] as? Saved<Value>
    }

    func save<Value>(_ key: String, _ value: Value) {
        values[key] = Saved(value: value)
    }

    struct Saved<Value> { let value: Value }
}

extension EnvironmentValues {
    /// Draws the chat's blocks only near the screen, when set (`TranscriptLaziness`).
    @Entry var transcriptLaziness: TranscriptLaziness? = nil
    /// Where the chat's rows keep what they remember (`RowMemory`), when set.
    @Entry var rowMemory: RowMemory? = nil
}

/// A row's state that outlives the row (`RowMemory`): what the chat's memory holds under
/// `key`, else the view's own state, as `@State` would be without a memory.
@MainActor @propertyWrapper struct Remembered<Value>: DynamicProperty {
    @Environment(\.rowMemory) private var memory
    @State private var local: Value
    private let key: String

    init(wrappedValue: Value, _ key: String) {
        _local = State(initialValue: wrappedValue)
        self.key = key
    }

    var wrappedValue: Value {
        get {
            memory?.saved(key, as: Value.self)?.value ?? local
        }
        nonmutating set {
            local = newValue
            memory?.save(key, newValue)
        }
    }

    var projectedValue: Binding<Value> {
        Binding(get: { wrappedValue }, set: { wrappedValue = $0 })
    }
}

extension View {
    /// Draws this block only near the screen, when the chat asks for it
    /// (`TranscriptLaziness`).
    func nearScreen() -> some View {
        modifier(NearScreen())
    }
}

/// A block drawn while it is near the screen, and clear space of its last height while
/// it is not. Drawn when it has no height yet or its height was taken at another width.
private struct NearScreen: ViewModifier {
    @Environment(\.transcriptLaziness) private var laziness
    /// Whether the block is drawn: since the area around it (`TranscriptLaziness.margin`)
    /// came on screen, until the wider one (`keepMargin`) left it. Nil until its first
    /// place is known.
    @State private var isNear: Bool?
    @State private var measured: CGSize?

    /// How far the block is from the visible area (`TranscriptLaziness.margin`,
    /// `keepMargin`).
    enum Distance: Equatable {
        case near, between, far

        init(_ proxy: GeometryProxy) {
            // The scroll view's visible area, in the block's own coordinates.
            guard let visible = proxy.bounds(of: .scrollView) else { self = .near; return }
            let block = CGRect(origin: .zero, size: proxy.size)
            if visible.insetBy(dx: 0, dy: -TranscriptLaziness.margin).intersects(block) {
                self = .near
            } else if visible.insetBy(dx: 0, dy: -TranscriptLaziness.keepMargin).intersects(block) {
                self = .between
            } else {
                self = .far
            }
        }
    }

    func body(content: Content) -> some View {
        if let laziness {
            let isCurrent = measured.map { size in laziness.settledWidth.map { abs($0 - size.width) < 0.5 } ?? true } ?? false
            Group {
                if isNear == false, isCurrent, let measured {
                    Color.clear.frame(height: measured.height)
                } else {
                    content
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { measured = $0 }
                }
            }
            .onGeometryChange(for: Distance.self) { Distance($0) } action: { distance in
                switch distance {
                case .near: isNear = true
                case .far: isNear = false
                case .between: if isNear == nil { isNear = true }
                }
            }
        } else {
            content
        }
    }
}
