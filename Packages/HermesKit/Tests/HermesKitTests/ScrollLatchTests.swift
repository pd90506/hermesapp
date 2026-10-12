import HermesKit
import Testing

@Suite struct ScrollLatchTests {
    /// Which of `events` start a gesture, fed to one latch in order.
    static func starts(_ events: [(ScrollLatch.Event, Double)], gap: Double = 0.3) -> [Bool] {
        var latch = ScrollLatch(gap: gap)
        return events.map { latch.startsGesture($0.0, at: $0.1) }
    }

    @Test func aTrackpadGestureIsOneGestureThroughItsMomentum() {
        // Momentum long after the fingers lifted is still that gesture.
        #expect(Self.starts([(.began, 0), (.continued, 0.1), (.continued, 2), (.began, 3)])
            == [true, false, false, true])
    }

    @Test func wheelTicksGroupByTheirPauses() {
        #expect(Self.starts([(.wheel, 0), (.wheel, 0.2), (.wheel, 0.45), (.wheel, 1)])
            == [true, false, false, true])
    }

    @Test func aContinuationWithNothingBeforeItStartsOne() {
        #expect(Self.starts([(.continued, 5)]) == [true])
    }
}
