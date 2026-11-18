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
    this.tool,
    this.outcome,
    this.isBlank = false,
    this.hasActionBar = false,
    this.notice,
    this.review,
    this.isCompressionNote = false,
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

  /// A tool item's call, as HermesKit's `ToolCallView` draws it.
  final ToolCall? tool;

  /// `interrupted` for a reply cut short.
  final String? outcome;

  /// A reply with nothing to show yet: the waiting row stands in for it.
  final bool isBlank;

  /// The reply has the Copy bar under it.
  final bool hasActionBar;

  /// A background notice Hermes wrote as a user turn; what the review saved.
  final Note? notice;
  final Note? review;
  final bool isCompressionNote;

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
        tool: j['tool'] is Map ? ToolCall.fromJson((j['tool'] as Map).cast()) : null,
        outcome: j['outcome'] as String?,
        isBlank: j['isBlank'] as bool? ?? false,
        hasActionBar: j['hasActionBar'] as bool? ?? false,
        notice: Note.from(j['notice']),
        review: Note.from(j['review']),
        isCompressionNote: j['isCompressionNote'] as bool? ?? false,
      );
}

class Note {
  const Note({required this.headline, this.detail = ''});
  final String headline;
  final String detail;
  static Note? from(Object? j) =>
      j is Map ? Note(headline: j['headline'] as String? ?? '', detail: j['detail'] as String? ?? '') : null;
}

enum ToolStatus { running, success, error, notice, warning }

/// A tool call as HermesKit's `ToolCallView` draws it (docs/desktop-bridge.md,
/// "Transcript"): texts clamped, a diff in its display form, output without ANSI codes.
class ToolCall {
  const ToolCall({
    required this.toolName,
    required this.title,
    this.status = ToolStatus.success,
    this.isPending = false,
    this.isFileEdit = false,
    this.isExpandable = false,
    this.opensByDefault = false,
    this.isHidden = false,
    this.hasBody = false,
    this.showsDetail = false,
    this.rendersDetailAsCode = false,
    this.detail = '',
    this.detailLabel = '',
    this.errorSummary = '',
    this.detailBody = '',
    this.countLabel,
    this.durationLabel,
    this.inlineDiff = '',
    this.added = 0,
    this.removed = 0,
    this.searchQuery,
    this.searchHits = const [],
    this.stdout,
    this.stderr,
    this.terminalCommand,
    this.terminalExitCode,
  });
  final String toolName, title;
  final ToolStatus status;
  final bool isPending, isFileEdit, isExpandable, opensByDefault, isHidden, hasBody, showsDetail, rendersDetailAsCode;
  final String detail, detailLabel, errorSummary, detailBody, inlineDiff;
  final String? countLabel, durationLabel, searchQuery, stdout, stderr, terminalCommand;
  final int added, removed;
  final int? terminalExitCode;
  final List<SearchHit> searchHits;

  static ToolCall fromJson(Map<String, Object?> j) => ToolCall(
        toolName: j['toolName'] as String? ?? 'tool',
        title: j['title'] as String? ?? '',
        status: ToolStatus.values.asNameMap()[j['status']] ?? ToolStatus.success,
        isPending: j['isPending'] as bool? ?? false,
        isFileEdit: j['isFileEdit'] as bool? ?? false,
        isExpandable: j['isExpandable'] as bool? ?? false,
        opensByDefault: j['opensByDefault'] as bool? ?? false,
        isHidden: j['isHidden'] as bool? ?? false,
        hasBody: j['hasBody'] as bool? ?? false,
        showsDetail: j['showsDetail'] as bool? ?? false,
        rendersDetailAsCode: j['rendersDetailAsCode'] as bool? ?? false,
        detail: j['detail'] as String? ?? '',
        detailLabel: j['detailLabel'] as String? ?? '',
        errorSummary: j['errorSummary'] as String? ?? '',
        detailBody: j['detailBody'] as String? ?? '',
        countLabel: j['countLabel'] as String?,
        durationLabel: j['durationLabel'] as String?,
        inlineDiff: j['inlineDiff'] as String? ?? '',
        added: (j['added'] as num?)?.toInt() ?? 0,
        removed: (j['removed'] as num?)?.toInt() ?? 0,
        searchQuery: j['searchQuery'] as String?,
        searchHits: _list(j['searchHits'])
            .map((h) => SearchHit(
                title: h['title'] as String? ?? '',
                url: h['url'] as String? ?? '',
                snippet: h['snippet'] as String? ?? ''))
            .toList(),
        stdout: j['stdout'] as String?,
        stderr: j['stderr'] as String?,
        terminalCommand: j['terminalCommand'] as String?,
        terminalExitCode: (j['terminalExitCode'] as num?)?.toInt(),
      );
}

class SearchHit {
  const SearchHit({required this.title, required this.url, required this.snippet});
  final String title, url, snippet;
}

/// A block of the transcript (HermesKit's `Transcript.blocks`): a message, or a turn's
/// work before its answer.
sealed class TranscriptBlock {
  const TranscriptBlock(this.id);
  final String id;

  static TranscriptBlock? fromJson(Map<String, Object?> j) {
    final id = j['id'] as String? ?? '';
    if (j['kind'] == 'work' && j['work'] is Map) return WorkBlock(id, TurnWork.fromJson((j['work'] as Map).cast()));
    if (j['item'] case final String item) return ItemBlock(id, item);
    return null;
  }
}

class ItemBlock extends TranscriptBlock {
  const ItemBlock(super.id, this.item);
  final String item;
}

class WorkBlock extends TranscriptBlock {
  const WorkBlock(super.id, this.work);
  final TurnWork work;
}

/// A turn's work (HermesKit's `TurnWork`): "Working… 12s" while live, else [title].
class TurnWork {
  const TurnWork({
    required this.isLive,
    this.startedAt,
    this.duration,
    this.interrupted = false,
    this.title = '',
    this.entries = const [],
  });
  final bool isLive;
  final DateTime? startedAt;
  final Duration? duration;
  final bool interrupted;
  final String title;
  final List<WorkEntry> entries;

  static TurnWork fromJson(Map<String, Object?> j) => TurnWork(
        isLive: j['isLive'] as bool? ?? false,
        startedAt: _seconds(j['startedAt']),
        duration: j['duration'] is num ? Duration(milliseconds: ((j['duration'] as num) * 1000).round()) : null,
        interrupted: j['interrupted'] as bool? ?? false,
        title: j['title'] as String? ?? '',
        entries: _list(j['entries']).map(WorkEntry.fromJson).toList(),
      );
}

/// Commentary or a card (an item), or a group of steps.
class WorkEntry {
  const WorkEntry({required this.id, this.item, this.group});
  final String id;
  final String? item;
  final StepGroup? group;

  static WorkEntry fromJson(Map<String, Object?> j) {
    final group = j['group'];
    return WorkEntry(
      id: j['id'] as String? ?? '',
      item: j['item'] as String?,
      group: group is Map ? StepGroup.fromJson(group.cast()) : null,
    );
  }
}

class StepGroup {
  const StepGroup(
      {required this.id, this.isLive = false, this.title = '', this.summary = '', this.iconTool, this.steps = const []});
  final String id;
  final bool isLive;
  final String title, summary;
  final String? iconTool;
  final List<WorkStep> steps;

  static StepGroup fromJson(Map<String, Object?> j) => StepGroup(
        id: j['id'] as String? ?? '',
        isLive: j['isLive'] as bool? ?? false,
        title: j['title'] as String? ?? '',
        summary: j['summary'] as String? ?? '',
        iconTool: j['iconTool'] as String?,
        steps: _list(j['steps']).map(WorkStep.fromJson).toList(),
      );
}

/// One step: "Bash · git status", "Think · Checking the build".
class WorkStep {
  const WorkStep({
    required this.id,
    required this.isThink,
    required this.item,
    this.isLive = false,
    this.label = '',
    this.summary = '',
    this.toolName,
    this.failed = false,
    this.workdir,
    this.copyText = '',
  });
  final String id;
  final bool isThink;
  final String item;
  final bool isLive;
  final String label, summary;
  final String? toolName;
  final bool failed;
  final String? workdir;
  final String copyText;

  static WorkStep fromJson(Map<String, Object?> j) => WorkStep(
        id: j['id'] as String? ?? '',
        isThink: j['kind'] == 'think',
        item: j['item'] as String? ?? '',
        isLive: j['isLive'] as bool? ?? false,
        label: j['label'] as String? ?? '',
        summary: j['summary'] as String? ?? '',
        toolName: j['toolName'] as String?,
        failed: j['failed'] as bool? ?? false,
        workdir: j['workdir'] as String?,
        copyText: j['copyText'] as String? ?? '',
      );
}

/// The reply's stand-in while it is awaited: [label] and the time since [since].
class Waiting {
  const Waiting({required this.label, this.hint, this.since});
  final String label;
  final String? hint;
  final DateTime? since;

  static Waiting? from(Object? j) => j is Map
      ? Waiting(label: j['label'] as String? ?? 'Thinking…', hint: j['hint'] as String?, since: _seconds(j['since']))
      : null;
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
              isClosed: code['isClosed'] as bool? ?? true,
              spans: _list(code['spans'])
                  .map((s) => (text: s['text'] as String? ?? '', kind: s['kind'] as String? ?? 'plain'))
                  .toList()),
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
  const MdCode({this.language, required this.text, this.isClosed = true, this.spans = const []});
  final String? language;
  final String text;
  final bool isClosed;

  /// The code cut into spans with their kind (`keyword`, `string`, `comment`, `number`,
  /// `type`, `function`, `literal`, `plain`), from HermesKit's `CodeHighlighter`.
  final List<({String text, String kind})> spans;
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
    this.blocks = const [],
    this.newestMessageID,
    this.waiting,
    this.status,
    this.canBranch = false,
  });
  final String? sessionID;
  final String? storedSessionID;
  final String? profile;
  final String? title;
  final bool isRunning;
  final String? lastError;
  final List<ChatItem> items;

  /// The transcript's blocks, in order (HermesKit's grouping).
  final List<TranscriptBlock> blocks;

  /// The last prompt or reply: its action bar shows without hover.
  final String? newestMessageID;
  final Waiting? waiting;

  /// The running turn's status line.
  final String? status;

  /// Branch in New Chat is offered (not in a Bot Chat).
  final bool canBranch;

  bool get isOpen => sessionID != null;

  static ChatSnapshot fromJson(Map<String, Object?> j) => ChatSnapshot(
        sessionID: j['sessionID'] as String?,
        storedSessionID: j['storedSessionID'] as String?,
        profile: j['profile'] as String?,
        title: j['title'] as String?,
        isRunning: j['isRunning'] as bool? ?? false,
        lastError: j['lastError'] as String?,
        items: _list(j['items']).map(ChatItem.fromJson).toList(),
        blocks: _list(j['blocks']).map(TranscriptBlock.fromJson).whereType<TranscriptBlock>().toList(),
        newestMessageID: j['newestMessageID'] as String?,
        waiting: Waiting.from(j['waiting']),
        status: j['status'] as String?,
        canBranch: j['canBranch'] as bool? ?? false,
      );
}

Iterable<Map<String, Object?>> _list(Object? v) => (v as List?)?.cast<Map<String, Object?>>() ?? const [];

DateTime? _seconds(Object? v) =>
    v is num ? DateTime.fromMillisecondsSinceEpoch((v * 1000).round()) : null;
