/** The Mac's fallback avatar colours: the system's blue, purple, pink, orange, teal, indigo, green and brown. */
export const avatarPalette = ['#007aff', '#af52de', '#ff2d55', '#ff9500', '#30b0c7', '#5856d6', '#34c759', '#a2845e'] as const

/** Two words' first letters, else the name's first two, upper-cased (the Mac's `BotAvatar`). */
export function initials(name: string): string {
  const words = name.split(' ').filter(Boolean)
  const letters = words.length > 1 ? words.slice(0, 2).map((word) => [...word][0]).join('') : [...name].slice(0, 2).join('')
  return letters.toUpperCase()
}

/** Steady across launches: the sum of the name's code points, into the palette. */
export function fallbackColor(name: string): string {
  let sum = 0
  for (const character of name) sum += character.codePointAt(0) ?? 0
  return avatarPalette[sum % avatarPalette.length]!
}
