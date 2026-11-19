/**
 * Sessions the user pinned to the top of their profile's list, per server (HermesKit's
 * `SessionPins`).
 *
 * `[client choice]` Kept by the app. Hermes's own pin is the `sessions.pinned` column,
 * written only through the dashboard's fenced REST `PATCH /api/sessions/{id} {pinned}`
 * (`apps/desktop/src/api/sessions.ts:427-428`); `session.list` rows don't carry it
 * (`_session_row_summary`, `methods_session.py:110-122`), so it can't be read back over
 * JSON-RPC (`docs/protocol.md` §10.9).
 */
export class SessionPins {
  private readonly keys: Set<string>

  constructor(keys: Iterable<string> = []) {
    this.keys = new Set(keys)
  }

  /** Stored ids are only unique per profile db, and profile names per server. */
  static key(server: string, profile: string, id: string): string {
    return `${server}/${profile}/${id}`
  }

  isPinned(server: string, profile: string, id: string): boolean {
    return this.keys.has(SessionPins.key(server, profile, id))
  }

  /** A copy with the row pinned or not. */
  setPinned(pinned: boolean, server: string, profile: string, id: string): SessionPins {
    const next = new Set(this.keys)
    if (pinned) next.add(SessionPins.key(server, profile, id))
    else next.delete(SessionPins.key(server, profile, id))
    return new SessionPins(next)
  }

  /** A server's pins go with it. */
  forgetServer(server: string): SessionPins {
    return new SessionPins([...this.keys].filter((key) => !key.startsWith(`${server}/`)))
  }

  /** The pinned rows, then the rest, each in list order. */
  split<T extends { id: string }>(rows: readonly T[], server: string, profile: string): { pinned: T[]; others: T[] } {
    const pinned: T[] = []
    const others: T[] = []
    for (const row of rows) (this.isPinned(server, profile, row.id) ? pinned : others).push(row)
    return { pinned, others }
  }

  toJSON(): string[] {
    return [...this.keys].sort()
  }
}
