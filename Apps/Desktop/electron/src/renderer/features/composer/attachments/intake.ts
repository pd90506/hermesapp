import {
  AttachmentTray, ImageAttachmentPolicy, attachmentID, encodedExtension, fileExtension, imageFileExtensions,
  type ComposerImage, type EncodeAttempt,
} from '@talaria/hermes-core'
import { rememberLocalImage } from '../../chat/blocks/media/local-images.ts'

/** A file the user picked, pasted or dropped, before it is read. */
export interface IncomingFile {
  name: string
  size: number
  /** The MIME type the system gave it, if any. */
  type?: string
  /** Where it is on disk: shown under an image card's name. */
  path?: string
  read(): Promise<Uint8Array>
}

/** A browser `File` (a paste or a drop) as an incoming file. */
export function incomingFromFile(file: File): IncomingFile {
  const path = window.talaria.files.pathFor(file)
  return {
    name: file.name || (file.type.startsWith('image/') ? `Pasted image.${file.type.slice(6).replace('jpeg', 'jpg')}` : 'Pasted file'),
    size: file.size,
    type: file.type,
    ...(path ? { path } : {}),
    read: async () => new Uint8Array(await file.arrayBuffer()),
  }
}

/** Files from the system's open dialog. */
export async function pickFiles(): Promise<IncomingFile[]> {
  const picked = await window.talaria.files.pick()
  return picked.map((file) => ({ name: file.name, size: file.size, path: file.path, read: () => window.talaria.files.read(file.path) }))
}

/**
 * Adds files to the composer, in order (the Mac's `ComposerView.attach(fileURLs:)`):
 * - an image Hermes takes as it is goes up unchanged;
 * - any other image (HEIC, TIFF, BMP, an image over 25 MB) is re-encoded first
 *   (`ImageAttachmentPolicy.encodeAttempts`): with Chromium's decoder, else with the OS's
 *   (`talaria.files.convertImage`); one that neither can read goes as a file;
 * - anything else is uploaded as a file (`file.attach`).
 */
export async function attachIncoming(tray: AttachmentTray, files: readonly IncomingFile[], report: (message: string) => void): Promise<void> {
  for (const file of files) {
    let bytes: Uint8Array
    try {
      bytes = await file.read()
    } catch {
      // A dropped folder reads as an error.
      report(`Couldn't attach ${file.name}: folders can't be attached.`)
      continue
    }
    const ext = fileExtension(file.name)
    if (imageFileExtensions.has(ext) || (ext === '' && file.type?.startsWith('image/'))) {
      const image = await prepareImage(file, bytes)
      if (image) {
        if (tray.attachImage(image)) rememberLocalImage(image)
        continue
      }
      if (ImageAttachmentPolicy.canSendUnchanged(file.name) && bytes.byteLength <= ImageAttachmentPolicy.maxBytes) {
        // Chromium could not even read its size: send it as it is.
        const plain: ComposerImage = { id: attachmentID(), filename: file.name, bytes, ...(file.path ? { source: file.path } : {}) }
        if (tray.attachImage(plain)) rememberLocalImage(plain)
        continue
      }
    }
    await tray.attachFile(bytes, file.name, file.type || undefined)
  }
}

/** The image as Hermes takes it, or undefined when it cannot be decoded here. */
async function prepareImage(file: IncomingFile, bytes: Uint8Array): Promise<ComposerImage | undefined> {
  const source = file.path ? { source: file.path } : {}
  let bitmap = await decode(bytes, file.type)
  if (!bitmap && !ImageAttachmentPolicy.canSendUnchanged(file.name)) bitmap = await decodeWithSystem(bytes)
  const width = bitmap?.width
  const height = bitmap?.height
  if (ImageAttachmentPolicy.canSendUnchanged(file.name) && bytes.byteLength <= ImageAttachmentPolicy.maxBytes) {
    bitmap?.close()
    return { id: attachmentID(), filename: file.name, bytes, ...(width ? { width, height } : {}), ...source }
  }
  // Like the Mac app (kCGImagePropertyHasAlpha): PNG only when the image really has
  // transparency, so an ordinary HEIC photo becomes a JPEG.
  const hasAlpha = bitmap ? bitmapHasAlpha(bitmap) : ['png', 'gif', 'webp', 'tif', 'tiff'].includes(fileExtension(file.name))
  const attempts = ImageAttachmentPolicy.encodeAttempts(bytes.byteLength, width, height, hasAlpha)
  try {
    for (const attempt of attempts) {
      const encoded = bitmap ? await encodeWithCanvas(bitmap, attempt) : await encodeWithSystem(bytes, attempt)
      if (!encoded) return undefined
      if (encoded.bytes.byteLength <= ImageAttachmentPolicy.maxBytes) {
        return {
          id: attachmentID(), filename: ImageAttachmentPolicy.filename(file.name, encodedExtension(attempt.format)),
          bytes: encoded.bytes, width: encoded.width, height: encoded.height, ...source,
        }
      }
    }
  } finally {
    bitmap?.close()
  }
  return undefined
}

async function decode(bytes: Uint8Array, type?: string): Promise<ImageBitmap | undefined> {
  try {
    return await createImageBitmap(new Blob([bytes as BlobPart], type ? { type } : {}))
  } catch {
    return undefined
  }
}

/** A format Chromium cannot read (HEIC in Electron): the system decodes it to PNG first. */
async function decodeWithSystem(bytes: Uint8Array): Promise<ImageBitmap | undefined> {
  const png = await window.talaria.files.convertImage(bytes, { format: 'png' })
  return png ? decode(png.bytes, 'image/png') : undefined
}

/** True when any pixel is not fully opaque. Checked on a copy of at most 512 px. */
function bitmapHasAlpha(bitmap: ImageBitmap): boolean {
  try {
    const size = scaled(bitmap.width, bitmap.height, 512)
    const context = new OffscreenCanvas(size.width, size.height).getContext('2d')
    if (!context) return true
    context.drawImage(bitmap, 0, 0, size.width, size.height)
    const pixels = context.getImageData(0, 0, size.width, size.height).data
    for (let i = 3; i < pixels.length; i += 4) if (pixels[i]! < 255) return true
    return false
  } catch {
    return true
  }
}

function scaled(width: number, height: number, maxPixels?: number): { width: number; height: number } {
  const longest = Math.max(width, height)
  if (!maxPixels || longest <= maxPixels) return { width, height }
  const scale = maxPixels / longest
  return { width: Math.max(1, Math.round(width * scale)), height: Math.max(1, Math.round(height * scale)) }
}

async function encodeWithCanvas(bitmap: ImageBitmap, attempt: EncodeAttempt): Promise<{ bytes: Uint8Array; width: number; height: number } | undefined> {
  const size = scaled(bitmap.width, bitmap.height, attempt.maxPixels)
  const canvas = new OffscreenCanvas(size.width, size.height)
  const context = canvas.getContext('2d')
  if (!context) return undefined
  if (attempt.format === 'jpeg') {
    // JPEG has no alpha: transparent parts go white, not black.
    context.fillStyle = '#fff'
    context.fillRect(0, 0, size.width, size.height)
  }
  context.drawImage(bitmap, 0, 0, size.width, size.height)
  const blob = await canvas.convertToBlob({ type: attempt.format === 'png' ? 'image/png' : 'image/jpeg', quality: 0.88 })
  return { bytes: new Uint8Array(await blob.arrayBuffer()), ...size }
}

async function encodeWithSystem(bytes: Uint8Array, attempt: EncodeAttempt): Promise<{ bytes: Uint8Array; width: number; height: number } | undefined> {
  const converted = await window.talaria.files.convertImage(bytes, {
    format: attempt.format, ...(attempt.maxPixels ? { maxPixels: attempt.maxPixels } : {}),
  })
  return converted ?? undefined
}
