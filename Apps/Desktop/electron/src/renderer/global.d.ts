import type { TalariaBridge } from '../shared/bridge.ts'

declare global {
  interface Window {
    /** Set by the preload (src/preload/preload.ts). */
    talaria: TalariaBridge
  }
}
