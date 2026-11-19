import { registerSettingsPane } from './panes.ts'
import { NotificationsPane } from './NotificationsPane.tsx'
import { ServersPane } from './servers/ServersPane.tsx'
import { SessionSourcesPane } from './SessionSourcesPane.tsx'
import { createElement } from 'react'

// One line per pane; each package adds its own (L: providers, capabilities; M: appearance).
registerSettingsPane({ id: 'servers', title: 'Servers', icon: 'server', render: () => createElement(ServersPane) })
registerSettingsPane({ id: 'sessionSources', title: 'Session Sources', icon: 'tray', render: () => createElement(SessionSourcesPane) })
registerSettingsPane({ id: 'notifications', title: 'Notifications', icon: 'bell', render: () => createElement(NotificationsPane) })
