import Foundation
import HermesProtocol

/// Streamed text a batch at a time (`StreamedTextQueue`).
extension ChatSession {
    /// The transcript, with the queued text shown first: everything that changes it
    /// other than streamed text goes through here, so it lands after the text that came
    /// before it.
    var current: Transcript {
        get { transcript }
        _modify {
            streamedText.flush()
            yield &transcript
        }
    }

    /// Applies a batch of streamed text in one change to the transcript.
    func show(_ events: [GatewayEvent]) {
        var next = transcript
        for event in events { next.apply(event) }
        transcript = next
    }
}
