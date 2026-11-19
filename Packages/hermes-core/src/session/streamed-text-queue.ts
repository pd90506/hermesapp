import type { GatewayEvent } from '../client.ts'

/**
 * Streamed text (`message.delta`, `reasoning.delta`) shown a batch at a time, as Desktop
 * shows it (`use-message-stream/index.ts:339-437`; HermesKit's `StreamedTextQueue`): at
 * least 33 ms apart, the gap growing to three times what the last batch cost, at most
 * 250 ms. The first delta of a stream shows at once. The owner shows the queued text
 * (`flush`) before anything else changes the transcript, so events apply in order.
 */
export class StreamedTextQueue {
  static readonly minimumGapMs = 33
  static readonly maximumGapMs = 250

  static gap(afterCostMs: number): number {
    return Math.min(Math.max(StreamedTextQueue.minimumGapMs, afterCostMs * 3), StreamedTextQueue.maximumGapMs)
  }

  private queued: GatewayEvent[] = []
  private timer?: ReturnType<typeof setTimeout>
  private batchStart = 0

  constructor(private readonly show: (events: GatewayEvent[]) => void, private readonly now: () => number = Date.now) {}

  get isEmpty(): boolean {
    return this.queued.length === 0
  }

  append(event: GatewayEvent): void {
    this.queued.push(event)
    if (this.timer !== undefined) return
    // The first delta of a stream shows at once.
    this.showBatch()
  }

  /** Shows the queued text now. */
  flush(): void {
    if (this.queued.length === 0) return
    const events = this.queued
    this.queued = []
    this.show(events)
  }

  /** Stops the batches; queued text is dropped. */
  cancel(): void {
    if (this.timer !== undefined) clearTimeout(this.timer)
    this.timer = undefined
    this.queued = []
  }

  private showBatch(): void {
    this.batchStart = this.now()
    this.flush()
    // The batch's cost is measured until the next timer fires: by then the view has drawn it.
    this.timer = setTimeout(() => {
      const cost = Math.max(0, this.now() - this.batchStart - 1)
      const wait = Math.max(0, StreamedTextQueue.gap(cost) - (this.now() - this.batchStart))
      this.timer = setTimeout(() => {
        this.timer = undefined
        if (this.queued.length > 0) this.showBatch()
      }, wait)
    }, 1)
  }
}
