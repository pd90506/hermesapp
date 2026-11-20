import type { ComposerImage } from '@talaria/hermes-core'

/**
 * Thumbnails of images sent from this device, by the composer card's id: the bubble
 * (and the card) show them without a download (the Mac's `TranscriptImage.localID`).
 * Object URLs of the cards' bytes; at most a few hundred are kept.
 */
const urls = new Map<string, string>()
const limit = 200

export function rememberLocalImage(image: ComposerImage): string {
  const existing = urls.get(image.id)
  if (existing) return existing
  const url = URL.createObjectURL(new Blob([image.bytes as BlobPart], { type: mimeFor(image.filename) }))
  urls.set(image.id, url)
  if (urls.size > limit) {
    const [oldest, oldURL] = urls.entries().next().value as [string, string]
    urls.delete(oldest)
    URL.revokeObjectURL(oldURL)
  }
  return url
}

export function localImageURL(id: string | undefined): string | undefined {
  return id === undefined ? undefined : urls.get(id)
}

function mimeFor(name: string): string {
  const ext = name.slice(name.lastIndexOf('.') + 1).toLowerCase()
  return ext === 'jpg' ? 'image/jpeg' : `image/${ext}`
}
