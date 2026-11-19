import { SessionList } from './SessionList.tsx'
import { registerSidebarTab } from './tabs.ts'

registerSidebarTab({ id: 'sessions', title: 'Sessions', icon: 'sessions', order: 0, Page: SessionList })
