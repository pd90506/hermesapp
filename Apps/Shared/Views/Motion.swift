import SwiftUI

/// The app's animations, in one place: short and subtle, as macOS's own (a sidebar slides
/// in about a quarter of a second, a control's hover state fades in a tenth). With Reduce
/// Motion on, what would slide or move changes at once (`Motion.rail(reduceMotion:)`);
/// fades stay, as the system's do.
enum Motion {
    /// The profile rail hiding or showing, the session list and the chat's card following
    /// it (`MacSidebar`). Nil with Reduce Motion: the panel would still slide.
    static func rail(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : slowed(.snappy(duration: 0.25))
    }

    /// On iPhone, the profiles' drawer sliding over the session list (`ProfileDrawer`).
    /// No bounce: past its place, the panel would come away from the screen's edge.
    static var drawer: Animation { slowed(.smooth(duration: 0.28)) }

    /// How long until the drawer has settled after `drawer` starts.
    static var drawerSettles: Duration { .milliseconds(Int(400 * (scale ?? 1))) }

    /// Controls that show while the pointer is over their content, such as a message's
    /// action bar.
    static var reveal: Animation { slowed(.easeOut(duration: 0.1)) }

    /// One control taking another's place, such as Stop for Send while a reply runs.
    static var swap: Animation { slowed(.snappy(duration: 0.2)) }

    /// The chat's scroll-to-bottom button coming and going: in from a little larger,
    /// out to a little smaller, as Desktop's (`thread-jump-button`, 200 ms in).
    static var jumpButton: Animation { slowed(.smooth(duration: 0.2)) }

    /// The chat scrolling down to its newest message from that button.
    static var scrollToEnd: Animation { slowed(.smooth(duration: 0.35)) }

    /// Under UI tests, `HERMES_UITEST_MOTION_SCALE` times slower, so a test can take
    /// screenshots part way through.
    private static func slowed(_ animation: Animation) -> Animation {
        scale.map { animation.speed(1 / $0) } ?? animation
    }

    private static var scale: Double? {
        #if DEBUG
        testScale
        #else
        nil
        #endif
    }

    #if DEBUG
    private static let testScale: Double? = ProcessInfo.processInfo.environment["HERMES_UITEST_MOTION_SCALE"]
        .flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
    #endif
}
