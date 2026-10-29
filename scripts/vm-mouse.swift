// The macOS UI tests' mouse in the test VM: drags with the system's own mouse events.
// XCUI's synthesized drags start no drag session from the Dock's stacks, and a UI test
// runner may not post events itself (it has no Accessibility access); processes that
// scripts/vm-test.sh starts in the VM do (VM, 2026-10-29).
//
// A test writes "drag x1 y1 x2 y2" (screen points, top-left origin) to the request
// file; this drags, then deletes the file, which tells the test it is done.
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

while true {
    if let line = try? String(contentsOfFile: request, encoding: .utf8) {
        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        let n = parts.dropFirst().compactMap(Double.init)
        if parts.first == "drag", parts.count == 5, n.count == 4 {
            drag(from: CGPoint(x: n[0], y: n[1]), to: CGPoint(x: n[2], y: n[3]))
            print("dragged \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            print("unknown request: \(line)")
        }
        try? FileManager.default.removeItem(atPath: request)
    }
    usleep(100_000)
}
