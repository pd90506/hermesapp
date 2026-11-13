// The macOS UI tests' mouse in the test VM: drags with the system's own mouse events.
// XCUI's synthesized drags start no drag session from the Dock's stacks, and a UI test
// runner may not post events itself (it has no Accessibility access); processes that
// scripts/vm-test.sh starts in the VM do (VM, 2026-10-29).
//
// A test writes "drag x1 y1 x2 y2" (screen points, top-left origin) to the request
// file; this drags, then deletes the file, which tells the test it is done.
// "trace <out> x1 y1 x2 y2 ..." clicks each point in turn, 1.5 s apart, while it samples
// the app's windows' frames every few milliseconds into <out>.tsv (seconds, window
// number, title, x, y, width, height; and "seconds click n" at each click).
//
//   swiftc -O scripts/vm-mouse.swift -o vm-mouse && ./vm-mouse   (vm-test.sh does this)
import CoreGraphics
import Foundation

let request = "/tmp/hermesapp-uitest-mouse"
setbuf(stdout, nil)

func post(_ type: CGEventType, _ point: CGPoint, pause: useconds_t = 200_000) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
        .post(tap: .cghidEventTap)
    usleep(pause)
}

func drag(from start: CGPoint, to end: CGPoint) {
    post(.mouseMoved, start)
    post(.leftMouseDown, start, pause: 300_000)
    for step in 1...40 {
        let t = CGFloat(step) / 40
        post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
             pause: 30_000)
    }
    post(.leftMouseDragged, end, pause: 500_000)
    post(.leftMouseUp, end)
}

func click(_ point: CGPoint) {
    post(.mouseMoved, point, pause: 50_000)
    post(.leftMouseDown, point, pause: 60_000)
    post(.leftMouseUp, point, pause: 0)
}

/// Clicks `points` while sampling the app's window frames. (A screen recording in the VM,
/// `screencapture -v`, skips the frames of a window resize: VM, 2026-11-13.)
func trace(to out: String, clicking points: [CGPoint]) {
    let seconds = 2 + Double(points.count) * 1.5
    var rows: [String] = []
    let start = Date()
    var next = 0
    var nextClick = 1.0
    while Date().timeIntervalSince(start) < seconds {
        let t = Date().timeIntervalSince(start)
        if next < points.count, t >= nextClick {
            click(points[next])
            rows.append(String(format: "%.4f\tclick\t%d", Date().timeIntervalSince(start), next))
            next += 1
            nextClick += 1.5
        }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let now = Date().timeIntervalSince(start)
        for w in list where (w[kCGWindowOwnerName as String] as? String) == "Talaria"
            && (w[kCGWindowLayer as String] as? Int) == 0 {
            let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
            rows.append(String(format: "%.4f\t%d\t%@\t%.0f\t%.0f\t%.0f\t%.0f", now,
                               w[kCGWindowNumber as String] as? Int ?? 0, (w[kCGWindowName as String] as? String) ?? "",
                               b["X"] ?? 0, b["Y"] ?? 0, b["Width"] ?? 0, b["Height"] ?? 0))
        }
        usleep(2_000)
    }
    try? rows.joined(separator: "\n").write(toFile: out + ".tsv", atomically: true, encoding: .utf8)
}

while true {
    if let line = try? String(contentsOfFile: request, encoding: .utf8) {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        let n = parts.dropFirst().compactMap(Double.init)
        if parts.first == "drag", parts.count == 5, n.count == 4 {
            drag(from: CGPoint(x: n[0], y: n[1]), to: CGPoint(x: n[2], y: n[3]))
            print("dragged \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else if parts.first == "trace", parts.count >= 2, n.count == parts.count - 2, n.count % 2 == 0 {
            let points = stride(from: 0, to: n.count, by: 2).map { CGPoint(x: n[$0], y: n[$0 + 1]) }
            trace(to: parts[1], clicking: points)
            print("traced \(parts[1])")
        } else {
            print("unknown request: \(line)")
        }
        try? FileManager.default.removeItem(atPath: request)
    }
    usleep(100_000)
}
