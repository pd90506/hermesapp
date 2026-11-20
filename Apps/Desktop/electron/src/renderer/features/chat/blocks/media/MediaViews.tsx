import { useEffect, useState, type MouseEvent } from 'react'
import { createPortal } from 'react-dom'
import {
  MediaTags, deliveredFileName, fileKind, imageID, isImagePath, type ChatSession, type DeliveredFile, type GatewayConnection,
  type TranscriptImage, type TranscriptItem,
} from '@talaria/hermes-core'
import { useConnection, useSnapshot } from '../../../../app/hooks.ts'
import { Markdown } from '../../../markdown/Markdown.tsx'
import { actionIcons, fileIcons } from './icons.ts'
import { localImageURL } from './local-images.ts'
import { failureText, fullImage, openFile, saveFile, useThumbnail, type GatewayFile } from './media.ts'
import styles from './MediaViews.module.css'

function Glyph({ path, className }: { path: string; className?: string }) {
  return <svg className={className ?? styles.glyph} viewBox="0 0 16 16" aria-hidden="true"><path d={path} /></svg>
}

/**
 * A user message's images and files, above its caption (the Mac's `TranscriptImages` and
 * `TranscriptFiles`): image cards of one fixed size, so nothing moves when the bubble is
 * replaced by its stored row, then a chip per file.
 */
export function UserAttachments({ item, chat }: { item: TranscriptItem; chat: ChatSession }) {
  const view = useSnapshot(chat)
  if (item.images.length === 0 && item.attachments.length === 0) return null
  const files: GatewayFile[] = item.attachments.map((name, index) => ({
    name, path: item.attachmentPaths[index] ?? name, ...scope(view.profile, view.storedSessionID),
  }))
  return (
    <div className={styles.userMedia}>
      {item.images.length > 0 && (
        <div className={styles.imageRow}>
          {item.images.map((image) => <SentImage key={imageID(image)} image={image} chat={chat} />)}
        </div>
      )}
      {files.length > 0 && (
        <div className={styles.fileColumn}>
          {files.map((file, index) => <FileChip key={`${index}:${file.path}`} file={file} />)}
        </div>
      )}
    </div>
  )
}

function scope(profile: string | undefined, storedSessionID: string | undefined): Pick<GatewayFile, 'profile' | 'storedSessionID'> {
  return { ...(profile !== undefined ? { profile } : {}), ...(storedSessionID !== undefined ? { storedSessionID } : {}) }
}

function SentImage({ image, chat }: { image: TranscriptImage; chat: ChatSession }) {
  const view = useSnapshot(chat)
  return <ImageCard path={image.path} name={image.name} localURL={localImageURL(image.localID)}
    file={image.path ? { path: image.path, name: image.name, ...scope(view.profile, view.storedSessionID) } : undefined} />
}

/** A reply in Markdown, with the files it delivered (`MEDIA:` tags) where their tags were. */
export function MediaMarkdown({ text, streaming, chat }: { text: string; streaming: boolean; chat: ChatSession }) {
  const view = useSnapshot(chat)
  if (!text.includes('MEDIA:')) return <Markdown text={text} streaming={streaming} />
  const segments = MediaTags.segments(text, streaming)
  return (
    <div className={styles.reply}>
      {segments.map((segment, index) => segment.kind === 'markdown'
        ? <Markdown key={index} text={segment.text} streaming={streaming && index === segments.length - 1} />
        : <DeliveredFiles key={index} files={segment.files} profile={view.profile} storedSessionID={view.storedSessionID} />)}
    </div>
  )
}

function DeliveredFiles({ files, profile, storedSessionID }: { files: readonly DeliveredFile[]; profile?: string; storedSessionID?: string }) {
  const images = files.filter((file) => isImagePath(file.path))
  const others = files.filter((file) => !isImagePath(file.path))
  const gateway = (file: DeliveredFile): GatewayFile => ({ path: file.path, name: deliveredFileName(file), ...scope(profile, storedSessionID) })
  return (
    <div className={styles.delivered}>
      {images.length > 0 && (
        <div className={styles.imageRow}>
          {images.map((file) => <ImageCard key={file.path} path={file.path} name={deliveredFileName(file)} file={gateway(file)} />)}
        </div>
      )}
      {others.length > 0 && (
        <div className={styles.fileRow}>
          {others.map((file) => <FileChip key={file.path} file={gateway(file)} />)}
        </div>
      )}
    </div>
  )
}

/** An image card: the thumbnail, or a placeholder with the name while it loads or when it cannot. */
function ImageCard({ path, name, localURL, file }: { path?: string; name: string; localURL?: string; file?: GatewayFile }) {
  const connection = useConnection()
  const state = useThumbnail(connection, path, file?.profile, localURL)
  const [viewing, setViewing] = useState(false)
  const url = state?.phase === 'loaded' ? state.url : undefined
  return (
    <>
      <button type="button" className={styles.imageCard} aria-label={`View ${name}`} title={name}
        disabled={!url} onClick={() => setViewing(true)}>
        {url
          ? <img className={styles.thumbnail} src={url} alt={name} draggable={false} />
          : (
            <span className={styles.placeholder}>
              {state?.phase === 'loading' || (!state && path)
                ? <span className={styles.spinner} aria-hidden="true" />
                : <Glyph path={fileIcons.image} />}
              <span className={styles.placeholderName}>{name}</span>
            </span>
          )}
      </button>
      {viewing && url && (
        <ImageViewer connection={connection} name={name} preview={url} localURL={localURL} file={file} onClose={() => setViewing(false)} />
      )}
    </>
  )
}

/** A file: its kind's icon and name. Click opens it in its default app; the button beside saves it. */
function FileChip({ file }: { file: GatewayFile }) {
  const connection = useConnection()
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string>()
  const run = (action: () => Promise<void>) => {
    setBusy(true)
    setError(undefined)
    action().catch((failure: unknown) => setError(failureText(failure))).finally(() => setBusy(false))
  }
  const save = (event: MouseEvent) => {
    event.stopPropagation()
    run(() => saveFile(connection, file))
  }
  return (
    <div className={styles.fileChip} data-error={error ? '' : undefined}>
      <button type="button" className={styles.fileOpen} title={error ?? file.path} aria-label={`Open ${file.name}`}
        aria-busy={busy || undefined} onClick={() => run(() => openFile(connection, file))}>
        <span className={styles.fileIcon}>
          {busy ? <span className={styles.spinner} aria-hidden="true" /> : <Glyph path={error ? actionIcons.alert : fileIcons[fileKind(file.name)]} />}
        </span>
        <span className={styles.fileText}>
          <span className={styles.fileName}>{file.name}</span>
          {error && <span className={styles.fileError}>{error}</span>}
        </span>
      </button>
      <button type="button" className={styles.fileSave} title="Save…" aria-label={`Save ${file.name}`} disabled={busy} onClick={save}>
        <Glyph path={actionIcons.download} />
      </button>
    </div>
  )
}

/** The image at full size over the window (Hermes Desktop's lightbox), with Save… and Open. */
export function ImageViewer({ connection, name, preview, localURL, file, onClose }: {
  connection: GatewayConnection
  name: string
  preview: string
  localURL?: string
  file?: GatewayFile
  onClose: () => void
}) {
  const [full, setFull] = useState<string | undefined>(localURL)
  const [error, setError] = useState<string>()
  useEffect(() => {
    if (localURL || !file) return
    let live = true
    fullImage(connection, file.path, file.profile).then((url) => { if (live) setFull(url) }, () => {})
    return () => { live = false }
  }, [connection, file, localURL])
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => { if (event.key === 'Escape') onClose() }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose])
  const act = (action: (connection: GatewayConnection, file: GatewayFile) => Promise<void>) => {
    if (!file) return
    setError(undefined)
    action(connection, file).catch((failure: unknown) => setError(failureText(failure)))
  }
  return createPortal(
    <div className={styles.viewer} role="dialog" aria-label={name} onClick={onClose}>
      <div className={styles.viewerBar} onClick={(event) => event.stopPropagation()}>
        <span className={styles.viewerName}>{name}</span>
        {error && <span className={styles.viewerError} role="alert">{error}</span>}
        {file && (
          <>
            <button type="button" className={styles.viewerButton} onClick={() => act(saveFile)}>
              <Glyph path={actionIcons.download} />Save…
            </button>
            <button type="button" className={styles.viewerButton} onClick={() => act(openFile)}>
              <Glyph path={actionIcons.open} />Open
            </button>
          </>
        )}
        <button type="button" className={styles.viewerClose} aria-label="Close" title="Close (Esc)" onClick={onClose}>
          <Glyph path={actionIcons.close} />
        </button>
      </div>
      <img className={styles.viewerImage} src={full ?? preview} alt={name} onClick={(event) => event.stopPropagation()} />
    </div>,
    document.body,
  )
}
