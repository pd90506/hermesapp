import HermesProtocol
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FakeTransportTests {
    @Test func cancellationUnregistersAWaitingReader() async throws {
        let transport = FakeTransport()
        let reader = Task { await transport.readSent() }
        #expect(await eventually { transport.pendingReaders == 1 })
        reader.cancel()
        #expect(await reader.value == nil)
        #expect(transport.pendingReaders == 0)
        // A cancelled reader must not steal the next test's/client's frame.
        try await transport.send(#"{"method":"after-cancel"}"#)
        #expect(await transport.nextSent()["method"] == "after-cancel")
    }

    @Test func cancellationBeforeRegistrationDoesNotWait() async {
        let transport = FakeTransport()
        let reader = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await transport.readSent()
        }
        #expect(await reader.value == nil)
        #expect(transport.pendingReaders == 0)
    }

    @Test func closeWakesReadersAndPreservesAlreadySentFrames() async throws {
        let transport = FakeTransport()
        let reader = Task { await transport.readSent() }
        #expect(await eventually { transport.pendingReaders == 1 })
        await transport.close()
        #expect(await reader.value == nil)
        #expect(transport.pendingReaders == 0)
        #expect(await transport.readSent() == nil)

        let buffered = FakeTransport()
        try await buffered.send(#"{"method":"buffered"}"#)
        await buffered.close()
        #expect(await buffered.nextSent()["method"] == "buffered")
        #expect(await buffered.readSent() == nil)
    }

    @Test func aServerDropWakesReadersButIsNotAClientClose() async {
        let transport = FakeTransport()
        let reader = Task { await transport.readSent() }
        #expect(await eventually { transport.pendingReaders == 1 })
        transport.serverDrops()
        #expect(await reader.value == nil)
        // `isClosed` stays the client's own close, which tests assert on.
        #expect(!transport.isClosed)
    }
}
