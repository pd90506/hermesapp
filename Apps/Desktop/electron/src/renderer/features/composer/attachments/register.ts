import { originalFileNames } from '@talaria/hermes-core'
import { registerComposerSlot } from '../slots.ts'
import { AttachButton } from './AttachButton.tsx'
import { AttachmentCards } from './AttachmentCards.tsx'

// E: attachment cards above the text, and the attach button at the toolbar's start.
registerComposerSlot({ id: 'attachments', area: 'attachments', order: 0, Slot: AttachmentCards })
registerComposerSlot({ id: 'attach', area: 'leading', order: 0, Slot: AttachButton })

// The names the user gave attached files, so bubbles show them after a restart too.
const namesKey = 'talaria.attachmentNames'
try {
  const storage = window.localStorage
  originalFileNames.use({ load: () => storage.getItem(namesKey), save: (value) => storage.setItem(namesKey, value) })
} catch {
  // No storage: names hold for this run only.
}
