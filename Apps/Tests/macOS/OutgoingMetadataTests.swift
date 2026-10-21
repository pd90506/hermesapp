import AppKit
import SwiftUI
import Testing

/// Native geometry checks, run in the Mac test VM. Sending… and Queued take the time's
/// slot without resizing it, so Copy does not move when the time replaces them; a
/// failure widens it rather than being cut to the slot's width.
@MainActor
struct OutgoingMetadataTests {
    private func size(_ status: String?, timestamp: Date) -> CGSize {
        NSHostingView(rootView:
            MessageActionBar(isHovering: false, isNewest: true, alignment: .trailing,
                             timestamp: timestamp, outgoingStatus: status) {}
                .fixedSize()).fittingSize
    }

    @Test func pendingStatusUsesTheSameFooterFootprintAsTime() {
        let timestamp = Date()
        let confirmed = size(nil, timestamp: timestamp)
        for status in ["Sending…", "Queued"] {
            let pending = size(status, timestamp: timestamp)
            #expect(abs(pending.width - confirmed.width) < 0.5)
            #expect(abs(pending.height - confirmed.height) < 0.5)
        }
    }

    @Test func failureStatusIsNotCutToTheTimeSlot() {
        let timestamp = Date()
        let confirmed = size(nil, timestamp: timestamp)
        for status in ["Not confirmed · The connection to the gateway was lost.",
                       "Not sent · Not connected to the gateway."] {
            let failed = size(status, timestamp: timestamp)
            #expect(failed.width > confirmed.width + 40)
            #expect(abs(failed.height - confirmed.height) < 0.5)
        }
    }

    @Test func unconfirmedStatusStaysVisibleWithoutHover() {
        let bar = MessageActionBar(isHovering: false, isNewest: false,
                                   timestamp: Date(), outgoingStatus: "Sending…") {}
        #expect(bar.isVisible)
    }
}
