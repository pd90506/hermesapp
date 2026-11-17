/// The bridge's snapshots (docs/desktop-bridge.md, "Events") as typed values. Fields
/// the bridge adds later are ignored until the app uses them; a missing one reads as
/// empty, so an older bridge never breaks the views.
library;

enum LinkState { disconnected, connecting, connected, reconnecting, failed }

class Bot {
  const Bot({required this.name, required this.displayName, this.preview, this.isDefault = false});
  final String name;
  final String displayName;
  final String? preview;
  final bool isDefault;

  static Bot fromJson(Map<String, Object?> j) => Bot(
        name: j['name'] as String? ?? '',
        displayName: j['displayName'] as String? ?? j['name'] as String? ?? '',
        preview: j['preview'] as String?,
        isDefault: j['isDefault'] as bool? ?? false,
      );
}

class SessionEntry {
  const SessionEntry({
    required this.id,
    required this.profile,
    this.storedID,
    this.title,
    this.preview,
    this.startedAt,
    this.isUnread = false,
  });
  final String id;
  final String profile;
  final String? storedID;
  final String? title;
  final String? preview;
  final DateTime? startedAt;
  final bool isUnread;

  static SessionEntry fromJson(Map<String, Object?> j) => SessionEntry(
        id: j['id'] as String? ?? '',
        profile: j['profile'] as String? ?? '',
        storedID: j['storedID'] as String?,
        title: j['title'] as String?,
        preview: j['preview'] as String?,
        startedAt: _seconds(j['startedAt']),
        isUnread: j['isUnread'] as bool? ?? false,
      );
}

class ConnectionSnapshot {
  const ConnectionSnapshot({
    this.state = LinkState.disconnected,
    this.detail,
    this.bots = const [],
    this.listProfile,
    this.sessions = const [],
    this.sessionListLoading = false,
    this.sessionListError,
  });
  final LinkState state;
  final String? detail;
  final List<Bot> bots;
  final String? listProfile;
  final List<SessionEntry> sessions;
  final bool sessionListLoading;
  final String? sessionListError;

  static ConnectionSnapshot fromJson(Map<String, Object?> j) => ConnectionSnapshot(
        state: LinkState.values.asNameMap()[j['state']] ?? LinkState.disconnected,
        detail: j['detail'] as String?,
        bots: _list(j['bots']).map(Bot.fromJson).toList(),
        listProfile: j['listProfile'] as String?,
        sessions: _list(j['sessions']).map(SessionEntry.fromJson).toList(),
        sessionListLoading: j['sessionListLoading'] as bool? ?? false,
        sessionListError: j['sessionListError'] as String?,
      );
}

enum Role { user, assistant, tool, system }

class ChatItem {
  const ChatItem({
    required this.id,
    required this.role,
    this.text = '',
    this.reasoning,
    this.toolName,
    this.detail,
    this.isActive = false,
    this.outgoingStatus,
    this.timestamp,
  });
  final String id;
  final Role role;
  final String text;
  final String? reasoning;
  final String? toolName;
  final String? detail;
  final bool isActive;
  final String? outgoingStatus;
  final DateTime? timestamp;

  static ChatItem fromJson(Map<String, Object?> j) => ChatItem(
        id: j['id'] as String? ?? '',
        role: Role.values.asNameMap()[j['role']] ?? Role.system,
        text: j['text'] as String? ?? '',
        reasoning: j['reasoning'] as String?,
        toolName: j['toolName'] as String?,
        detail: j['detail'] as String?,
        isActive: j['isActive'] as bool? ?? false,
        outgoingStatus: j['outgoingStatus'] as String?,
        timestamp: _seconds(j['timestamp']),
      );
}

class ChatSnapshot {
  const ChatSnapshot({
    this.sessionID,
    this.storedSessionID,
    this.profile,
    this.title,
    this.isRunning = false,
    this.lastError,
    this.items = const [],
  });
  final String? sessionID;
  final String? storedSessionID;
  final String? profile;
  final String? title;
  final bool isRunning;
  final String? lastError;
  final List<ChatItem> items;

  bool get isOpen => sessionID != null;

  static ChatSnapshot fromJson(Map<String, Object?> j) => ChatSnapshot(
        sessionID: j['sessionID'] as String?,
        storedSessionID: j['storedSessionID'] as String?,
        profile: j['profile'] as String?,
        title: j['title'] as String?,
        isRunning: j['isRunning'] as bool? ?? false,
        lastError: j['lastError'] as String?,
        items: _list(j['items']).map(ChatItem.fromJson).toList(),
      );
}

Iterable<Map<String, Object?>> _list(Object? v) => (v as List?)?.cast<Map<String, Object?>>() ?? const [];

DateTime? _seconds(Object? v) =>
    v is num ? DateTime.fromMillisecondsSinceEpoch((v * 1000).round()) : null;
