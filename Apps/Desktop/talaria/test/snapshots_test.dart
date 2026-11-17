import 'package:flutter_test/flutter_test.dart';
import 'dart:ui';

import 'package:talaria/app/snapshots.dart';
import 'package:talaria/platform/cjk_fonts.dart';
import 'package:talaria/ui/sidebar.dart' show relativeTime;

void main() {
  test('a connection snapshot reads as the bridge sends it', () {
    final s = ConnectionSnapshot.fromJson({
      'type': 'connection',
      'state': 'reconnecting',
      'detail': '2',
      'bots': [
        {'name': 'default', 'displayName': 'Default', 'isDefault': true},
      ],
      'listProfile': 'default',
      'sessions': [
        {'id': 'default/abc', 'profile': 'default', 'storedID': 'abc', 'title': 'Hi', 'startedAt': 1700000000.5, 'isUnread': true},
      ],
      'sessionListLoading': false,
    });
    expect(s.state, LinkState.reconnecting);
    expect(s.bots.single.isDefault, isTrue);
    expect(s.sessions.single.isUnread, isTrue);
    expect(s.sessions.single.startedAt, DateTime.fromMillisecondsSinceEpoch(1700000000500));
  });

  test('fields a bridge leaves out read as empty, and an unknown state as disconnected', () {
    final s = ConnectionSnapshot.fromJson({'type': 'connection', 'state': 'something-new'});
    expect(s.state, LinkState.disconnected);
    expect(s.bots, isEmpty);
    final chat = ChatSnapshot.fromJson({
      'sessionID': 's1',
      'items': [
        {'id': '1', 'role': 'tool', 'toolName': 'terminal', 'isActive': true},
        {'id': '2', 'role': 'narrator'},
      ],
    });
    expect(chat.isOpen, isTrue);
    expect(chat.items.first.role, Role.tool);
    expect(chat.items.last.role, Role.system);
  });

  test('times read as Windows lists say them', () {
    final now = DateTime(2026, 11, 17, 15, 0);
    expect(relativeTime(now.subtract(const Duration(seconds: 20)), now: now), 'Now');
    expect(relativeTime(now.subtract(const Duration(minutes: 1)), now: now), '1 minute ago');
    expect(relativeTime(now.subtract(const Duration(hours: 3)), now: now), '3 hours ago');
    expect(relativeTime(DateTime(2026, 11, 16, 23, 0), now: now), 'Yesterday');
    expect(relativeTime(DateTime(2026, 11, 2), now: now), 'Nov 2');
    expect(relativeTime(DateTime(2025, 11, 2), now: now), 'Nov 2, 2025');
  });

  test('an assistant item carries its parsed parts', () {
    final item = ChatItem.fromJson({
      'id': 'a1',
      'role': 'assistant',
      'text': '# Hi',
      'markdown': [
        {
          'id': 0,
          'prose': [
            {'text': 'Hi', 'role': 'heading', 'level': 1},
            {'text': '\n', 'role': 'separator'},
            {'text': '\t•\t', 'role': 'listMarker', 'indents': ['list'], 'gap': 'block'},
            {'text': 'go', 'role': 'body', 'bold': true, 'link': 'https://example.com', 'indents': ['list']},
          ],
        },
        {'id': 1, 'code': {'language': 'dart', 'text': 'x', 'isClosed': false}},
        {
          'id': 2,
          'table': {
            'alignments': ['leading', 'trailing'],
            'header': [
              [{'text': 'A', 'role': 'tableHeader'}],
              [{'text': 'B', 'role': 'tableHeader'}],
            ],
            'rows': [
              [
                [{'text': '1', 'role': 'tableCell'}],
                [{'text': '2', 'role': 'tableCell'}],
              ],
            ],
          },
        },
      ],
    });
    final prose = item.markdown[0].prose!;
    expect(prose.first.level, 1);
    expect(prose[2].indents, ['list']);
    expect(prose[2].gap, 'block');
    expect(prose[3].bold, isTrue);
    expect(prose[3].italic, isFalse);
    expect(prose[3].link, 'https://example.com');
    expect(item.markdown[1].code!.isClosed, isFalse);
    expect(item.markdown[2].table!.rows.single.last.single.text, '2');
    expect(item.reasoningMarkdown, isEmpty);
  });

  test('a composer snapshot reads its pickers and cards', () {
    final c = ComposerSnapshot.fromJson({
      'type': 'composer',
      'sessionID': 's1',
      'model': 'claude-sonnet-5-5',
      'modelLabel': 'Sonnet 5.5',
      'providers': [
        {
          'slug': 'custom',
          'name': 'Custom endpoint',
          'models': [
            {'model': 'claude-sonnet-5-5', 'label': 'Sonnet 5.5', 'isCurrent': true},
            {'model': 'claude-haiku-5-5', 'label': 'Haiku 5.5', 'isCurrent': false},
          ],
        },
      ],
      'efforts': [
        {'value': 'none', 'label': 'Off'},
        {'value': 'high', 'label': 'High'},
      ],
      'effort': 'high',
      'effortLabel': 'High',
      'attachments': [
        {'id': 'a', 'kind': 'image', 'name': 'Pasted Image.png', 'detail': '973 bytes', 'isUploading': true},
        {'id': 'b', 'kind': 'file', 'name': 'notes.txt', 'detail': '50 bytes'},
      ],
      'uploadingFiles': ['big.pdf'],
      'canSubmit': false,
    });
    expect(c.providers!.single.models.first.isCurrent, isTrue);
    expect(c.efforts.last.label, 'High');
    expect(c.attachments.first.isImage, isTrue);
    expect(c.attachments.first.isUploading, isTrue);
    expect(c.attachments.last.isImage, isFalse);
    expect(c.hasCards, isTrue);
    expect(const ComposerSnapshot().providers, isNull);
  });

  test('session rows carry their pin and date group', () {
    final s = ConnectionSnapshot.fromJson({
      'sessions': [
        {'id': 'p/a', 'profile': 'p', 'isPinned': true, 'group': 'pinned', 'groupTitle': 'Pinned'},
        {'id': 'p/b', 'profile': 'p', 'group': 'recent'},
        {'id': 'p/c', 'profile': 'p', 'group': 'yesterday', 'groupTitle': 'Yesterday'},
      ],
    });
    expect(s.sessions.first.isPinned, isTrue);
    expect(s.sessions[1].group, 'recent');
    expect(s.sessions[1].groupTitle, isNull);
    expect(s.sessions.last.groupTitle, 'Yesterday');
    expect(SessionEntry.fromJson({'id': 'x'}).group, 'recent');
  });

  test('Han characters follow the first Chinese, Japanese or Korean Windows language', () {
    // An English Windows with Chinese (Singapore) added: Chinese forms.
    final en = CjkFonts.pick(const [Locale('en', 'US'), Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans', countryCode: 'SG')]);
    expect(en.fallback.first, 'Microsoft YaHei UI');
    expect(en.locale.scriptCode, 'Hans');
    expect(CjkFonts.pick(const [Locale('zh', 'TW')]).fallback.first, 'Microsoft JhengHei UI');
    expect(CjkFonts.pick(const [Locale('ja', 'JP'), Locale('zh', 'CN')]).fallback.first, 'Yu Gothic UI');
    expect(CjkFonts.pick(const [Locale('ko', 'KR')]).fallback.first, 'Malgun Gothic');
    // No Asian language at all: Simplified Chinese.
    expect(CjkFonts.pick(const [Locale('en', 'US')]).fallback.first, 'Microsoft YaHei UI');
    expect(en.fallback.toSet().length, en.fallback.length);
  });
}
