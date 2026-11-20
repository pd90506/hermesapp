import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './theme/tokens.css'
import './theme/platform.css'
import './theme/themes/themes.css'
import './theme/base.css'
import { App } from './App.tsx'
import { AppModel } from './app/model.ts'
import { startNotifications } from './features/notifications/notifier.ts'

const model = new AppModel(window.talaria)
const root = document.getElementById('root')
if (root) {
  createRoot(root).render(<StrictMode><App model={model} /></StrictMode>)
}
void model.start()
startNotifications(model) // J
