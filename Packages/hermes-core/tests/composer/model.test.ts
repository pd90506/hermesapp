import { describe, expect, it, test } from 'vitest'
import { ModelCatalog, ReasoningEffort, modelDisplayName, sessionModelValue } from '../../src/index.ts'

// The same cases as HermesKit's ModelLabelTests and ChatComposerTests.

describe('modelDisplayName', () => {
  test.each([
    ['claude-opus-5-5', 'Opus 5.5'],
    ['claude-haiku-4-5-20251001', 'Haiku 4.5'],
    ['anthropic/claude-sonnet-5-5[1m]', 'Sonnet 5.5 · 1M'],
    ['gpt-5.2', 'GPT-5.2'],
    ['gemini-2.5-pro', 'Gemini 2.5 Pro'],
    ['deepseek/deepseek-v4-flash', 'DeepSeek V4 · Flash'],
    ['qwen3-235b-a22b', 'Qwen3 235B A22B'],
    ['', 'No model'],
  ])('%s → %s', (model, expected) => {
    expect(modelDisplayName(model)).toBe(expected)
  })
})

describe('ModelCatalog', () => {
  const catalog = new ModelCatalog({
    model: 'claude-opus-5-5',
    provider: 'anthropic',
    providers: [
      { slug: 'anthropic', name: 'Anthropic', models: ['claude-opus-5-5', 'claude-haiku-5-5'], is_current: true,
        capabilities: { 'claude-haiku-5-5': { reasoning: false }, 'claude-opus-5-5': { reasoning: true, can_disable_reasoning: false } } },
      { slug: 'empty', name: 'Nothing', models: [] },
      { slug: 'openrouter', models: ['gpt-5.2'], capabilities: 'not an object' },
      { name: 'no slug' },
    ],
  })

  it('keeps providers with models, sorted so the menu never reshuffles', () => {
    expect(catalog.providers.map((row) => row.slug)).toEqual(['anthropic', 'openrouter'])
    expect(catalog.providers[0]!.models).toEqual(['claude-haiku-5-5', 'claude-opus-5-5'])
    const shuffled = new ModelCatalog({ providers: [
      { slug: 'z', name: 'Zed', models: ['m-10', 'm-2', 'M-1'] }, { slug: 'a', name: 'alpha', models: ['x'] }] })
    expect(shuffled.providers.map((row) => row.name)).toEqual(['alpha', 'Zed'])
    expect(shuffled.providers[1]!.models).toEqual(['M-1', 'm-2', 'm-10'])
    expect(catalog.providerName('openrouter')).toBe('openrouter')
    expect(catalog.providerName('ANTHROPIC')).toBe('Anthropic')
    expect(catalog.model).toBe('claude-opus-5-5')
    expect(new ModelCatalog({ providers: [] }).isEmpty).toBe(true)
  })

  it('offers effort levels by capability', () => {
    expect(ReasoningEffort.choices(catalog.capabilities('claude-haiku-5-5', 'anthropic'))).toEqual([])
    expect(ReasoningEffort.choices(catalog.capabilities('claude-opus-5-5', 'Anthropic'))).toEqual(ReasoningEffort.levels)
    // An unknown model keeps the dial, with Off first.
    expect(ReasoningEffort.choices(catalog.capabilities('gpt-5.2'))).toEqual(['none', ...ReasoningEffort.levels])
  })

  it('sends only effort words, and switches the session only', () => {
    expect(ReasoningEffort.isSendable('none')).toBe(true)
    expect(ReasoningEffort.isSendable('xhigh')).toBe(true)
    expect(ReasoningEffort.isSendable('off')).toBe(false)
    expect(ReasoningEffort.normalized(' High ')).toBe('high')
    expect(ReasoningEffort.label('xhigh')).toBe('Extra High')
    expect(sessionModelValue({ provider: 'anthropic', model: 'claude-opus-5-5' })).toBe('claude-opus-5-5 --provider anthropic --session')
    expect(sessionModelValue({ provider: ' ', model: 'm' })).toBe('m --session')
  })
})

describe('ComposerModels', () => {
  async function open() {
    const { PagedServer } = await import('../support/paged-server.ts')
    const server = new PagedServer()
    server.handlers.set('model.options', () => ({
      model: 'test-model', provider: 'local',
      providers: [{ slug: 'local', name: 'Local', models: ['test-model', 'big-model'],
        capabilities: { 'test-model': { reasoning: true }, 'big-model': { reasoning: false } } }],
    }))
    server.handlers.set('config.get', () => ({ value: 'High' }))
    const sets: Array<Record<string, unknown>> = []
    server.handlers.set('config.set', (params) => {
      sets.push(params)
      if (params.key === 'model' && params.value === 'big-model --provider local --session' && !params.confirm_expensive_model) {
        return { confirm_required: true, confirm_message: 'big-model costs $75/M output tokens.' }
      }
      return { key: params.key, value: params.value }
    })
    const connection = await server.connect()
    const chat = await connection.chats.newChat('coder')
    const composer = connection.chats.composer(chat)
    return { server, composer, sets }
  }

  it('loads the catalog and the effort, and switches the session only', async () => {
    const { composer, sets, server } = await open()
    await composer.models.loadOptions()
    expect(server.calls('model.options')[0]).toMatchObject({ explicit_only: true, profile: 'coder' })
    expect(composer.models.currentModelLabel).toBe('Test Model')
    expect(composer.models.currentEffort).toBe('high')
    expect(composer.models.effortChoices[0]).toBe('none')
    await composer.models.selectEffort('low')
    expect(sets.at(-1)).toMatchObject({ key: 'reasoning', value: 'low' })
    expect(composer.models.currentEffort).toBe('low')
    await composer.models.loadOptions(true)
    expect(server.calls('model.options')[1]?.refresh).toBe(true)
  })

  it('asks before an expensive model, and switches once confirmed', async () => {
    const { composer, sets } = await open()
    await composer.models.loadOptions()
    await composer.models.selectModel({ provider: 'local', model: 'big-model' })
    expect(composer.models.get().pendingSwitch?.message).toBe('big-model costs $75/M output tokens.')
    expect(composer.models.currentModel).toBe('test-model')
    await composer.models.confirmPendingSwitch()
    expect(sets.at(-1)).toMatchObject({ key: 'model', confirm_expensive_model: true })
    expect(composer.models.currentModel).toBe('big-model')
    expect(composer.models.effortChoices).toEqual([])
    expect(composer.models.get().pendingSwitch).toBeUndefined()
  })

  it('shows a failed load in the composer', async () => {
    const { composer, server } = await open()
    server.errors.set('model.options', { code: 5000, message: 'boom' })
    await composer.models.loadOptions()
    expect(composer.get().error).toBe("Couldn't load models: boom")
  })
})

describe('the current model row', () => {
  it('matches a provider by slug, name or alias, as Desktop', async () => {
    const { PagedServer } = await import('../support/paged-server.ts')
    const server = new PagedServer()
    server.handlers.set('model.options', () => ({ providers: [
      { slug: 'custom:cliproxy', name: 'cliproxy', aliases: ['cliproxy-key'], models: ['claude-sonnet-5-5'] },
      { slug: 'openrouter', name: 'OpenRouter', models: ['claude-sonnet-5-5'] }] }))
    server.handlers.set('config.get', () => ({ value: 'medium' }))
    const connection = await server.connect()
    const chat = await connection.chats.newChat('coder')
    const composer = connection.chats.composer(chat)
    await composer.models.loadOptions()
    for (const reported of ['custom:cliproxy', 'cliproxy', 'CLIPROXY-KEY']) {
      chat.showInfo({ model: 'claude-sonnet-5-5', provider: reported })
      expect(composer.models.isCurrent({ provider: 'custom:cliproxy', model: 'claude-sonnet-5-5' })).toBe(true)
      expect(composer.models.isCurrent({ provider: 'openrouter', model: 'claude-sonnet-5-5' })).toBe(false)
    }
    // A name no row answers to: the model alone decides when only one row lists it.
    chat.showInfo({ model: 'claude-sonnet-5-5', provider: 'something-else' })
    expect(composer.models.isCurrent({ provider: 'openrouter', model: 'claude-sonnet-5-5' })).toBe(false)
  })
})
