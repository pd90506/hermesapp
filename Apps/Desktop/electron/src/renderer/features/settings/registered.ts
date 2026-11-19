import { createElement } from 'react'
import { registerSettingsPane } from './panes.ts'
import { AppearancePane } from './appearance/AppearancePane.tsx'
import { CapabilitiesSettingsPane } from './capabilities/CapabilitiesPane.tsx'
import { NotificationsPane } from './NotificationsPane.tsx'
import { ProvidersSettingsPane } from './providers/ProvidersPane.tsx'
import { ServersPane } from './servers/ServersPane.tsx'
import { SessionSourcesPane } from './SessionSourcesPane.tsx'

// One line per pane; the overlay lists them in panes.ts's order.
registerSettingsPane({ id: 'servers', title: 'Servers', icon: 'server', render: () => createElement(ServersPane) })
registerSettingsPane({ id: 'providers', title: 'Providers', icon: 'key', render: () => createElement(ProvidersSettingsPane) })
registerSettingsPane({ id: 'capabilities', title: 'Capabilities', icon: 'puzzle', render: () => createElement(CapabilitiesSettingsPane) })
registerSettingsPane({ id: 'sessionSources', title: 'Session Sources', icon: 'tray', render: () => createElement(SessionSourcesPane) })
registerSettingsPane({ id: 'appearance', title: 'Appearance', icon: 'palette', render: () => createElement(AppearancePane) })
registerSettingsPane({ id: 'notifications', title: 'Notifications', icon: 'bell', render: () => createElement(NotificationsPane) })
