import { GatewayClientError, type GatewayClient } from '../../client.ts'
import { describeError } from '../../describe.ts'
import { Observable } from '../../observable.ts'
import { splitLeadingAttachmentRefs, type TranscriptImage } from '../../session/items.ts'
import type { ChatSession } from '../../session/chat-session.ts'
import { AttachmentError, FileAttachmentPolicy, ImageAttachmentPolicy, formatBytes } from './policy.ts'
import { detachImage, StrandedImages, type StrandedImage } from './stranded.ts'
import { originalFileNames } from '../../media/file-names.ts'

/**
 * An image waiting in the composer (HermesKit's `ComposerAttachment`), already in a
 * format Hermes takes (`ImageAttachmentPolicy.canSendUnchanged`). It is uploaded to the
 * session's image queue as soon as it is added, as Claude Code does (§10.3).
 */
export interface ComposerImage {
  readonly id: string
  /** Sent as `filename`; its extension decides the stored type on the gateway. */
  readonly filename: string
  readonly bytes: Uint8Array
  readonly width?: number
  readonly height?: number
  /** Where it came from (a file path); shown instead of the size line when set. */
  readonly source?: string
}

/** The card's second line: the source path, else `1920×1080 · 2.4 MB`. */
export function imageDetail(image: ComposerImage): string {
  if (image.source) return image.source
  const parts: string[] = []
  if (image.width && image.height) parts.push(`${image.width}×${image.height}`)
  parts.push(formatBytes(image.bytes.byteLength))
  return parts.join(' · ')
}

/**
 * A non-image file waiting in the composer (HermesKit's `ComposerFile`): already staged
 * on the gateway with `file.attach`; its `@file:` reference goes in front of the text.
 */
export interface ComposerFile {
  readonly id: string
  /** The name the user gave it (shown everywhere). */
  readonly name: string
  /** The name the gateway stored it under, which differs when that name was taken. */
  readonly storedName: string
  readonly byteCount: number
  /** `@file:<ref_path>`, quoted when needed. */
  readonly refText: string
  /** Where the gateway stored it, absolute. */
  readonly path?: string
}

/** Where the gateway stored a file: its reference's value. */
export function fileRefPath(file: ComposerFile): string {
  return splitLeadingAttachmentRefs(file.refText).refs[0] ?? file.name
}

/** An image uploaded ahead of its prompt: its path in a runtime session's queue. */
export interface QueuedImage {
  path: string
  sessionID: string
}

export interface AttachmentsView {
  readonly images: readonly ComposerImage[]
  readonly files: readonly ComposerFile[]
  /** Files `file.attach` is uploading, in the order they started: a pending card each. */
  readonly uploadingFiles: readonly { id: string; name: string }[]
  /** Image cards still uploading to the session's queue; Send waits for them. */
  readonly uploadingImageIDs: readonly string[]
  /** Image cards whose upload failed, with why; the send uploads them again. */
  readonly failedImageUploads: Readonly<Record<string, string>>
}

/** What a send took from the composer, for `send` and to put back after a failure. */
export interface TakenAttachments {
  images: readonly ComposerImage[]
  files: readonly ComposerFile[]
  queued: ReadonlyMap<string, QueuedImage>
}

/**
 * What `ChatSession.send` needs to send a prompt with attachments: the bubble's images
 * and file names, the text Hermes gets (the files' references in front of the typed
 * text, as Desktop sends it, `use-prompt-actions/submit.ts:224-234`), and the uploads
 * to run once the chat's runtime is known.
 */
export interface PromptAttachments {
  readonly bubble: { images: TranscriptImage[]; attachments: string[]; attachmentPaths: string[] }
  readonly prompt: string
  /** Uploads what is not queued in this runtime yet; returns the bubble's images with their paths. */
  prepare(client: GatewayClient, sessionID: string, cancelled: () => boolean): Promise<TranscriptImage[]>
}

let counter = 0
export function attachmentID(): string {
  counter += 1
  return `attachment-${Date.now().toString(36)}-${counter}`
}

/**
 * The images and files attached to one chat's composer (the attachment half of
 * HermesKit's `ChatComposer`). Images upload to the session's image queue as soon as
 * they are added and files to its attachments folder, so Send only submits; removing a
 * card takes its image back off the queue (`image.detach`). Images whose detach got no
 * answer are stranded on the connection and detached before the next send.
 */
export class AttachmentTray extends Observable<AttachmentsView> {
  private queued = new Map<string, QueuedImage>()
  private readonly uploads = new Map<string, Promise<void>>()
  private readonly fileUploads = new Set<Promise<unknown>>()
  /** A send holds the cards: removing one is ignored meanwhile. */
  isSending = false

  constructor(
    private readonly session: ChatSession,
    readonly stranded: StrandedImages,
    private readonly report: (message: string | undefined) => void,
  ) {
    super({ images: [], files: [], uploadingFiles: [], uploadingImageIDs: [], failedImageUploads: {} })
  }

  private update(change: Partial<AttachmentsView>): void {
    this.set({ ...this.get(), ...change })
  }

  get hasCards(): boolean {
    const view = this.get()
    return view.images.length > 0 || view.files.length > 0
  }

  /** Something still uploading: Send waits (images) or is off (files). */
  get isUploading(): boolean {
    const view = this.get()
    return view.uploadingImageIDs.length > 0 || view.uploadingFiles.length > 0
  }

  get isUploadingFiles(): boolean {
    return this.get().uploadingFiles.length > 0
  }

  /**
   * Adds an image already in a format Hermes takes, and starts its upload. False, with
   * the reason reported, when it cannot be attached.
   */
  attachImage(image: ComposerImage): boolean {
    const rejection = ImageAttachmentPolicy.rejection(image.filename, image.bytes.byteLength)
    if (rejection) {
      this.report(rejection)
      return false
    }
    if (this.get().images.length >= ImageAttachmentPolicy.maxAttachments) {
      this.report(`At most ${ImageAttachmentPolicy.maxAttachments} images per message.`)
      return false
    }
    this.update({ images: [...this.get().images, image] })
    this.report(undefined)
    this.queueAhead(image)
    return true
  }

  /**
   * Attaches a picked, pasted or dropped file. An image Hermes takes as it is becomes an
   * image card; anything else (PDFs too, as in Desktop) is uploaded now with
   * `file.attach` and becomes a file card. Convert other images first.
   */
  async attachFile(bytes: Uint8Array, filename: string, mimeType?: string): Promise<boolean> {
    if (ImageAttachmentPolicy.canSendUnchanged(filename)) return this.attachImage({ id: attachmentID(), filename, bytes })
    const reason = FileAttachmentPolicy.rejection(bytes.byteLength)
    if (reason) {
      this.report(AttachmentError.attachmentFailed(filename, reason).message)
      return false
    }
    this.report(undefined)
    const pending = { id: attachmentID(), name: filename }
    this.update({ uploadingFiles: [...this.get().uploadingFiles, pending] })
    const upload = this.uploadFile(bytes, filename, mimeType)
    this.fileUploads.add(upload)
    try {
      const file = await upload
      this.update({ files: [...this.get().files, file] })
      return true
    } catch (error) {
      this.report(error instanceof AttachmentError ? error.message : `Couldn't attach ${filename}: ${describeError(error)}`)
      return false
    } finally {
      this.fileUploads.delete(upload)
      this.update({ uploadingFiles: this.get().uploadingFiles.filter((each) => each !== pending) })
    }
  }

  private async uploadFile(bytes: Uint8Array, filename: string, mimeType?: string): Promise<ComposerFile> {
    const client = await this.liveClient()
    let result: { attached?: boolean; name?: string; path?: string; ref_text?: string } | null
    try {
      result = await client.call('file.attach', {
        session_id: this.session.sessionID, name: filename,
        data_url: `data:${mimeType || 'application/octet-stream'};base64,${base64(bytes)}`,
      }, uploadTimeoutMs) as typeof result
    } catch (error) {
      throw AttachmentError.attachmentFailed(filename, describeError(error))
    }
    if (!result?.attached || !result.ref_text) throw AttachmentError.attachmentFailed(filename, 'the gateway did not stage it')
    const file: ComposerFile = {
      id: attachmentID(), name: filename, storedName: result.name || filename, byteCount: bytes.byteLength, refText: result.ref_text,
      ...(result.path ? { path: result.path } : {}),
    }
    originalFileNames.remember([fileRefPath(file), result.path], filename)
    return file
  }

  /**
   * Uploads a card's image to the session's queue now. A card removed meanwhile is taken
   * back off the queue once its upload ends. A failed upload is marked on the card.
   */
  private queueAhead(image: ComposerImage): void {
    const id = image.id
    const failed = { ...this.get().failedImageUploads }
    delete failed[id]
    this.update({ uploadingImageIDs: [...this.get().uploadingImageIDs, id], failedImageUploads: failed })
    const upload = (async () => {
      let queued: QueuedImage | undefined
      let failure: string | undefined
      try {
        const client = await this.liveClient()
        queued = await queueImage(client, this.session.sessionID, this.session.profile, image)
      } catch (error) {
        failure = error instanceof AttachmentError ? error.message : describeError(error)
      }
      const kept = this.get().images.some((each) => each.id === id)
      this.uploads.delete(id)
      this.update({ uploadingImageIDs: this.get().uploadingImageIDs.filter((each) => each !== id) })
      if (queued) {
        if (kept) this.queued.set(id, queued)
        else void this.unqueue(queued)
      } else if (kept && failure !== undefined) {
        this.update({ failedImageUploads: { ...this.get().failedImageUploads, [id]: failure } })
      }
    })()
    this.uploads.set(id, upload)
  }

  /** Waits for the image uploads under way. */
  async uploadsSettled(): Promise<void> {
    await Promise.all([...this.uploads.values()])
  }

  /** Removes a card; an image already uploaded comes off the session's queue. */
  remove(id: string): void {
    if (this.isSending) return
    const view = this.get()
    const failed = { ...view.failedImageUploads }
    delete failed[id]
    this.update({
      images: view.images.filter((image) => image.id !== id),
      files: view.files.filter((file) => file.id !== id),
      failedImageUploads: failed,
    })
    const queued = this.queued.get(id)
    if (queued) {
      this.queued.delete(id)
      void this.unqueue(queued)
    }
  }

  /** Takes every card for a send; they leave the composer at once. */
  take(): TakenAttachments {
    const view = this.get()
    const taken = { images: view.images, files: view.files, queued: this.queued }
    this.queued = new Map()
    this.update({ images: [], files: [], failedImageUploads: {} })
    return taken
  }

  /**
   * Puts a failed send's cards back in front of any added meanwhile. The failed send took
   * its images off the queue (`release`), so the next send uploads them again.
   */
  restore(taken: TakenAttachments): void {
    const view = this.get()
    this.update({ images: [...taken.images, ...view.images], files: [...taken.files, ...view.files] })
  }

  /** Everything this send needs from the cards it took (`ChatSession.send`). */
  promptFor(text: string, taken: TakenAttachments): PromptAttachments & { release(): Promise<void> } {
    const trimmed = text.trim()
    const refs = taken.files.map((file) => file.refText).join('\n')
    const prompt = [refs, trimmed].filter((part) => part !== '').join('\n\n')
    const shown = taken.images.map((image, position) => ({ name: image.filename, localID: image.id, position }))
    const uploaded: QueuedImage[] = []
    const tray = this
    return {
      bubble: { images: shown, attachments: taken.files.map((file) => file.name), attachmentPaths: taken.files.map(fileRefPath) },
      prompt,
      async prepare(client, sessionID, cancelled) {
        const paths: string[] = []
        for (const image of taken.images) {
          const early = taken.queued.get(image.id)
          if (early && early.sessionID === sessionID) {
            uploaded.push(early)
            paths.push(early.path)
            continue
          }
          const queued = await queueImage(client, sessionID, tray.session.profile, image)
          uploaded.push(queued)
          paths.push(queued.path)
          if (cancelled()) break
        }
        const shownImages: TranscriptImage[] = []
        taken.images.forEach((image, position) => {
          const path = paths[position]
          if (path !== undefined) shownImages.push({ name: image.filename, path, localID: image.id, position })
        })
        return shownImages
      },
      /**
       * After a failed send: every image it queued, early or not, comes off the queue
       * (detached, or stranded when there is no answer), so a retry uploads them again.
       */
      async release() {
        const early = [...taken.queued.values()].filter((image) => !uploaded.includes(image))
        await Promise.all([...uploaded, ...early].map((image) => tray.unqueue(image)))
      },
    }
  }

  /** Takes a queued image back; one whose detach gets no answer is stranded. */
  private async unqueue(image: QueuedImage): Promise<void> {
    const stranded: StrandedImage = {
      sessionID: image.sessionID, path: image.path,
      ...(this.session.profile !== undefined ? { profile: this.session.profile } : {}),
    }
    const client = this.client()
    if (!client || !(await detachImage(stranded, client))) this.stranded.strand([stranded])
  }

  private client(): GatewayClient | undefined {
    return this.session.client
  }

  private async liveClient(): Promise<GatewayClient> {
    try {
      return await this.session.liveClient()
    } catch (error) {
      if (error instanceof GatewayClientError && error.kind === 'notConnected') throw AttachmentError.notConnected()
      throw error
    }
  }
}

/** Up to 25 MB of base64 over the socket; files get the same time (HermesKit's 300 s). */
export const uploadTimeoutMs = 300_000

/** `image.attach_bytes`: uploads an image and queues it for the session's next turn. */
async function queueImage(client: GatewayClient, sessionID: string, profile: string | undefined, image: ComposerImage): Promise<QueuedImage> {
  let result: { attached?: boolean; path?: string; message?: string } | null
  try {
    result = await client.call('image.attach_bytes', {
      session_id: sessionID, content_base64: base64(image.bytes), filename: image.filename,
      ...(profile !== undefined ? { profile } : {}),
    }, uploadTimeoutMs) as typeof result
  } catch (error) {
    throw AttachmentError.attachmentFailed(image.filename, describeError(error))
  }
  if (!result?.attached || !result.path) {
    throw AttachmentError.attachmentFailed(image.filename, result?.message || 'the gateway did not queue it')
  }
  return { path: result.path, sessionID }
}

declare function btoa(data: string): string

/** Standard base64, in chunks (no Node `Buffer` in the core). */
export function base64(bytes: Uint8Array): string {
  let binary = ''
  const chunk = 0x8000
  for (let index = 0; index < bytes.length; index += chunk) {
    binary += String.fromCharCode(...bytes.subarray(index, index + chunk))
  }
  return btoa(binary)
}
