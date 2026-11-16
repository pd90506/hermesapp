import Foundation
import Synchronization

/// The C interface the desktop app loads. See docs/desktop-bridge.md for the contract.
///
/// Strings cross as NUL-terminated UTF-8. Every string the bridge hands out is malloc'd
/// and owned by the caller, who frees it with `hb_free`. Events are delivered through the
/// callback given to `hb_start`, on the thread that runs Swift's main actor.

public typealias HBEventCallback = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void

private let callback = Mutex<HBEventCallback?>(nil)

private func deliver(_ json: String) {
    guard let callback = callback.withLock({ $0 }) else { return }
    // A malloc'd copy (`strdup` is deprecated on Windows): the receiver frees it with `hb_free`.
    let bytes = Array(json.utf8CString)
    guard let copy = malloc(bytes.count)?.bindMemory(to: CChar.self, capacity: bytes.count) else { return }
    copy.initialize(from: bytes, count: bytes.count)
    callback(copy)
}

@MainActor private var bridge: Bridge?

/// The bridge's interface version; bumped on any incompatible change to the contract.
@_cdecl("hb_version")
public func hb_version() -> Int32 { 1 }

/// Registers the event callback and creates the bridge. Call once, before `hb_command`.
@_cdecl("hb_start")
public func hb_start(_ cb: HBEventCallback?) {
    callback.withLock { $0 = cb }
    Task { @MainActor in
        if bridge == nil { bridge = Bridge(emit: deliver) }
    }
}

/// Queues one JSON command; its reply arrives as a `reply` event with the same id.
@_cdecl("hb_command")
public func hb_command(_ json: UnsafePointer<CChar>?) {
    guard let json else { return }
    let text = String(cString: json)
    Task { @MainActor in
        if bridge == nil { bridge = Bridge(emit: deliver) }
        await bridge?.receive(text)
    }
}

/// Runs the work queued on Swift's main actor, then returns.
///
/// On Windows nothing else drains the main queue in a Flutter app, so the app calls this
/// from its main isolate's thread (the platform thread, which is the process's main
/// thread), regularly. On macOS the app's run loop drains it already; the call is harmless.
@_cdecl("hb_pump")
public func hb_pump() {
    _ = RunLoop.main.run(mode: .default, before: .distantPast)
}

/// Allocates `size` bytes for a string the caller passes in (`hb_command`), so the caller
/// needs no allocator of its own. Free it with `hb_free`.
@_cdecl("hb_alloc")
public func hb_alloc(_ size: Int) -> UnsafeMutableRawPointer? {
    malloc(size)
}

/// Frees a string the bridge handed out, or memory from `hb_alloc`.
@_cdecl("hb_free")
public func hb_free(_ pointer: UnsafeMutableRawPointer?) {
    free(pointer)
}
