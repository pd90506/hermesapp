import { RPCError } from '../../protocol/jsonrpc.ts'
import type { GatewayClient } from '../../client.ts'

/**
 * An image a send uploaded (`image.attach_bytes`) but could not take back: its
 * `image.detach` got no answer, because the socket dropped (HermesKit's `StrandedImage`).
 */
export interface StrandedImage {
  /** The runtime session whose queue holds it. */
  sessionID: string
  profile?: string
  path: string
}

/**
 * Stranded images ride with the next turn that starts on their session, from any client
 * (`tui_gateway/prompt_turn.py:147-149`), and the runtime can outlive the outage, so they
 * are detached again as soon as a socket is up, and before any send on their session
 * (HermesKit's `GatewayConnection+StrandedImages`, docs/protocol.md §10.3). Kept per
 * connection, so they survive reopening the chat; at most `limit`, the oldest dropped.
 *
 * Work is per session: each session's detaches run as one flush, its images in parallel,
 * chained after that session's previous flush only. A send waits for its own session's.
 */
export class StrandedImages {
  static readonly limit = 50
  private images: StrandedImage[] = []
  private readonly flushes = new Map<string, Promise<void>>()

  strand(images: readonly StrandedImage[]): void {
    for (const image of images) {
      if (!this.images.some((other) => same(other, image))) this.images.push(image)
    }
    if (this.images.length > StrandedImages.limit) this.images.splice(0, this.images.length - StrandedImages.limit)
  }

  /** Stranded paths of one runtime session, oldest first. */
  paths(sessionID: string): string[] {
    return this.images.filter((image) => image.sessionID === sessionID).map((image) => image.path)
  }

  /** Right after a connect or reattach: one flush per session with stranded images. */
  flushInBackground(client: GatewayClient): void {
    for (const sessionID of new Set(this.images.map((image) => image.sessionID))) void this.startFlush(sessionID, client)
  }

  /**
   * Before a send on `sessionID`: detaches that session's stranded images and waits for
   * that alone. False when one still got no answer; the send must not go out, or the
   * image would ride with it. `cancelled` returns early; the flush carries on.
   */
  async clear(sessionID: string, client: GatewayClient, cancelled?: () => boolean): Promise<boolean> {
    if (!this.flushes.has(sessionID) && this.paths(sessionID).length === 0) return true
    const flush = this.startFlush(sessionID, client)
    if (cancelled) await untilCancelled(flush, cancelled)
    else await flush
    return this.paths(sessionID).length === 0
  }

  private startFlush(sessionID: string, client: GatewayClient): Promise<void> {
    const previous = this.flushes.get(sessionID) ?? Promise.resolve()
    const flush = previous.then(() => this.detachAll(sessionID, client))
    this.flushes.set(sessionID, flush)
    void flush.then(() => { if (this.flushes.get(sessionID) === flush) this.flushes.delete(sessionID) })
    return flush
  }

  /** Takes the session's entries out first, detaches them in parallel, puts back the unanswered. */
  private async detachAll(sessionID: string, client: GatewayClient): Promise<void> {
    const batch = this.images.filter((image) => image.sessionID === sessionID)
    if (batch.length === 0) return
    this.images = this.images.filter((image) => image.sessionID !== sessionID)
    const answered = await Promise.all(batch.map((image) => detachImage(image, client)))
    this.strand(batch.filter((_, index) => !answered[index]))
  }
}

/**
 * False only when the request got no answer. Any answer settles the path: `detached:
 * false` (a turn already took it) or 4001 (the runtime is gone).
 */
export async function detachImage(image: StrandedImage, client: GatewayClient): Promise<boolean> {
  try {
    await client.call('image.detach', {
      session_id: image.sessionID, path: image.path, ...(image.profile !== undefined ? { profile: image.profile } : {}),
    })
    return true
  } catch (error) {
    return error instanceof RPCError
  }
}

function same(a: StrandedImage, b: StrandedImage): boolean {
  return a.sessionID === b.sessionID && a.path === b.path && a.profile === b.profile
}

async function untilCancelled(task: Promise<void>, cancelled: () => boolean): Promise<void> {
  let done = false
  void task.then(() => { done = true })
  while (!done && !cancelled()) await Promise.race([task, new Promise<void>((resolve) => setTimeout(resolve, 50))])
}
