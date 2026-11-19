import { useSyncExternalStore } from 'react'
import { Observable, type ChatSession } from '@talaria/hermes-core'

/** Which of a chat's pill cards is open: one at a time, so they never cover each other. */
export type PillCard = 'todo' | 'background' | 'subagents'

class OpenCard extends Observable<PillCard | undefined> {
  constructor() {
    super(undefined)
  }

  show(card: PillCard | undefined): void {
    this.set(card)
  }
}

const cards = new WeakMap<ChatSession, OpenCard>()

function openCard(chat: ChatSession): OpenCard {
  let card = cards.get(chat)
  if (!card) {
    card = new OpenCard()
    cards.set(chat, card)
  }
  return card
}

/** Whether `card` is open for `chat`, and its toggle; opening one closes the others. */
export function useOpenCard(chat: ChatSession, card: PillCard): [boolean, (open: boolean) => void] {
  const state = openCard(chat)
  const open = useSyncExternalStore(state.subscribe, state.get) === card
  return [open, (next) => state.show(next ? card : state.get() === card ? undefined : state.get())]
}
