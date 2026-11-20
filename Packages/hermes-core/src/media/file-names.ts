/**
 * The names the user gave the files they attached, by where the gateway stored them.
 * `file.attach` renames a file whose name is taken (`notes.txt` → `notes-2.txt`); bubbles
 * show the name the user chose (user 2026-11-19), so an upload records it here and a
 * stored row looks it up. The last `limit` names are kept, in `storage` when one is set.
 */
export interface FileNameStorage {
  load(): string | null
  save(value: string): void
}

export class OriginalFileNames {
  private names = new Map<string, string>()
  private storage: FileNameStorage | undefined

  constructor(readonly limit = 1000) {}

  /** Reads what `storage` kept and saves there from now on. */
  use(storage: FileNameStorage | undefined): void {
    this.storage = storage
    this.names = new Map()
    if (!storage) return
    try {
      const saved: unknown = JSON.parse(storage.load() ?? '[]')
      if (Array.isArray(saved)) {
        for (const entry of saved) {
          if (Array.isArray(entry) && typeof entry[0] === 'string' && typeof entry[1] === 'string') this.names.set(entry[0], entry[1])
        }
      }
    } catch {
      // Unreadable: start empty.
    }
  }

  remember(paths: readonly (string | undefined)[], name: string): void {
    for (const path of paths) {
      if (!path) continue
      this.names.delete(path)
      this.names.set(path, name)
    }
    while (this.names.size > this.limit) this.names.delete(this.names.keys().next().value as string)
    try {
      this.storage?.save(JSON.stringify([...this.names]))
    } catch {
      // Storage full or gone: the names still hold for this run.
    }
  }

  name(path: string): string | undefined {
    return this.names.get(path)
  }
}

export const originalFileNames = new OriginalFileNames()
