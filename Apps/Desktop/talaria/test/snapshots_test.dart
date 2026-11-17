import 'package:flutter_test/flutter_test.dart';
import 'package:talaria/app/snapshots.dart';
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
}
