/// The bridge's snapshots (docs/desktop-bridge.md, "Events") as typed values. Fields
/// the bridge adds later are ignored until the app uses them; a missing one reads as
/// empty, so an older bridge never breaks the views.
library;

enum LinkState { disconnected, connecting, connected, reconnecting, failed }

enum BotActivity { idle, recent, working, waitingForYou }

class Bot {
  const Bot({
    required this.name,
    required this.displayName,
    this.preview,
    this.isDefault = false,
    this.hasAvatar = false,
    this.avatarColor,
    this.avatarID,
    this.activity = BotActivity.idle,
  });
  final String name;
  final String displayName;
  final String? preview;
  final bool isDefault;

  /// The profile has an avatar image on the server; [avatarID] is set once it is
  /// loaded, and changes with it.
  final bool hasAvatar;
  final String? avatarID;

  /// The colour picked in Hermes Desktop, 0xRRGGBB.
  final int? avatarColor;

  /// What the rail's badge shows (HermesKit's `BotActivity`).
  final BotActivity activity;

  static Bot fromJson(Map<String, Object?> j) => Bot(
        name: j['name'] as String? ?? '',
        displayName: j['displayName'] as String? ?? j['name'] as String? ?? '',
        preview: j['preview'] as String?,
        isDefault: j['isDefault'] as bool? ?? false,
        hasAvatar: j['hasAvatar'] as bool? ?? false,
        avatarColor: (j['avatarColor'] as num?)?.toInt(),
        avatarID: j['avatarID'] as String?,
        activity: BotActivity.values.asNameMap()[j['activity']] ?? BotActivity.idle,
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
    this.draft = '',
    this.slashIsOpen = false,
    this.slashRows = const [],
    this.slashNotice,
    this.isModelPickerRequested = false,
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

  /// The draft as the composer holds it: kept in step by setDraft, and read back
  /// after a slash send (a prefill or a refused command may be back in it).
  final String draft;

  /// The slash list (HermesKit's): shown while [slashIsOpen]; [slashNotice] when
  /// it closed with no matches or the catalog failed to load.
  final bool slashIsOpen;
  final List<SlashRow> slashRows;
  final String? slashNotice;

  /// /model with no argument asked for the picker; the app opens its own and
  /// clears the request.
  final bool isModelPickerRequested;

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
      draft: j['draft'] as String? ?? '',
      slashIsOpen: j['slashIsOpen'] as bool? ?? false,
      slashRows: _list(j['slashRows'])
          .map((r) => SlashRow(
                id: r['id'] as String? ?? '',
                header: r['header'] as String?,
                text: r['text'] as String? ?? '',
                display: r['display'] as String? ?? '',
                meta: r['meta'] as String?,
                kind: r['kind'] as String?,
                isSelected: r['isSelected'] as bool? ?? false,
              ))
          .toList(),
      slashNotice: j['slashNotice'] as String?,
      isModelPickerRequested: j['isModelPickerRequested'] as bool? ?? false,
    );
  }
}

/// One row of the slash list, as the composer's snapshot carries it.
class SlashRow {
  const SlashRow({
    required this.id,
    this.header,
    required this.text,
    required this.display,
    this.meta,
    this.kind,
    this.isSelected = false,
  });
  final String id;
  final String? header;
  final String text;
  final String display;
  final String? meta;
  final String? kind;
  final bool isSelected;
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
    this.pendingRequests = const [],
  });
  final String? sessionID;
  final String? storedSessionID;
  final String? profile;
  final String? title;
  final bool isRunning;
  final String? lastError;
  final List<ChatItem> items;

  /// The blocking requests the agent waits on, newest last, as the transcript's
  /// cards (docs/desktop-bridge.md, "Events": chat).
  final List<PendingRequest> pendingRequests;

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
        pendingRequests: _list(j['pendingRequests']).map(PendingRequest.fromJson).toList(),
      );
}

Iterable<Map<String, Object?>> _list(Object? v) => (v as List?)?.cast<Map<String, Object?>>() ?? const [];

DateTime? _seconds(Object? v) =>
    v is num ? DateTime.fromMillisecondsSinceEpoch((v * 1000).round()) : null;

/// A blocking server→client request, as the transcript's card: approval, clarify,
/// sudo or secret (docs/desktop-bridge.md, "Events": chat).
class PendingRequest {
  const PendingRequest({
    required this.id,
    required this.kind,
    required this.method,
    required this.headline,
    this.description,
    this.command,
    this.choices = const [],
    this.questions = const [],
    this.envVar,
    this.prompt,
  });
  final String id;

  /// `approval`, `clarify`, `sudo`, `secret` or `unsupported`.
  final String kind;
  final String method;
  final String headline;
  final String? description;

  /// The command an approval asks about, a sudo request's command.
  final String? command;

  /// An approval's buttons, in order.
  final List<ApprovalChoice> choices;

  /// A clarify's questions, in order.
  final List<ClarifyQuestion> questions;

  /// A secret request's variable, and its own prompt line.
  final String? envVar;
  final String? prompt;

  static PendingRequest fromJson(Map<String, Object?> j) => PendingRequest(
        id: j['id'] as String? ?? '',
        kind: j['kind'] as String? ?? 'unsupported',
        method: j['method'] as String? ?? '',
        headline: j['headline'] as String? ?? '',
        description: j['description'] as String?,
        command: j['command'] as String?,
        choices: _list(j['choices'])
            .map((c) => ApprovalChoice(
                  value: c['value'] as String? ?? '',
                  label: c['label'] as String? ?? '',
                ))
            .toList(),
        questions: _list(j['questions'])
            .map((q) => ClarifyQuestion(
                  qid: q['qid'] as String? ?? '',
                  question: q['question'] as String? ?? '',
                  choices: ((q['choices'] as List?) ?? const []).cast<String>(),
                  multiSelect: q['multiSelect'] as bool? ?? false,
                  isLocked: q['isLocked'] as bool? ?? false,
                ))
            .toList(),
        envVar: j['envVar'] as String?,
        prompt: j['prompt'] as String?,
      );
}

class ApprovalChoice {
  const ApprovalChoice({required this.value, required this.label});
  final String value;
  final String label;
}

class ClarifyQuestion {
  const ClarifyQuestion({
    required this.qid,
    required this.question,
    this.choices = const [],
    this.multiSelect = false,
    this.isLocked = false,
  });
  final String qid;
  final String question;

  /// The choices to offer, as the wire carried them.
  final List<String> choices;

  /// Offered as checkboxes with an optional typed answer.
  final bool multiSelect;

  /// An answer was locked via clarify.lock (a replayed request): the question
  /// shows it and takes no input.
  final bool isLocked;
}

/// The session list's search results (docs/desktop-bridge.md: the `search` snapshot).
class SearchSnapshot {
  const SearchSnapshot({
    this.profile,
    this.query = '',
    this.results = const [],
    this.isSearching = false,
    this.error,
    this.isAvailable = true,
  });
  final String? profile;
  final String query;
  final List<SearchResult> results;
  final bool isSearching;
  final String? error;
  final bool isAvailable;

  static SearchSnapshot fromJson(Map<String, Object?> j) => SearchSnapshot(
        profile: j['profile'] as String?,
        query: j['query'] as String? ?? '',
        results: _list(j['results']).map(SearchResult.fromJson).toList(),
        isSearching: j['isSearching'] as bool? ?? false,
        error: j['error'] as String?,
        isAvailable: j['isAvailable'] as bool? ?? true,
      );
}

class SearchResult {
  const SearchResult({
    required this.id,
    required this.profile,
    required this.title,
    this.preview,
    this.segments = const [],
    this.role,
    this.date,
    this.messageCount,
    this.isBotChat = false,
  });

  /// `profile/storedID`, what openSession takes.
  final String id;
  final String profile;
  final String title;
  final String? preview;
  final List<SearchSegment> segments;
  final String? role;
  final DateTime? date;
  final int? messageCount;

  /// The hit's row is the profile's Bot Chat, which opens with openBotChat.
  final bool isBotChat;

  static SearchResult fromJson(Map<String, Object?> j) => SearchResult(
        id: j['id'] as String? ?? '',
        profile: j['profile'] as String? ?? '',
        title: j['title'] as String? ?? '',
        preview: j['preview'] as String?,
        segments: _list(j['segments'])
            .map((s) => SearchSegment(text: s['text'] as String? ?? '', isMatch: s['isMatch'] as bool? ?? false))
            .toList(),
        role: j['role'] as String?,
        date: _seconds(j['date']),
        messageCount: (j['messageCount'] as num?)?.toInt(),
        isBotChat: j['isBotChat'] as bool? ?? false,
      );
}

class SearchSegment {
  const SearchSegment({required this.text, required this.isMatch});
  final String text;
  final bool isMatch;
}

/// The chat's running subagents, as the pill above the composer lists them
/// (docs/desktop-bridge.md: the `subagents` snapshot).
class SubagentsSnapshot {
  const SubagentsSnapshot({this.sessionID, this.runs = const []});
  final String? sessionID;
  final List<SubagentRun> runs;

  static SubagentsSnapshot fromJson(Map<String, Object?> j) => SubagentsSnapshot(
        sessionID: j['sessionID'] as String?,
        runs: _list(j['runs']).map(SubagentRun.fromJson).toList(),
      );
}

class SubagentRun {
  const SubagentRun({
    required this.id,
    required this.goal,
    this.model,
    this.status = 'running',
    this.taskIndex = 0,
    this.taskCount = 1,
    this.startedAt,
    this.updatedAt,
    this.currentTool,
    this.activity = const [],
    this.summary,
  });
  final String id;
  final String goal;
  final String? model;

  /// `queued` or `running`.
  final String status;
  final int taskIndex;
  final int taskCount;
  final DateTime? startedAt;
  final DateTime? updatedAt;

  /// The tool it is running, while it runs.
  final String? currentTool;

  /// The newest lines, oldest first.
  final List<SubagentActivity> activity;
  final String? summary;

  static SubagentRun fromJson(Map<String, Object?> j) => SubagentRun(
        id: j['id'] as String? ?? '',
        goal: j['goal'] as String? ?? '',
        model: j['model'] as String?,
        status: j['status'] as String? ?? 'running',
        taskIndex: (j['taskIndex'] as num?)?.toInt() ?? 0,
        taskCount: (j['taskCount'] as num?)?.toInt() ?? 1,
        startedAt: _seconds(j['startedAt']),
        updatedAt: _seconds(j['updatedAt']),
        currentTool: j['currentTool'] as String?,
        activity: _list(j['activity'])
            .map((a) => SubagentActivity(
                  kind: a['kind'] as String? ?? 'progress',
                  text: a['text'] as String? ?? '',
                  isError: a['isError'] as bool? ?? false,
                ))
            .toList(),
        summary: j['summary'] as String?,
      );
}

class SubagentActivity {
  const SubagentActivity({required this.kind, required this.text, this.isError = false});
  final String kind;
  final String text;
  final bool isError;
}

/// The chat's context gauge and session counters, for the composer's ring
/// (docs/desktop-bridge.md: the `usage` snapshot).
class UsageSnapshot {
  const UsageSnapshot({this.sessionID, this.gauge, this.usage, this.breakdown});
  final String? sessionID;
  final ContextGauge? gauge;
  final SessionCounters? usage;
  final ContextBreakdown? breakdown;

  static UsageSnapshot fromJson(Map<String, Object?> j) => UsageSnapshot(
        sessionID: j['sessionID'] as String?,
        gauge: j['gauge'] is Map ? ContextGauge.fromJson(j['gauge'] as Map<String, Object?>) : null,
        usage: j['usage'] is Map ? SessionCounters.fromJson(j['usage'] as Map<String, Object?>) : null,
        breakdown:
            j['breakdown'] is Map ? ContextBreakdown.fromJson(j['breakdown'] as Map<String, Object?>) : null,
      );
}

class ContextGauge {
  const ContextGauge({required this.used, required this.max, required this.percent, this.isEstimated = false});
  final int used;
  final int max;

  /// 0…100.
  final int percent;
  final bool isEstimated;

  double get fraction => (percent / 100).clamp(0.0, 1.0);

  static ContextGauge fromJson(Map<String, Object?> j) => ContextGauge(
        used: (j['used'] as num?)?.toInt() ?? 0,
        max: (j['max'] as num?)?.toInt() ?? 0,
        percent: (j['percent'] as num?)?.toInt() ?? 0,
        isEstimated: j['isEstimated'] as bool? ?? false,
      );
}

class SessionCounters {
  const SessionCounters({
    this.input = 0,
    this.output = 0,
    this.total = 0,
    this.calls = 0,
    this.reasoning,
    this.compressions,
    this.cacheHitPercent,
    this.tokensPerSecond,
    this.costUSD,
    this.model,
  });
  final int input;
  final int output;
  final int total;
  final int calls;
  final int? reasoning;
  final int? compressions;
  final int? cacheHitPercent;
  final double? tokensPerSecond;
  final double? costUSD;
  final String? model;

  static SessionCounters fromJson(Map<String, Object?> j) => SessionCounters(
        input: (j['input'] as num?)?.toInt() ?? 0,
        output: (j['output'] as num?)?.toInt() ?? 0,
        total: (j['total'] as num?)?.toInt() ?? 0,
        calls: (j['calls'] as num?)?.toInt() ?? 0,
        reasoning: (j['reasoning'] as num?)?.toInt(),
        compressions: (j['compressions'] as num?)?.toInt(),
        cacheHitPercent: (j['cacheHitPercent'] as num?)?.toInt(),
        tokensPerSecond: (j['tokensPerSecond'] as num?)?.toDouble(),
        costUSD: (j['costUSD'] as num?)?.toDouble(),
        model: j['model'] as String?,
      );
}

class ContextBreakdown {
  const ContextBreakdown({
    this.contextUsed = 0,
    this.contextMax = 0,
    this.contextPercent = 0,
    this.isEstimated = true,
    this.categories = const [],
  });
  final int contextUsed;
  final int contextMax;
  final int contextPercent;
  final bool isEstimated;
  final List<ContextCategory> categories;

  static ContextBreakdown fromJson(Map<String, Object?> j) => ContextBreakdown(
        contextUsed: (j['contextUsed'] as num?)?.toInt() ?? 0,
        contextMax: (j['contextMax'] as num?)?.toInt() ?? 0,
        contextPercent: (j['contextPercent'] as num?)?.toInt() ?? 0,
        isEstimated: j['isEstimated'] as bool? ?? true,
        categories: _list(j['categories'])
            .map((c) => ContextCategory(
                  id: c['id'] as String? ?? '',
                  label: c['label'] as String? ?? '',
                  tokens: (c['tokens'] as num?)?.toInt() ?? 0,
                ))
            .toList(),
      );
}

class ContextCategory {
  const ContextCategory({required this.id, required this.label, required this.tokens});
  final String id;
  final String label;
  final int tokens;
}

/// The list profile's scheduled jobs, as the sidebar's Cron tab shows them
/// (docs/desktop-bridge.md: the `cron` snapshot).
class CronSnapshot {
  const CronSnapshot({
    this.profile,
    this.isLoading = false,
    this.error,
    this.isAvailable = true,
    this.jobs = const [],
    this.runs = const {},
    this.runErrors = const {},
    this.targets = const [],
    this.triggering = const [],
    this.blueprints = const [],
  });

  /// The profile whose jobs [jobs] holds; null until the first read comes back.
  final String? profile;
  final bool isLoading;
  final String? error;
  final bool isAvailable;
  final List<CronJobEntry> jobs;

  /// Recent runs by job id, newest first, for the jobs whose runs were read.
  final Map<String, List<CronRunEntry>> runs;
  final Map<String, String> runErrors;
  final List<CronTarget> targets;

  /// Jobs being run now from the app.
  final List<String> triggering;

  /// The ready-made jobs the profile can start from, once read.
  final List<CronBlueprintEntry> blueprints;

  static CronSnapshot fromJson(Map<String, Object?> j) => CronSnapshot(
        profile: j['profile'] as String?,
        isLoading: j['isLoading'] as bool? ?? false,
        error: j['error'] as String?,
        isAvailable: j['isAvailable'] as bool? ?? true,
        jobs: _list(j['jobs']).map(CronJobEntry.fromJson).toList(),
        runs: {
          for (final entry in (j['runs'] as Map<String, Object?>? ?? const {}).entries)
            entry.key: _list(entry.value).map(CronRunEntry.fromJson).toList(),
        },
        runErrors: {
          for (final entry in (j['runErrors'] as Map<String, Object?>? ?? const {}).entries)
            if (entry.value is String) entry.key: entry.value as String,
        },
        targets: _list(j['targets'])
            .map((t) => CronTarget(
                  id: t['id'] as String? ?? '',
                  name: t['name'] as String? ?? '',
                  homeTargetSet: t['homeTargetSet'] as bool? ?? true,
                ))
            .toList(),
        triggering: ((j['triggering'] as List?) ?? const []).cast<String>(),
        blueprints: _list(j['blueprints']).map(CronBlueprintEntry.fromJson).toList(),
      );
}

class CronJobEntry {
  const CronJobEntry({
    required this.id,
    required this.title,
    this.name,
    this.prompt,
    this.script,
    this.isScriptOnly = false,
    this.state = 'scheduled',
    this.nextRunAt,
    this.lastRunAt,
    this.lastStatus,
    this.lastError,
    this.lastDeliveryError,
    this.pausedReason,
    this.scheduleDisplay,
    this.scheduleExpression,
    this.model,
    this.provider,
    this.deliver = const [],
    this.overdueSince,
    this.needsAttention = false,
  });
  final String id;

  /// The name, else the start of the prompt or script, else the id.
  final String title;
  final String? name;
  final String? prompt;
  final String? script;

  /// A script that runs without an agent: no prompt, no model to pick.
  final bool isScriptOnly;

  /// The stated state, else one from enabled.
  final String state;
  final DateTime? nextRunAt;
  final DateTime? lastRunAt;
  final String? lastStatus;
  final String? lastError;
  final String? lastDeliveryError;
  final String? pausedReason;

  /// The human line ("0 9 * * *").
  final String? scheduleDisplay;

  /// The raw expression, for the editor.
  final String? scheduleExpression;
  final String? model;
  final String? provider;

  /// The targets the job delivers to, `local` when it names none.
  final List<String> deliver;

  /// When the next run passed more than 15 minutes ago: a scheduler that stopped ticking.
  final DateTime? overdueSince;

  /// The job's last run failed or wasn't delivered.
  final bool needsAttention;

  bool get isPaused => state == 'paused';

  static CronJobEntry fromJson(Map<String, Object?> j) => CronJobEntry(
        id: j['id'] as String? ?? '',
        title: j['title'] as String? ?? '',
        name: j['name'] as String?,
        prompt: j['prompt'] as String?,
        script: j['script'] as String?,
        isScriptOnly: j['isScriptOnly'] as bool? ?? false,
        state: j['state'] as String? ?? 'scheduled',
        nextRunAt: _seconds(j['nextRunAt']),
        lastRunAt: _seconds(j['lastRunAt']),
        lastStatus: j['lastStatus'] as String?,
        lastError: j['lastError'] as String?,
        lastDeliveryError: j['lastDeliveryError'] as String?,
        pausedReason: j['pausedReason'] as String?,
        scheduleDisplay: j['scheduleDisplay'] as String?,
        scheduleExpression: j['scheduleExpression'] as String?,
        model: j['model'] as String?,
        provider: j['provider'] as String?,
        deliver: ((j['deliver'] as List?) ?? const []).cast<String>(),
        overdueSince: _seconds(j['overdueSince']),
        needsAttention: j['needsAttention'] as bool? ?? false,
      );
}

class CronRunEntry {
  const CronRunEntry({
    required this.id,
    this.title,
    this.preview,
    this.startedAt,
    this.lastActive,
    this.endedAt,
    this.messageCount,
    this.isOutputDocument = false,
    this.entryID,
  });
  final String id;
  final String? title;

  /// A script run's output; an agent run's preview is the scheduler's own
  /// instructions, so the row shows only the time.
  final String? preview;
  final DateTime? startedAt;
  final DateTime? lastActive;
  final DateTime? endedAt;
  final int? messageCount;

  /// `cron_output`: the run's output document, not a session.
  final bool isOutputDocument;

  /// What openCronRun takes, for a run that is a session.
  final String? entryID;

  static CronRunEntry fromJson(Map<String, Object?> j) => CronRunEntry(
        id: j['id'] as String? ?? '',
        title: j['title'] as String?,
        preview: j['preview'] as String?,
        startedAt: _seconds(j['startedAt']),
        lastActive: _seconds(j['lastActive']),
        endedAt: _seconds(j['endedAt']),
        messageCount: (j['messageCount'] as num?)?.toInt(),
        isOutputDocument: j['isOutputDocument'] as bool? ?? false,
        entryID: j['entryID'] as String?,
      );
}

class CronTarget {
  const CronTarget({required this.id, required this.name, this.homeTargetSet = true});
  final String id;
  final String name;

  /// A platform without a cron home channel is listed with false.
  final bool homeTargetSet;
}

class CronBlueprintEntry {
  const CronBlueprintEntry({
    required this.key,
    required this.title,
    this.description = '',
    this.fields = const [],
  });
  final String key;
  final String title;
  final String description;
  final List<CronBlueprintField> fields;

  static CronBlueprintEntry fromJson(Map<String, Object?> j) => CronBlueprintEntry(
        key: j['key'] as String? ?? '',
        title: j['title'] as String? ?? '',
        description: j['description'] as String? ?? '',
        fields: _list(j['fields'])
            .map((f) => CronBlueprintField(
                  kind: f['kind'] as String? ?? 'text',
                  name: f['name'] as String? ?? '',
                  label: f['label'] as String? ?? '',
                  defaultValue: f['defaultValue'] as String?,
                  options: ((f['options'] as List?) ?? const []).cast<String>(),
                  isOptional: f['isOptional'] as bool? ?? false,
                  help: f['help'] as String? ?? '',
                  isDeliver: f['isDeliver'] as bool? ?? false,
                ))
            .toList(),
      );
}

class CronBlueprintField {
  const CronBlueprintField({
    required this.kind,
    required this.name,
    required this.label,
    this.defaultValue,
    this.options = const [],
    this.isOptional = false,
    this.help = '',
    this.isDeliver = false,
  });

  /// `text`, `time`, `weekdays` or `enum`; an unknown kind filled in as text.
  final String kind;
  final String name;
  final String label;
  final String? defaultValue;
  final List<String> options;
  final bool isOptional;
  final String help;

  /// The deliver blank, offered as delivery toggles, not its options.
  final bool isDeliver;
}
