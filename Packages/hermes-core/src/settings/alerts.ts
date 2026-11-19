/**
 * What a system notification is about (HermesKit's `AlertKind`): Hermes Desktop's native
 * notification kinds (`apps/desktop/src/store/native-notifications.ts:26-37`) without
 * `plugin`, plus this app's `otherReply`.
 */
export type AlertKind = 'approval' | 'input' | 'turnDone' | 'turnError' | 'backgroundDone' | 'credits' | 'otherReply'

export const alertKinds: readonly AlertKind[] = ['approval', 'input', 'turnDone', 'turnError', 'backgroundDone', 'credits', 'otherReply']

/**
 * Which notifications the user wants, on this device (HermesKit's `AlertPreferences`,
 * the same JSON shape). Settings ▸ Notifications writes it; notifications read it with
 * `isAlertOn`.
 */
export interface AlertPreferences {
  /** Off silences every kind. */
  isEnabled: boolean
  /** While the app is in front, banners for chats not on screen too. */
  showsInApp: boolean
  /** Kinds switched away from their default. */
  kinds: Partial<Record<AlertKind, boolean>>
}

export const defaultAlertPreferences: AlertPreferences = { isEnabled: true, showsInApp: true, kinds: {} }

export function decodeAlertPreferences(value: unknown): AlertPreferences {
  const raw = (value && typeof value === 'object' ? value : {}) as Record<string, unknown>
  const kinds: Partial<Record<AlertKind, boolean>> = {}
  if (raw.kinds && typeof raw.kinds === 'object') {
    for (const [key, on] of Object.entries(raw.kinds as Record<string, unknown>)) {
      if ((alertKinds as readonly string[]).includes(key) && typeof on === 'boolean') kinds[key as AlertKind] = on
    }
  }
  return {
    isEnabled: typeof raw.isEnabled === 'boolean' ? raw.isEnabled : true,
    showsInApp: typeof raw.showsInApp === 'boolean' ? raw.showsInApp : true,
    kinds,
  }
}

/** Every kind but `otherReply` is on until switched off. */
export function isAlertOn(preferences: AlertPreferences, kind: AlertKind): boolean {
  return preferences.isEnabled && (preferences.kinds[kind] ?? kind !== 'otherReply')
}

export function setAlertOn(preferences: AlertPreferences, kind: AlertKind, on: boolean): AlertPreferences {
  return { ...preferences, kinds: { ...preferences.kinds, [kind]: on } }
}

/** Settings ▸ Notifications' words (the Mac's `NotificationSettingsCopy`, from Desktop's `i18n/en_notifications.ts`). */
export const alertCopy = {
  enableAll: 'Enable Notifications',
  enableAllNote: 'Off silences every notification below. Kept on this device only.',
  inApp: 'Banners While Talaria Is Open',
  inAppNote: 'Responses, failures and replies in chats you aren’t looking at show as a banner too while Talaria is in front. Click one to open its chat.',
  hint: 'While Talaria is in the background, responses and failures notify only for the chat you had open, as in Hermes Desktop. With banners off, the same holds while it is open.',
  testSent: 'Test sent. If nothing appears, check Focus or Do Not Disturb.',
  denied: 'Notifications for Talaria are off in the system settings.',
  kinds: {
    approval: { label: 'Approval Needed', note: 'A command is waiting for you to approve or reject it.' },
    input: { label: 'Input Needed', note: 'Hermes asked a question, or needs a password or secret.' },
    turnDone: { label: 'Response Ready', note: 'A turn finished in a chat you aren’t looking at.' },
    turnError: { label: 'Turn Failed', note: 'A turn failed in a chat you aren’t looking at.' },
    backgroundDone: { label: 'Background Task Finished', note: 'A /background task finished.' },
    credits: { label: 'Credit Alerts', note: 'Credit access is paused or restored.' },
    otherReply: { label: 'Replies in Other Chats', note: 'A reply came in a chat Talaria doesn’t follow live, such as a Telegram or cron session.' },
  } satisfies Record<AlertKind, { label: string; note: string }>,
}
