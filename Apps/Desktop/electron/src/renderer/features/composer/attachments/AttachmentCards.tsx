import { useState } from 'react'
import { fileKind, formatBytes, imageDetail, type ComposerFile, type ComposerImage } from '@talaria/hermes-core'
import { useConnection, useSnapshot } from '../../../app/hooks.ts'
import { actionIcons, fileIcons } from '../../chat/blocks/media/icons.ts'
import { ImageViewer } from '../../chat/blocks/media/MediaViews.tsx'
import { localImageURL, rememberLocalImage } from '../../chat/blocks/media/local-images.ts'
import type { ComposerSlotProps } from '../slots.ts'
import styles from './Attachments.module.css'

function Glyph({ path }: { path: string }) {
  return <svg className={styles.glyph} viewBox="0 0 16 16" aria-hidden="true"><path d={path} /></svg>
}

/**
 * The composer's attachment cards, above the text (the Mac's `AttachmentCardView`, drawn
 * as Hermes Desktop's pills): an image's thumbnail or a file's icon, its name and a detail
 * line, a ring while it uploads, a mark when its upload failed, and × on hover to remove it.
 */
export function AttachmentCards({ composer }: ComposerSlotProps) {
  const tray = composer.attachments
  const view = useSnapshot(tray)
  if (view.images.length === 0 && view.files.length === 0 && view.uploadingFiles.length === 0) return null
  return (
    <div className={styles.cards} data-slot="composer-attachments">
      {view.images.map((image) => (
        <ImagePill key={image.id} image={image} uploading={view.uploadingImageIDs.includes(image.id)}
          failure={view.failedImageUploads[image.id]} onRemove={() => tray.remove(image.id)} />
      ))}
      {view.files.map((file) => <FilePill key={file.id} file={file} onRemove={() => tray.remove(file.id)} />)}
      {view.uploadingFiles.map((file) => (
        <Pill key={file.id} label={file.name} detail="Uploading…" icon={fileIcons[fileKind(file.name)]} uploading />
      ))}
    </div>
  )
}

function ImagePill({ image, uploading, failure, onRemove }: {
  image: ComposerImage; uploading: boolean; failure?: string; onRemove: () => void
}) {
  const connection = useConnection()
  const [viewing, setViewing] = useState(false)
  const url = localImageURL(image.id) ?? rememberLocalImage(image)
  return (
    <>
      <Pill label={image.filename} detail={failure ?? imageDetail(image)} thumbnail={url} uploading={uploading}
        failed={failure !== undefined} title={failure ?? image.source} onOpen={() => setViewing(true)} onRemove={onRemove} />
      {viewing && <ImageViewer connection={connection} name={image.filename} preview={url} localURL={url} onClose={() => setViewing(false)} />}
    </>
  )
}

function FilePill({ file, onRemove }: { file: ComposerFile; onRemove: () => void }) {
  return <Pill label={file.name} detail={formatBytes(file.byteCount)} icon={fileIcons[fileKind(file.name)]} title={file.path} onRemove={onRemove} />
}

function Pill({ label, detail, thumbnail, icon, uploading = false, failed = false, title, onOpen, onRemove }: {
  label: string
  detail?: string
  thumbnail?: string
  icon?: string
  uploading?: boolean
  failed?: boolean
  title?: string
  onOpen?: () => void
  onRemove?: () => void
}) {
  return (
    <div className={styles.pillWrap}>
      <button type="button" className={styles.pill} data-failed={failed || undefined} aria-busy={uploading || undefined}
        aria-label={onOpen ? `Preview ${label}` : label} title={title !== label ? title : undefined} disabled={!onOpen || uploading} onClick={onOpen}>
        <span className={styles.thumb}>
          {thumbnail ? <img className={styles.thumbImage} src={thumbnail} alt="" draggable={false} /> : <Glyph path={icon ?? fileIcons.other} />}
          {uploading && <span className={styles.thumbOverlay}><span className={styles.spinner} aria-hidden="true" /></span>}
          {failed && <span className={styles.thumbFailed}><Glyph path={actionIcons.alert} /></span>}
        </span>
        <span className={styles.text}>
          <span className={styles.label}>{label}</span>
          {detail && <span className={styles.detail}>{detail}</span>}
        </span>
      </button>
      {onRemove && (
        <button type="button" className={styles.remove} aria-label={`Remove ${label}`} title="Remove" onClick={onRemove}>
          <svg viewBox="0 0 16 16" aria-hidden="true"><path d={actionIcons.close} /></svg>
        </button>
      )}
    </div>
  )
}
