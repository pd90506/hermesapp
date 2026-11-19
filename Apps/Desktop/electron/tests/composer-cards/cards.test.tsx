import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Observable, type ChatSession, type ClarifyRequest, type GatewayConnection, type ServerRequest } from '@talaria/hermes-core'
import { ModelContext } from '../../src/renderer/app/hooks.ts'
import type { AppModel } from '../../src/renderer/app/model.ts'
import { ClarifyCard } from '../../src/renderer/features/composer/cards/ClarifyCard.tsx'
import { PromptCards } from '../../src/renderer/features/composer/cards/PromptCards.tsx'
import {
  FakeMessageStore, PagedServer, eventually, rows,
} from '../../../../../Packages/hermes-core/tests/support/paged-server.ts'

class Store<T> extends Observable<T> {}

afterEach(cleanup)

async function runningChat() {
  const server = new PagedServer(new FakeMessageStore(rows(1, 2)))
  const connection = await server.connect()
  const chat = await connection.chats.openSession('default', { id: 'stored-1' })
  await eventually(() => chat.get().paging.isLoaded)
  const composer = connection.chats.composer(chat)
  composer.setDraft('first')
  await composer.submit()
  server.event('message.start', chat.sessionID, 1)
  await eventually(() => chat.get().isRunning)
  const model = Object.assign(new Store({}), { connection }) as unknown as AppModel
  return { server, connection, chat, composer, model }
}

function renderCards(model: AppModel, chat: ChatSession, connection: GatewayConnection) {
  const composer = connection.chats.composer(chat)
  return render(<ModelContext.Provider value={model}><PromptCards chat={chat} composer={composer} /></ModelContext.Provider>)
}

describe('PromptCards', () => {
  it('draws nothing while nothing waits', async () => {
    const { model, chat, connection } = await runningChat()
    const { container } = renderCards(model, chat, connection)
    expect(container.innerHTML).toBe('')
  })

  it('shows a held message with Steer and Cancel; Cancel gives the text back', async () => {
    const { model, chat, connection, composer } = await runningChat()
    renderCards(model, chat, connection)
    composer.setDraft('and the docs')
    await act(() => composer.submit())
    expect(screen.getByLabelText('Queued: and the docs')).toBeTruthy()
    expect(screen.getByRole('button', { name: 'Steer Now' })).toBeTruthy()
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    expect(screen.queryByLabelText('Queued: and the docs')).toBeNull()
    expect(composer.draft).toBe('and the docs')
  })

  it('shows the compression, and no Steer during it', async () => {
    const { server, model, chat, connection, composer } = await runningChat()
    renderCards(model, chat, connection)
    composer.setDraft('after')
    await act(() => composer.submit())
    act(() => server.event('status.update', chat.sessionID, 2, { kind: 'compacting', text: '' }))
    await act(async () => { await eventually(() => chat.get().isCompacting) })
    expect(screen.getByText('Compressing context…')).toBeTruthy()
    expect(screen.queryByRole('button', { name: 'Steer Now' })).toBeNull()
  })
})

describe('ClarifyCard', () => {
  const clarify: ClarifyRequest = {
    session_id: 's',
    questions: [
      { qid: 'db', question: 'Which database?', choices: ['Postgres (Recommended)', 'SQLite'] },
      { qid: 'name', question: 'Project name?' },
    ],
  }
  const request: ServerRequest = { id: 'r1', method: 'clarify', params: clarify as never }

  it('steps through the questions and sends every answer at once', () => {
    const answerClarify = vi.fn()
    const chat = { answerClarify } as unknown as ChatSession
    render(<ClarifyCard chat={chat} request={request} clarify={clarify} />)
    expect(screen.getByText('Hermes has 2 questions')).toBeTruthy()
    expect(screen.getByText('Recommended')).toBeTruthy()
    const send = screen.getByRole('button', { name: 'Send Answers' }) as HTMLButtonElement
    expect(send.disabled).toBe(true)
    fireEvent.click(screen.getByRole('radio', { name: 'Postgres' }))
    // A single choice moves on to the next question.
    expect(screen.getByText('Project name?')).toBeTruthy()
    expect(screen.getByText('1 of 2 answered')).toBeTruthy()
    fireEvent.change(screen.getByLabelText('Your answer'), { target: { value: 'talaria' } })
    fireEvent.click(send)
    expect(answerClarify).toHaveBeenCalledWith(request, { db: 'Postgres', name: 'talaria' })
  })

  it('Skip cancels the request', () => {
    const answerClarify = vi.fn()
    render(<ClarifyCard chat={{ answerClarify } as unknown as ChatSession} request={request} clarify={clarify} />)
    fireEvent.click(screen.getByRole('button', { name: 'Skip' }))
    expect(answerClarify).toHaveBeenCalledWith(request, null)
  })
})
