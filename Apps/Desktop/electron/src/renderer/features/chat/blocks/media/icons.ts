import type { FileKind } from '@talaria/hermes-core'

/** Line icons, 16×16, drawn with the current colour (after Hermes Desktop's file pills). */
export const fileIcons: Record<FileKind | 'folder', string> = {
  image: 'M2.5 3.5h11v9h-11zM2.5 10.5l3-3 3 3 2-2 3 3M10.5 6.2h.01',
  pdf: 'M4 1.5h5.5l3 3v10H4zM9.5 1.5v3h3M6 9h4M6 11.5h4',
  text: 'M4 1.5h5.5l3 3v10H4zM9.5 1.5v3h3M6 7.5h4M6 9.5h4M6 11.5h3',
  code: 'M6 4.5 2.5 8 6 11.5M10 4.5 13.5 8 10 11.5',
  spreadsheet: 'M2.5 3.5h11v9h-11zM2.5 6.5h11M2.5 9.5h11M6.5 3.5v9',
  document: 'M4 1.5h5.5l3 3v10H4zM9.5 1.5v3h3M6 7.5h4.5M6 9.5h4.5M6 11.5h4.5',
  presentation: 'M2 3.5h12v7H2zM8 10.5v3M5.5 13.5h5',
  archive: 'M3 2.5h10v11H3zM8 2.5v1.5M8 5v1.5M8 7.5V9M7 10h2v2H7z',
  audio: 'M2.5 6.5v3M5 4.5v7M7.5 2.5v11M10 5v6M12.5 6.5v3',
  video: 'M2.5 4h11v8h-11zM6.5 6v4l3.5-2z',
  other: 'M4 1.5h5.5l3 3v10H4zM9.5 1.5v3h3',
  folder: 'M1.5 4h4.5l1.5 1.5h7v7h-13z',
}

export const actionIcons = {
  plus: 'M8 3v10M3 8h10',
  close: 'M4.5 4.5l7 7M11.5 4.5l-7 7',
  download: 'M8 2.5v8M4.5 7 8 10.5 11.5 7M3 13.5h10',
  open: 'M9 2.5h4.5V7M13.5 2.5 7.5 8.5M12 9.5v4H2.5V4h4',
  alert: 'M8 2l6.5 11.5h-13zM8 6.5v3.5M8 12h.01',
} as const
