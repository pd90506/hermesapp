import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:hermes_bridge/hermes_bridge.dart';

import '../platform/system.dart';
import 'settings_store.dart';
import 'snapshots.dart';

/// What the views show and the actions they take: the bridge's snapshots, the saved
/// settings, and commands sent through the bridge. No protocol logic: that is
/// HermesKit's, behind the bridge.
class AppState extends ChangeNotifier {
  AppState({required HermesBridge bridge, required SettingsStore store})
      : _bridge = bridge,
        _store = store,
        settings = store.load() {
    _events = _bridge.events.listen(_receive);
    unawaited(WindowFrame.setTheme(settings.theme));
    NativeFiles.listen(
      onDrag: (over) {
        isDraggingFiles = over && chat.isOpen;
        notifyListeners();
      },
      onDrop: (paths) {
        if (chat.isOpen) unawaited(attachPaths(paths));
      },
    );
  }

  final HermesBridge _bridge;
  final SettingsStore _store;
  late final StreamSubscription<Map<String, Object?>> _events;

  Settings settings;
  ConnectionSnapshot connection = const ConnectionSnapshot();
  ChatSnapshot chat = const ChatSnapshot();
  ComposerSnapshot composer = const ComposerSnapshot();
  SearchSnapshot search = const SearchSnapshot();
  SubagentsSnapshot subagents = const SubagentsSnapshot();
  UsageSnapshot usage = const UsageSnapshot();
  CronSnapshot cron = const CronSnapshot();

  /// Thumbnails of the images attached here, by card id: the composer's cards and,
  /// once sent, the prompt's bubble (`SentImage.localID`).
  final Map<String, Uint8List> previews = {};

  /// Files are being dragged over the window.
  bool isDraggingFiles = false;

  /// The profile the rail has selected; its Bot Chat and sessions are listed.
  String? selectedProfile;

  /// What the session list has highlighted: a session's id, or `bot:<profile>`.
  String? selectedRow;

  /// Shown over the window: the first-run page, or Settings.
  bool isSettingsShown = false;

  /// A command's failure, shown in an InfoBar until dismissed.
  String? error;

  bool isConnecting = false;

  /// The search field's text, untrimmed; the list shows its results while it has
  /// text. A pause in typing (250 ms, as the Mac's) runs the search.
  String searchText = '';
  Timer? _searchPause;

  /// The sidebar's tab: the profile's sessions or its cron jobs.
  bool isCronShown = false;
  Timer? _cronPoll;

  /// Reconciles the subagents while a turn runs or a child does, as the Mac's
  /// pill does (every 5 s, `SubagentsPill`).
  Timer? _subagentsPoll;

  bool get needsServer => !settings.hasServer;

  /// With `TALARIA_LOG` set to a file path, every bridge event is summed up there: how
  /// the UI tests in the VM see what the app received.
  static final _log = Platform.environment['TALARIA_LOG'];

  void _trace(String line) {
    final path = _log;
    if (path == null) return;
    File(path).writeAsStringSync('${DateTime.now().toIso8601String()} $line\n', mode: FileMode.append);
  }

  void _receive(Map<String, Object?> event) {
    _trace('${event['type']} state=${event['state']} sessions=${(event['sessions'] as List?)?.length} '
        'sid=${event['sessionID']} running=${event['isRunning']} items=${(event['items'] as List?)?.length} '
        'error=${event['lastError'] ?? event['sessionListError']}');
    switch (event['type']) {
      case 'connection':
        connection = ConnectionSnapshot.fromJson(event);
        if (selectedProfile == null && connection.bots.isNotEmpty) {
          final pick = connection.bots.where((b) => b.name == settings.lastProfile).firstOrNull ??
              connection.bots.firstWhere((b) => b.isDefault, orElse: () => connection.bots.first);
          unawaited(selectProfile(pick.name));
        }
        _restoreLastSession();
      case 'composer':
        composer = ComposerSnapshot.fromJson(event);
      case 'search':
        search = SearchSnapshot.fromJson(event);
      case 'subagents':
        subagents = SubagentsSnapshot.fromJson(event);
      case 'usage':
        usage = UsageSnapshot.fromJson(event);
      case 'cron':
        cron = CronSnapshot.fromJson(event);
      case 'chat':
        final wasRunning = chat.isRunning;
        chat = ChatSnapshot.fromJson(event);
        if (composer.sessionID != null && composer.sessionID != chat.sessionID) composer = const ComposerSnapshot();
        // A turn that started or ended changes the list: a new chat gets its row, a
        // finished one its title and time.
        if (wasRunning != chat.isRunning) unawaited(refreshSessions());
        // And the context gauge's numbers: a free chat reads them again, as the
        // Mac's ring does after a turn.
        if (!chat.isRunning && chat.isOpen) unawaited(refreshUsage());
        // Whichever way the chat came on screen (a click, New chat, a slash
        // command's client action), its own numbers and children show now.
        if (chat.isOpen && _usageSession != chat.sessionID) {
          _usageSession = chat.sessionID;
          unawaited(refreshUsage());
          unawaited(refreshSubagents());
        }
        if (!chat.isOpen) _usageSession = null;
        _syncSelectedRow();
        // Whichever way the chat came on screen (a click, New chat), it shows next time.
        if (chat.storedSessionID case final stored? when chat.profile != null) {
          final id = '${chat.profile}/$stored';
          if (settings.lastSession != id) _remember(session: id);
        }
    }
    notifyListeners();
  }

  /// The session whose numbers were read last, so an open chat reads them once.
  String? _usageSession;

  /// Keeps the sidebar's row in step with the chat on screen: a slash command's
  /// client action (/new) or another client can have changed what is open.
  void _syncSelectedRow() {
    final stored = chat.storedSessionID;
    if (stored == null || chat.profile == null) {
      if (selectedRow != null && !selectedRow!.startsWith('bot:')) selectedRow = null;
      return;
    }
    final id = '${chat.profile}/$stored';
    if (connection.sessions.any((s) => s.id == id)) {
      selectedRow = id;
    } else if (selectedRow != null && selectedRow != id && !selectedRow!.startsWith('bot:')) {
      selectedRow = null;
    }
  }

  /// Once the list has the session shown last, shows it again (at launch only).
  bool _restored = false;
  void _restoreLastSession() {
    if (_restored || chat.isOpen || connection.sessions.isEmpty) return;
    final last = settings.lastSession;
    final entry = connection.sessions.where((s) => s.id == last && s.profile == selectedProfile).firstOrNull;
    _restored = true;
    if (entry != null) unawaited(openSession(entry));
  }

  void _remember({String? profile, String? session}) {
    if (profile != null) settings.lastProfile = profile;
    settings.lastSession = session;
    _store.save(settings);
  }

  Future<void> _run(String method, [Map<String, Object?> params = const {}]) async {
    try {
      _trace('> $method');
      await _bridge.call(method, params);
    } on BridgeException catch (e) {
      _trace('! $method: ${e.message}');
      error = e.message;
      notifyListeners();
    }
  }

  // --- Server ----------------------------------------------------------------------

  /// Connects with the saved settings and secret, if there are any.
  Future<void> connectSaved() async {
    if (!settings.hasServer) return;
    final secret = _store.readSecret();
    if (secret == null) return;
    await _connect(secret);
  }

  /// Saves the server and its secret, then connects.
  Future<bool> saveServerAndConnect(Settings next, String secret) async {
    // The same server keeps its id and pins; another one starts without.
    if (next.serverUrl.trim() == settings.serverUrl.trim()) {
      next.serverId = settings.serverId;
      next.pins = settings.pins;
    }
    settings = next;
    _store.save(settings);
    _store.writeSecret(secret, userName: next.username);
    return _connect(secret);
  }

  Future<bool> _connect(String secret) async {
    isConnecting = true;
    error = null;
    selectedProfile = null;
    selectedRow = null;
    chat = const ChatSnapshot();
    notifyListeners();
    await _sendPins();
    final params = <String, Object?>{'url': settings.serverUrl.trim()};
    switch (settings.signIn) {
      case SignIn.password:
        params['username'] = settings.username;
        params['password'] = secret;
      case SignIn.accessToken:
        params['accessToken'] = secret;
      case SignIn.sessionToken:
        params['token'] = secret;
    }
    try {
      await _bridge.call('connect', params);
      return true;
    } on BridgeException catch (e) {
      error = e.message;
      return false;
    } finally {
      isConnecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    await _run('disconnect');
    chat = const ChatSnapshot();
    selectedRow = null;
    notifyListeners();
  }

  /// Forgets the server and its secret (Settings > Servers > Remove).
  Future<void> removeServer() async {
    await disconnect();
    _store.deleteSecret();
    settings = Settings(theme: settings.theme);
    _store.save(settings);
    selectedProfile = null;
    notifyListeners();
  }

  // --- Preferences -------------------------------------------------------------------

  void setTheme(AppTheme theme) {
    settings.theme = theme;
    _store.save(settings);
    unawaited(WindowFrame.setTheme(theme));
    notifyListeners();
  }

  void showSettings(bool shown) {
    isSettingsShown = shown;
    notifyListeners();
  }

  void dismissError() {
    error = null;
    notifyListeners();
  }

  // --- Profiles and sessions -----------------------------------------------------------

  Future<void> selectProfile(String profile) async {
    if (selectedProfile != null && selectedProfile != profile) _restored = true;
    selectedProfile = profile;
    if (settings.lastProfile != profile) _remember(profile: profile, session: null);
    if (searchText.isNotEmpty) setSearchText('');
    notifyListeners();
    await _run('selectProfile', {'profile': profile});
  }

  // --- Search -------------------------------------------------------------------------

  /// The search field's text, untrimmed: a pause in typing runs the search, as
  /// the Mac's (250 ms, `SessionSearchResultsList`).
  void setSearchText(String value) {
    if (searchText == value) return;
    searchText = value;
    notifyListeners();
    _searchPause?.cancel();
    if (value.trim().isEmpty) {
      search = const SearchSnapshot();
      unawaited(_run('searchSessions', {'query': ''}));
      return;
    }
    _searchPause = Timer(const Duration(milliseconds: 250), () {
      if (value.trim().isNotEmpty) unawaited(_run('searchSessions', {'query': value.trim()}));
    });
  }

  /// A result's row, as the list's row opens: the Bot Chat as the Bot Chat.
  Future<void> openSearchResult(SearchResult result) async {
    if (result.isBotChat && result.profile == selectedProfile) {
      await openBotChat(result.profile);
    } else {
      selectedRow = result.id;
      _remember(session: result.id);
      notifyListeners();
      await _run('openSession', {'id': result.id});
    }
  }

  Future<void> openBotChat(String profile) async {
    selectedRow = 'bot:$profile';
    notifyListeners();
    await _run('openBotChat', {'profile': profile});
  }

  Future<void> openSession(SessionEntry entry) async {
    selectedRow = entry.id;
    _remember(session: entry.id);
    notifyListeners();
    await _run('openSession', {'id': entry.id});
  }

  Future<void> newChat() async {
    final profile = selectedProfile;
    if (profile == null) return;
    selectedRow = null;
    notifyListeners();
    await _run('newChat', {'profile': profile});
  }

  Future<void> refreshSessions() => _run('refreshSessions');

  /// Pins a session to the top of the list, or unpins it (the Mac's Pin); kept in
  /// settings.json, as the Mac keeps them in its defaults.
  Future<void> setPinned(SessionEntry entry, bool pinned) async {
    try {
      final result = await _bridge.call('pinSession', {'id': entry.id, 'pinned': pinned});
      settings.pins = ((result as Map?)?['pins'] as Map?)?.cast<String, Object?>();
      _store.save(settings);
    } on BridgeException catch (e) {
      error = e.message;
      notifyListeners();
    }
  }

  // --- A session's actions (the Mac's `SessionActions`) ------------------------------

  /// Renames a session; one not open here is opened first, as on the Mac.
  Future<void> renameSession(SessionEntry entry, String title) async {
    await _run('renameSession', {'id': entry.id, 'title': title});
    if (chat.storedSessionID == entry.storedID) {
      selectedRow = entry.id;
      notifyListeners();
    }
  }

  /// Copies a session into a new one, which opens ("Title #2").
  Future<void> forkSession(SessionEntry entry) async {
    selectedRow = null;
    notifyListeners();
    await _run('forkSession', {'id': entry.id});
  }

  /// Archives a session: it leaves the list and the pins, its messages kept.
  Future<void> archiveSession(SessionEntry entry) => _changeListed('archiveSession', entry);

  /// Deletes a session and its messages for good; it leaves the pins.
  Future<void> deleteSession(SessionEntry entry) async {
    if (entry.storedID != null && chat.storedSessionID == entry.storedID) {
      chat = const ChatSnapshot();
      selectedRow = null;
      notifyListeners();
    }
    await _changeListed('deleteSession', entry);
  }

  Future<void> _changeListed(String method, SessionEntry entry) async {
    try {
      _trace('> $method');
      final result = await _bridge.call(method, {'id': entry.id});
      settings.pins = ((result as Map?)?['pins'] as Map?)?.cast<String, Object?>();
      _store.save(settings);
    } on BridgeException catch (e) {
      _trace('! $method: ${e.message}');
      error = e.message;
      notifyListeners();
    }
  }

  // --- Avatars ----------------------------------------------------------------------

  /// A profile's avatar image, read once per image.
  Future<Uint8List?> avatar(Bot bot) {
    final id = bot.avatarID;
    if (id == null) return Future.value(null);
    return _avatars.putIfAbsent('${bot.name}/$id', () async {
      try {
        final result = await _bridge.call('avatar', {'profile': bot.name});
        final data = (result as Map?)?['data'] as String?;
        return data == null ? null : base64Decode(data);
      } on BridgeException {
        return null;
      }
    });
  }

  final Map<String, Future<Uint8List?>> _avatars = {};

  /// Change Avatar…: an image picked in the Open dialog, cropped to its centre square
  /// and scaled to 256 px, as the Mac's picker makes it (`AvatarImages.uploadPNG`).
  Future<void> changeAvatar(Bot bot) async {
    final path = await NativeFiles.pickImage();
    if (path == null) return;
    final png = await _avatarPng(await File(path).readAsBytes());
    if (png == null) {
      error = "That file isn't an image this app can read.";
      notifyListeners();
      return;
    }
    await _run('setAvatar', {'profile': bot.name, 'data': base64Encode(png)});
  }

  Future<void> removeAvatar(Bot bot) => _run('removeAvatar', {'profile': bot.name});

  /// The side of an uploaded avatar, as Desktop's picker makes it.
  static const avatarEdge = 256;

  static Future<Uint8List?> _avatarPng(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final image = (await codec.getNextFrame()).image;
      final side = image.width < image.height ? image.width : image.height;
      final src = ui.Rect.fromLTWH((image.width - side) / 2, (image.height - side) / 2, side.toDouble(), side.toDouble());
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(image, src,
          ui.Rect.fromLTWH(0, 0, avatarEdge.toDouble(), avatarEdge.toDouble()), ui.Paint()..filterQuality = ui.FilterQuality.high);
      final scaled = await recorder.endRecording().toImage(avatarEdge, avatarEdge);
      final data = await scaled.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  /// Hands the bridge the saved pins and the server's id (made once, on first use).
  Future<void> _sendPins() async {
    if (settings.serverId == null) {
      settings.serverId = _newUuid();
      _store.save(settings);
    }
    await _run('setPins', {'server': settings.serverId, 'pins': settings.pins});
  }

  static String _newUuid() {
    final r = Random.secure();
    final b = List<int>.generate(16, (_) => r.nextInt(256));
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}'.toUpperCase();
  }

  // --- The open chat -----------------------------------------------------------------

  /// Sends the text, with the composer's cards if there are any.
  Future<bool> send(String text) async {
    try {
      _trace('> send');
      await _bridge.call('send', {'text': text});
      return true;
    } on BridgeException catch (e) {
      _trace('! send: ${e.message}');
      error = e.message;
      notifyListeners();
      return false;
    }
  }

  Future<void> interrupt() => _run('interrupt');

  // --- The draft and its slash list -----------------------------------------------------

  /// Keeps the bridge's draft in step with the composer's text field, so the
  /// slash list follows it.
  Future<void> setDraft(String text) => _run('setDraft', {'text': text});

  /// A key the slash list takes; true when the list used it.
  Future<bool> slashKey(String key) async {
    try {
      return await _bridge.call('slashKey', {'key': key}) == true;
    } on BridgeException {
      return false;
    }
  }

  Future<void> acceptSlashRow(String id) => _run('acceptSlashRow', {'id': id});
  Future<void> dismissSlashSuggestions() => _run('dismissSlashSuggestions');
  Future<void> setModelPickerRequested(bool shown) => _run('setModelPickerRequested', {'shown': shown});

  // --- The chat's blocking requests -----------------------------------------------------

  Future<void> answerApproval(String id, String choice, {bool all = false}) =>
      _run('answerApproval', {'id': id, 'choice': choice, 'all': all});

  /// A clarify's answers from the app's own form, one selection per question;
  /// a null map skips every question.
  Future<void> answerClarify(String id, [Map<String, Object?>? selections]) =>
      _run('answerClarify', selections == null ? {'id': id} : {'id': id, 'selections': selections});

  Future<void> answerValue(String id, String value) => _run('answerValue', {'id': id, 'value': value});

  // --- The subagents --------------------------------------------------------------------

  Future<void> refreshSubagents() => _run('refreshSubagents');

  /// Starts the 5 s reconcile while the chat shows, as the Mac's pill does.
  void startSubagentsPoll() {
    _subagentsPoll?.cancel();
    _subagentsPoll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!chat.isOpen || (!chat.isRunning && subagents.runs.isEmpty)) return;
      unawaited(refreshSubagents());
    });
  }

  void stopSubagentsPoll() {
    _subagentsPoll?.cancel();
    _subagentsPoll = null;
  }

  Future<void> steerSubagent(String id, String text) => _run('steerSubagent', {'id': id, 'text': text});
  Future<void> stopSubagent(String id) => _run('stopSubagent', {'id': id});

  // --- The context gauge ----------------------------------------------------------------

  Future<void> refreshUsage() => _run('refreshUsage');

  // --- The profile's cron jobs -----------------------------------------------------------

  /// The sidebar's tab. While the Cron tab shows, its lists refresh every 15 s,
  /// as the Mac's Cron list does.
  void showCron(bool shown) {
    if (isCronShown == shown) return;
    isCronShown = shown;
    notifyListeners();
    _cronPoll?.cancel();
    _cronPoll = null;
    if (shown) {
      unawaited(refreshCronJobs());
      unawaited(loadCronDeliveryTargets());
      _cronPoll = Timer.periodic(const Duration(seconds: 15), (_) {
        if (!isCronShown || connection.state != LinkState.connected) return;
        unawaited(refreshCronJobs());
        unawaited(loadCronDeliveryTargets());
        for (final id in _cronExpanded.toList()) {
          unawaited(refreshCronRuns(id));
        }
      });
    }
  }

  /// The job whose runs show under it: one at a time, as in Desktop.
  final Set<String> _cronExpanded = {};

  void toggleCronRuns(String id) {
    if (_cronExpanded.contains(id)) {
      _cronExpanded.remove(id);
      notifyListeners();
    } else {
      if (_cronExpanded.length == 1) _cronExpanded.clear();
      _cronExpanded.add(id);
      notifyListeners();
      unawaited(refreshCronRuns(id));
    }
  }

  bool isCronExpanded(String id) => _cronExpanded.contains(id);

  Future<void> refreshCronJobs() => _run('refreshCronJobs');
  Future<void> refreshCronRuns(String id) => _run('refreshCronRuns', {'id': id});
  Future<void> loadCronDeliveryTargets() => _run('loadCronDeliveryTargets');
  Future<void> loadCronBlueprints() => _run('loadCronBlueprints');
  Future<void> pauseCronJob(String id) => _run('pauseCronJob', {'id': id});
  Future<void> resumeCronJob(String id) => _run('resumeCronJob', {'id': id});
  Future<void> triggerCronJob(String id) => _run('triggerCronJob', {'id': id});
  Future<void> deleteCronJob(String id) => _run('deleteCronJob', {'id': id});

  /// The targets the job toggled, as a comma list.
  Future<void> setCronDelivery(String id, List<String> deliver) =>
      _run('setCronDelivery', {'id': id, 'deliver': deliver.join(',')});

  /// A run with a session opens it as a chat of the profile.
  Future<void> openCronRun(CronRunEntry run) async {
    if (run.entryID case final id?) {
      selectedRow = id;
      notifyListeners();
      await _run('openCronRun', {'id': run.id});
    }
  }

  /// The models a job can pin, for the editor's picker. The display names come
  /// from the bridge's catalog result, as the composer's labels do.
  Future<List<ModelProvider>> cronModelCatalog() async {
    try {
      final result = await _bridge.call('cronModelCatalog');
      final providers = ((result as Map?)?['providers'] as List?) ?? const [];
      return providers
          .map((p) => ModelProvider(
                slug: (p as Map)['slug'] as String? ?? '',
                name: p['name'] as String? ?? '',
                models: ((p['models'] as List?) ?? const [])
                    .map((m) => ModelOption(model: m as String, label: _modelLabel(m)))
                    .toList(),
              ))
          .toList();
    } on BridgeException {
      return const [];
    }
  }

  /// The bridge's composer snapshot holds the display labels; the cron catalog
  /// holds bare ids. A id in the composer's catalog takes its label.
  String _modelLabel(String model) {
    for (final provider in composer.providers ?? const <ModelProvider>[]) {
      for (final option in provider.models) {
        if (option.model == model) return option.label;
      }
    }
    return model;
  }

  Future<void> createCronJob(Map<String, Object?> draft) => _run('createCronJob', {'draft': draft});
  Future<void> saveCronJob(String id, Map<String, Object?> draft) =>
      _run('saveCronJob', {'id': id, 'draft': draft});
  Future<void> instantiateCronBlueprint(String key, Map<String, String> values) =>
      _run('instantiateCronBlueprint', {'key': key, 'values': values});

  // --- The composer: model, effort, attachments ---------------------------------------

  Future<void> selectModel(String provider, String model) =>
      _run('selectModel', {'provider': provider, 'model': model});
  Future<void> confirmModelSwitch() => _run('confirmModelSwitch');
  Future<void> cancelModelSwitch() => _run('cancelModelSwitch');
  Future<void> reloadModels() => _run('reloadModels');
  Future<void> selectEffort(String effort) => _run('selectEffort', {'effort': effort});
  Future<void> dismissComposerError() => _run('dismissComposerError');
  Future<void> removeAttachment(String id) => _run('removeAttachment', {'id': id});

  /// The Open dialog, then each picked file attached.
  Future<void> pickFiles() async => attachPaths(await NativeFiles.pick());

  /// Files from the Open dialog, a drop or a paste. HermesKit decides how each goes
  /// (an image Hermes takes as it is becomes an image card, anything else a file).
  Future<void> attachPaths(List<String> paths) async {
    for (final path in paths) {
      try {
        _trace('> attachFile');
        final result = await _bridge.call('attachFile', {'path': path});
        final id = (result as Map?)?['id'] as String?;
        if (id != null && _isImageName(path)) {
          try {
            previews[id] = await File(path).readAsBytes();
          } on FileSystemException {
            // No thumbnail; the card shows the file's name.
          }
          notifyListeners();
        }
      } on BridgeException catch (e) {
        _trace('! attachFile: ${e.message}');
        // The composer shows its own error; a refusal before it (a folder) shows here.
        if (composer.error == null) {
          error = e.message;
          notifyListeners();
        }
      }
    }
  }

  /// A sent image's bytes from the gateway, once per path; null when it can't be read.
  Future<Uint8List?> sentImage(String path) => _sentImages.putIfAbsent(path, () async {
        try {
          final result = await _bridge.call('imageData', {'path': path, 'profile': chat.profile});
          final data = (result as Map?)?['data'] as String?;
          return data == null ? null : base64Decode(data);
        } on BridgeException {
          return null;
        }
      });
  final Map<String, Future<Uint8List?>> _sentImages = {};

  static bool _isImageName(String name) =>
      RegExp(r'\.(png|jpe?g|gif|webp)$', caseSensitive: false).hasMatch(name);

  /// Ctrl+V in the composer: files and images on the clipboard are attached
  /// (HermesKit's `ClipboardPolicy`, as on the Mac); true when the paste is text, which
  /// the caller inserts.
  Future<bool> pasteIsText() async {
    final clip = await NativeFiles.readClipboard();
    if (clip.types.isEmpty) return false;
    final Object? answer;
    try {
      answer = await _bridge.call('decidePaste', {'types': clip.types, 'string': clip.text, 'files': clip.files});
    } on BridgeException {
      return true;
    }
    final decision = answer as Map? ?? const {};
    switch (decision['decision']) {
      case 'files':
        await attachPaths(((decision['files'] as List?) ?? const []).cast<String>());
        return false;
      case 'imageData':
        await _attachClipboardImage(decision['type'] as String? ?? '');
        return false;
      default:
        return true;
    }
  }

  /// The clipboard's image, as a PNG unless it is a JPEG or GIF already (a bitmap is
  /// converted: Hermes takes PNG, JPEG, GIF and WebP as they are).
  Future<void> _attachClipboardImage(String type) async {
    var bytes = await NativeFiles.readClipboardImage(type);
    if (bytes == null) return;
    var ext = switch (type) { 'public.jpeg' => 'jpg', 'com.compuserve.gif' => 'gif', _ => 'png' };
    if (type == 'com.microsoft.bmp') {
      final png = await _toPng(bytes);
      if (png == null) return;
      bytes = png;
      ext = 'png';
    }
    try {
      final result = await _bridge.call('attachData', {'data': base64Encode(bytes), 'filename': 'Pasted Image.$ext'});
      final id = (result as Map?)?['id'] as String?;
      if (id != null) previews[id] = bytes;
      notifyListeners();
    } on BridgeException catch (e) {
      if (composer.error == null) {
        error = e.message;
        notifyListeners();
      }
    }
  }

  static Future<Uint8List?> _toPng(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Future<void> deleteChat() async {
    await _run('deleteChat');
    chat = const ChatSnapshot();
    selectedRow = null;
    notifyListeners();
    await refreshSessions();
  }

  /// Branch in New Chat from a message (the Mac's action bar): the branch opens.
  Future<void> branch(String itemID) async {
    selectedRow = null;
    await _run('branch', {'item': itemID});
    notifyListeners();
  }

  /// What Copy Message copies (HermesKit's `ConversationMarkdown.messageSource`).
  Future<String?> messageSource(String itemID) => _text('messageSource', {'item': itemID});

  /// What Copy Conversation copies: the chat as Markdown.
  Future<String?> conversationSource() => _text('conversationSource');

  Future<String?> _text(String method, [Map<String, Object?> params = const {}]) async {
    try {
      final result = await _bridge.call(method, params);
      return result is Map ? result['text'] as String? : null;
    } on BridgeException catch (e) {
      _trace('! $method: ${e.message}');
      return null;
    }
  }

  @override
  void dispose() {
    _events.cancel();
    _searchPause?.cancel();
    _cronPoll?.cancel();
    _subagentsPoll?.cancel();
    super.dispose();
  }
}
