/** A value React (or anything else) can watch: `useSyncExternalStore(subscribe, get)`. */
export class Observable<T> {
  private listeners = new Set<() => void>()
  constructor(private value: T) {}

  get = (): T => this.value

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  protected set(value: T): void {
    if (Object.is(value, this.value)) return
    this.value = value
    for (const listener of [...this.listeners]) listener()
  }
}
