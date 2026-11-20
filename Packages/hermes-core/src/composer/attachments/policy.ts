// What the gateway accepts for images and files, and what the app must convert first
// (HermesKit's `ImageAttachmentPolicy`, `FileAttachmentPolicy`, `ComposerAttachment.formatBytes`;
// docs/protocol.md §10.3, §10.5).

/** `512 bytes`, `14 KB`, `2.4 MB` (decimal units, like Finder and Explorer's sizes). */
export function formatBytes(count: number): string {
  if (count < 1000) return `${count} bytes`
  if (count < 1_000_000) return `${Math.round(count / 1000)} KB`
  return `${(count / 1_000_000).toFixed(1)} MB`
}

/** Lower-cased, without the dot; empty when there is none. */
export function fileExtension(filename: string): string {
  const dot = filename.lastIndexOf('.')
  if (dot <= 0) return ''
  const ext = filename.slice(dot + 1)
  return ext.includes('/') || ext.includes('\\') ? '' : ext.toLowerCase()
}

export const ImageAttachmentPolicy = {
  /** The gateway's cap; larger uploads fail with 4018 (`prompt_attachments.py:16,50-60`). */
  maxBytes: 25 * 1024 * 1024,
  /**
   * Formats sent unchanged. Hermes stores more (bmp, tiff, svg, ico) but not HEIC, and
   * vision providers commonly read only these four; anything else is re-encoded first.
   */
  passthroughExtensions: new Set(['png', 'jpg', 'jpeg', 'gif', 'webp']),
  /** At most this many image cards per message: each holds its bytes in memory. */
  maxAttachments: 10,
  /** Long side tried when the full-size encode is over `maxBytes`. */
  downscaleSides: [4096, 2048],

  canSendUnchanged(filename: string): boolean {
    return this.passthroughExtensions.has(fileExtension(filename))
  },

  /** `IMG_0001.HEIC` → `IMG_0001.jpg` for a re-encoded copy. */
  filename(original: string, newExtension: string): string {
    const name = original === '' ? 'image' : original
    const ext = fileExtension(name)
    const stem = ext === '' ? name : name.slice(0, name.length - ext.length - 1)
    return `${stem === '' ? 'image' : stem}.${newExtension}`
  },

  /** Why an image cannot be attached as it is, or undefined when it can. */
  rejection(filename: string, byteCount: number): string | undefined {
    if (byteCount === 0) return `${filename} is empty.`
    if (byteCount > this.maxBytes) {
      return `${filename} is too large (${formatBytes(byteCount)}; the limit is ${this.maxBytes / 1024 / 1024} MB).`
    }
    if (!this.canSendUnchanged(filename)) return `${filename} is not a PNG, JPEG, GIF or WebP image.`
    return undefined
  },

  /**
   * The encodes to try, in order, for an image that cannot be sent as it is; the app
   * keeps the first output within `maxBytes`. Native size first unless the source alone
   * is over the cap; then 4096 and 2048 px on the long side, each in the preferred format
   * (PNG keeps alpha) and then as JPEG. Unknown dimensions start at native size.
   */
  encodeAttempts(sourceBytes: number, width: number | undefined, height: number | undefined, hasAlpha: boolean): EncodeAttempt[] {
    const preferred: EncodedFormat = hasAlpha ? 'png' : 'jpeg'
    const formats: EncodedFormat[] = hasAlpha ? ['png', 'jpeg'] : ['jpeg']
    const longest = Math.max(width ?? 0, height ?? 0)
    const known = longest > 0
    const attempts: EncodeAttempt[] = []
    if (sourceBytes <= this.maxBytes) attempts.push({ format: preferred })
    for (const side of this.downscaleSides) {
      if (known && side >= longest) continue
      for (const format of formats) attempts.push({ maxPixels: side, format })
    }
    // A small image whose source is over the cap (a long animated GIF): one JPEG frame.
    const hasLastResort = attempts.some((attempt) => attempt.maxPixels === undefined && attempt.format === 'jpeg')
    const smallest = this.downscaleSides[this.downscaleSides.length - 1]!
    if (attempts.length === 0 || (known && longest <= smallest && !hasLastResort)) attempts.push({ format: 'jpeg' })
    return attempts
  },
}

export type EncodedFormat = 'png' | 'jpeg'

/** One encode to try; no `maxPixels` keeps the native size. */
export interface EncodeAttempt {
  maxPixels?: number
  format: EncodedFormat
}

export function encodedExtension(format: EncodedFormat): string {
  return format === 'png' ? 'png' : 'jpg'
}

export const FileAttachmentPolicy = {
  /**
   * `file.attach` has no cap of its own; the bytes travel base64 in one WebSocket frame.
   * Hermes' own PDF cap (`_PDF_ATTACH_MAX_BYTES`) bounds it here too (§10.5).
   */
  maxBytes: 50 * 1024 * 1024,

  /** Why a file of this size cannot be attached, or undefined when it can. */
  rejection(byteCount: number): string | undefined {
    if (byteCount === 0) return 'the file is empty'
    if (byteCount > this.maxBytes) {
      return `it is too large (${formatBytes(byteCount)}; the limit is ${this.maxBytes / 1024 / 1024} MB)`
    }
    return undefined
  },
}

/** File extensions read as images: anything the app can convert (`ClipboardPolicy.imageFileExtensions`). */
export const imageFileExtensions = new Set(['png', 'jpg', 'jpeg', 'gif', 'webp', 'heic', 'heif', 'tif', 'tiff', 'bmp'])

/**
 * What a paste into the composer does (HermesKit's `ClipboardPolicy`, for a web
 * clipboard): files on it are attached (a copy in Finder or Explorer, a screenshot, an
 * image copied from a browser), unless its text is real text, which stays text. A copied
 * spreadsheet range or rich-text selection carries a picture of itself beside the text.
 */
export const ClipboardPolicy = {
  /**
   * `files`: the clipboard's files (`clipboardData.files`); `text`: its plain text.
   * Copied files from Finder or Explorer come with their names as text.
   */
  decide(contents: { fileCount: number; text?: string; fileNames?: readonly string[] }): 'text' | 'files' {
    if (contents.fileCount === 0) return 'text'
    const text = (contents.text ?? '').trim()
    if (contents.fileNames && contents.fileNames.length > 0 && namesOnly(text, contents.fileNames)) return 'files'
    return this.isIncidental(contents.text) ? 'files' : 'text'
  },

  /**
   * A string that comes along with a copied image rather than being what was copied:
   * none, blank, or one line that is a link or an image file name.
   */
  isIncidental(string: string | undefined): boolean {
    const text = (string ?? '').trim()
    if (text === '') return true
    if (/[\n\r]/.test(text)) return false
    // Only link schemes: `TODO:fix` or `key:value` in a copied cell is text.
    if (/^(?:https?|file|data):\S+$/i.test(text)) return true
    return imageFileExtensions.has(fileExtension(text))
  },
}

/** The text is just the copied files' names (or paths), one per line. */
function namesOnly(text: string, names: readonly string[]): boolean {
  if (text === '') return true
  const lines = text.split(/\r?\n/).map((line) => line.trim()).filter((line) => line !== '')
  return lines.every((line) => names.some((name) => line === name || line.endsWith(`/${name}`) || line.endsWith(`\\${name}`)))
}

/** Why a composer action failed before anything reached the gateway (HermesKit's `ComposerError`). */
export class AttachmentError extends Error {
  constructor(readonly kind: 'attachmentFailed' | 'notConnected' | 'strandedImages', message: string) {
    super(message)
  }

  static attachmentFailed(filename: string, reason: string): AttachmentError {
    return new AttachmentError('attachmentFailed', `Couldn't attach ${filename}: ${reason}`)
  }

  static notConnected(): AttachmentError {
    return new AttachmentError('notConnected', 'Not connected to Hermes. Nothing was sent; try again once it reconnects.')
  }

  static strandedImages(): AttachmentError {
    return new AttachmentError('strandedImages',
      "Images from an earlier failed send are still queued on Hermes and couldn't be removed, " +
      'so nothing was sent (they would have gone with it). Try again.')
  }
}
