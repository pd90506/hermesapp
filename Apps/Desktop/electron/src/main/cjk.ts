/**
 * The CJK language whose glyph forms Han characters take: the first Chinese, Japanese or
 * Korean language in the system's list, else Simplified Chinese (the Flutter app's rule,
 * PR #160). The renderer picks fonts by it (theme/tokens.css, data-cjk).
 */
export function cjkLanguage(languages: readonly string[]): 'zh-Hans' | 'zh-Hant' | 'ja' | 'ko' {
  for (const tag of languages.map((language) => language.toLowerCase())) {
    if (tag.startsWith('zh')) {
      return /hant|-tw|-hk|-mo/.test(tag) ? 'zh-Hant' : 'zh-Hans'
    }
    if (tag.startsWith('ja')) return 'ja'
    if (tag.startsWith('ko')) return 'ko'
  }
  return 'zh-Hans'
}
