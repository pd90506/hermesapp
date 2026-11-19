import { needsAttention } from '@talaria/hermes-core'
import { useSnapshot } from '../../app/hooks.ts'
import { useCronBoard } from './board.ts'

/** The Cron Jobs tab's red dot: a job whose last run failed or wasn't delivered (the Mac's `cronAlerts`). */
export function useCronAlert(): boolean {
  const { board } = useCronBoard()
  return useSnapshot(board).jobs.some(needsAttention)
}
