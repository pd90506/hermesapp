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
    this.isPinned = false,
    this.group = 'recent',
    this.groupTitle,
  });
  final String id;
  final String profile;
  final String? storedID;
  final String? title;
  final String? preview;
  final DateTime? startedAt;
  final bool isUnread;

  /// The list's section (docs/desktop-bridge.md): `pinned`, `recent` (the unlabelled
  /// head, under "Sessions"), or a date range titled [groupTitle].
  final bool isPinned;
  final String group;
  final String? groupTitle;

  static SessionEntry fromJson(Map<String, Object?> j) => SessionEntry(
        id: j['id'] as String? ?? '',
        profile: j['profile'] as String? ?? '',
        storedID: j['storedID'] as String?,
        title: j['title'] as String?,
        preview: j['preview'] as String?,
        startedAt: _seconds(j['startedAt']),
        isUnread: j['isUnread'] as bool? ?? false,
        isPinned: j['isPinned'] as bool? ?? false,
        group: j['group'] as String? ?? 'recent',
        groupTitle: j['groupTitle'] as String?,
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
    this.markdown = const [],
    this.reasoningMarkdown = const [],
    this.images = const [],
    this.attachments = const [],
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

  /// An assistant item's text and reasoning, parsed by HermesKit; empty from an older bridge.
  final List<MdPart> markdown;
  final List<MdPart> reasoningMarkdown;

  /// A user item's images (`localID`: the composer card it was sent from) and files.
  final List<SentImage> images;
  final List<String> attachments;

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
        markdown: _list(j['markdown']).map(MdPart.fromJson).toList(),
        reasoningMarkdown: _list(j['reasoningMarkdown']).map(MdPart.fromJson).toList(),
        images: _list(j['images'])
            .map((i) => SentImage(
                name: i['name'] as String? ?? '', path: i['path'] as String?, localID: i['localID'] as String?))
            .toList(),
        attachments: ((j['attachments'] as List?) ?? const []).cast<String>(),
      );
}

class SentImage {
  const SentImage({required this.name, this.path, this.localID});
  final String name;
  final String? path;
  final String? localID;
}

/// The open chat's composer (docs/desktop-bridge.md, "Composer"): the model and
/// reasoning-effort pickers and the attachment cards.
class ComposerSnapshot {
  const ComposerSnapshot({
    this.sessionID,
    this.model,
    this.provider,
    this.modelLabel,
    this.providers,
    this.efforts = const [],
    this.effort = 'medium',
    this.effortLabel = 'Medium',
    this.pendingModelSwitch,
    this.error,
    this.attachments = const [],
    this.uploadingFiles = const [],
    this.isSubmitting = false,
    this.canSubmit = false,
  });
  final String? sessionID;
  final String? model;
  final String? provider;
  final String? modelLabel;

  /// Null until the models load; empty when the gateway offers none.
  final List<ModelProvider>? providers;
  final List<EffortChoice> efforts;
  final String effort;
  final String effortLabel;
  final PendingModelSwitch? pendingModelSwitch;
  final String? error;
  final List<AttachmentCard> attachments;
  final List<String> uploadingFiles;
  final bool isSubmitting;
  final bool canSubmit;

  bool get hasCards => attachments.isNotEmpty || uploadingFiles.isNotEmpty;

  static ComposerSnapshot fromJson(Map<String, Object?> j) {
    final pending = j['pendingModelSwitch'] as Map<String, Object?>?;
    return ComposerSnapshot(
      sessionID: j['sessionID'] as String?,
      model: j['model'] as String?,
      provider: j['provider'] as String?,
      modelLabel: j['modelLabel'] as String?,
      providers: j['providers'] == null
          ? null
          : _list(j['providers'])
              .map((p) => ModelProvider(
                    slug: p['slug'] as String? ?? '',
                    name: p['name'] as String? ?? '',
                    models: _list(p['models'])
                        .map((m) => ModelOption(
                              model: m['model'] as String? ?? '',
                              label: m['label'] as String? ?? '',
                              isCurrent: m['isCurrent'] as bool? ?? false,
                            ))
                        .toList(),
                  ))
              .toList(),
      efforts: _list(j['efforts'])
          .map((e) => EffortChoice(value: e['value'] as String? ?? '', label: e['label'] as String? ?? ''))
          .toList(),
      effort: j['effort'] as String? ?? 'medium',
      effortLabel: j['effortLabel'] as String? ?? 'Medium',
      pendingModelSwitch: pending == null
          ? null
          : PendingModelSwitch(
              provider: pending['provider'] as String? ?? '',
              model: pending['model'] as String? ?? '',
              label: pending['label'] as String? ?? '',
              message: pending['message'] as String? ?? '',
            ),
      error: j['error'] as String?,
      attachments: _list(j['attachments'])
          .map((a) => AttachmentCard(
                id: a['id'] as String? ?? '',
                isImage: a['kind'] == 'image',
                name: a['name'] as String? ?? '',
                detail: a['detail'] as String? ?? '',
                isUploading: a['isUploading'] as bool? ?? false,
                failure: a['failure'] as String?,
              ))
          .toList(),
      uploadingFiles: ((j['uploadingFiles'] as List?) ?? const []).cast<String>(),
      isSubmitting: j['isSubmitting'] as bool? ?? false,
      canSubmit: j['canSubmit'] as bool? ?? false,
    );
  }
}

class ModelProvider {
  const ModelProvider({required this.slug, required this.name, required this.models});
  final String slug;
  final String name;
  final List<ModelOption> models;
}

class ModelOption {
  const ModelOption({required this.model, required this.label, this.isCurrent = false});
  final String model;
  final String label;
  final bool isCurrent;
}

class EffortChoice {
  const EffortChoice({required this.value, required this.label});
  final String value;
  final String label;
}

class PendingModelSwitch {
  const PendingModelSwitch({required this.provider, required this.model, required this.label, required this.message});
  final String provider;
  final String model;
  final String label;
  final String message;
}

class AttachmentCard {
  const AttachmentCard({
    required this.id,
    required this.isImage,
    required this.name,
    required this.detail,
    this.isUploading = false,
    this.failure,
  });
  final String id;
  final bool isImage;
  final String name;
  final String detail;
  final bool isUploading;
  final String? failure;
}

/// A part of a parsed message (docs/desktop-bridge.md, "Markdown"): prose runs, a code
/// block, or a table.
class MdPart {
  const MdPart({required this.id, this.prose, this.code, this.table});
  final int id;
  final List<MdRun>? prose;
  final MdCode? code;
  final MdTable? table;

  static MdPart fromJson(Map<String, Object?> j) {
    final code = j['code'] as Map<String, Object?>?;
    final table = j['table'] as Map<String, Object?>?;
    return MdPart(
      id: j['id'] as int? ?? 0,
      prose: j['prose'] == null ? null : _list(j['prose']).map(MdRun.fromJson).toList(),
      code: code == null
          ? null
          : MdCode(
              language: code['language'] as String?,
              text: code['text'] as String? ?? '',
              isClosed: code['isClosed'] as bool? ?? true),
      table: table == null
          ? null
          : MdTable(
              alignments: (table['alignments'] as List?)?.cast<String>() ?? const [],
              header: _cells(table['header']),
              rows: ((table['rows'] as List?) ?? const []).map(_cells).toList()),
    );
  }

  static List<List<MdRun>> _cells(Object? v) =>
      ((v as List?) ?? const []).map((cell) => _list(cell).map(MdRun.fromJson).toList()).toList();
}

class MdCode {
  const MdCode({this.language, required this.text, this.isClosed = true});
  final String? language;
  final String text;
  final bool isClosed;
}

class MdTable {
  const MdTable({required this.alignments, required this.header, required this.rows});
  final List<String> alignments;
  final List<List<MdRun>> header;
  final List<List<List<MdRun>>> rows;
}

/// A run of text with its role and styles (HermesKit's `MarkdownSelection.Run`).
class MdRun {
  const MdRun({
    required this.text,
    this.role = 'body',
    this.level,
    this.bold = false,
    this.italic = false,
    this.strike = false,
    this.inlineCode = false,
    this.link,
    this.math,
    this.display = false,
    this.indents = const [],
    this.gap,
  });
  final String text;
  final String role;
  final int? level;
  final bool bold, italic, strike, inlineCode, display;
  final String? link;
  final String? math;
  final List<String> indents;
  final String? gap;

  static MdRun fromJson(Map<String, Object?> j) => MdRun(
        text: j['text'] as String? ?? '',
        role: j['role'] as String? ?? 'body',
        level: j['level'] as int?,
        bold: j['bold'] as bool? ?? false,
        italic: j['italic'] as bool? ?? false,
        strike: j['strike'] as bool? ?? false,
        inlineCode: j['inlineCode'] as bool? ?? false,
        link: j['link'] as String?,
        math: j['math'] as String?,
        display: j['display'] as bool? ?? false,
        indents: (j['indents'] as List?)?.cast<String>() ?? const [],
        gap: j['gap'] as String?,
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
