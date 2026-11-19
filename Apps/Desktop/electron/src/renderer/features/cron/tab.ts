import { registerSidebarTab } from '../sidebar/tabs.ts'
import { useCronAlert } from './alert.ts'
import { CronJobsList } from './CronJobsList.tsx'

registerSidebarTab({ id: 'cron', title: 'Cron Jobs', icon: 'clock', order: 10, Page: CronJobsList, useAlert: useCronAlert })
