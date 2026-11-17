/// Which of Windows' own CJK fonts draws Han characters, by the user's languages.
///
/// Chinese, Japanese and Korean share Unicode's Han characters but draw many of them
/// differently. Flutter asks Windows for a fallback font with the app's locale, and an
/// app on an English Windows gets Yu Gothic (Japanese forms) for Chinese text. So the
/// app names the fallback fonts itself, in the order the user's Windows languages
/// (Settings > Time & language > Language) call for, and tags text with that language,
/// which picks the right forms in fonts that carry several. Only fonts Windows ships are
/// used; nothing is bundled.
library;

import 'dart:ui';

class CjkFonts {
  const CjkFonts({required this.locale, required this.fallback});

  /// The language Han characters are drawn in: tag text with it.
  final Locale locale;

  /// Fonts to try after the UI font, the user's CJK font first.
  final List<String> fallback;

  static const _simplified = 'Microsoft YaHei UI';
  static const _traditional = 'Microsoft JhengHei UI';
  static const _japanese = 'Yu Gothic UI';
  static const _korean = 'Malgun Gothic';

  /// From the user's preferred languages, first first: the first Chinese, Japanese or
  /// Korean one decides. With none (an English Windows with no Asian language added),
  /// Simplified Chinese.
  static CjkFonts pick(List<Locale> preferred) {
    for (final l in preferred) {
      switch (l.languageCode.toLowerCase()) {
        case 'zh':
          final traditional = l.scriptCode == 'Hant' || const {'TW', 'HK', 'MO'}.contains(l.countryCode);
          return traditional
              ? _make(const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'), _traditional)
              : _make(const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'), _simplified);
        case 'ja':
          return _make(const Locale('ja'), _japanese);
        case 'ko':
          return _make(const Locale('ko'), _korean);
      }
    }
    return _make(const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'), _simplified);
  }

  static CjkFonts _make(Locale locale, String first) => CjkFonts(
        locale: locale,
        fallback: [
          first,
          for (final f in const [_simplified, _traditional, _japanese, _korean])
            if (f != first) f,
          'Segoe UI Emoji',
          'Segoe UI Symbol',
        ],
      );
}
