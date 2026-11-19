import { registerComposerSlot } from '../slots.ts'
import { AttachButton } from './AttachButton.tsx'
import { AttachmentCards } from './AttachmentCards.tsx'

// E: attachment cards above the text, and the attach button at the toolbar's start.
registerComposerSlot({ id: 'attachments', area: 'attachments', order: 0, Slot: AttachmentCards })
registerComposerSlot({ id: 'attach', area: 'leading', order: 0, Slot: AttachButton })
