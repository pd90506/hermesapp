/** Session method and event names (HermesKit's `GatewayMethods.swift`, `EventType`). */
export const SessionMethod = {
  sessionActivate: 'session.activate',
  sessionCompress: 'session.compress',
  sessionCreate: 'session.create',
  sessionEventsSince: 'session.events.since',
  sessionInterrupt: 'session.interrupt',
  sessionResume: 'session.resume',
  sessionSteer: 'session.steer',
  sessionTitle: 'session.title',
  promptSubmit: 'prompt.submit',
} as const

/** The source the app's sessions carry, as Desktop sends `desktop` (HermesKit's `SessionSourceSettings.newSessionSource`). */
export const newSessionSource = 'desktop'

/** `PROMPT_SUBMIT_REQUEST_TIMEOUT_MS` in Hermes Desktop: an ack can lag behind a busy session. */
export const promptSubmitTimeoutMs = 1_800_000

/** How long `session.compress` may take (HermesKit's `compress`, 660 s): a summary call runs first. */
export const sessionCompressTimeoutMs = 660_000
