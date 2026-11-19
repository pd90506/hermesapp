import { avatarMaxBytes, avatarUploadEdge } from '@talaria/hermes-core'

/**
 * A picked image file as the avatar `profiles.set_asset` takes: its centre square,
 * scaled to 256 px, as a PNG data URL (the Mac's `AvatarImages.uploadPNG`, Desktop's
 * `normalizeAvatarImage`). The browser decodes it, upright (EXIF orientation applied).
 */
export async function avatarUpload(file: Blob): Promise<string> {
  const bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' })
  try {
    const side = Math.min(bitmap.width, bitmap.height)
    const canvas = document.createElement('canvas')
    canvas.width = avatarUploadEdge
    canvas.height = avatarUploadEdge
    const context = canvas.getContext('2d')
    if (!context) throw new Error('This image can’t be read.')
    context.imageSmoothingQuality = 'high'
    context.drawImage(bitmap, (bitmap.width - side) / 2, (bitmap.height - side) / 2, side, side,
      0, 0, avatarUploadEdge, avatarUploadEdge)
    const url = canvas.toDataURL('image/png')
    // base64 is 4/3 of the bytes.
    if ((url.length - url.indexOf(',') - 1) * 0.75 > avatarMaxBytes) throw new Error('The image is too large.')
    return url
  } finally {
    bitmap.close()
  }
}
