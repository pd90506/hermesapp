import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
      case 'chat':
        final wasRunning = chat.isRunning;
        chat = ChatSnapshot.fromJson(event);
        if (composer.sessionID != null && composer.sessionID != chat.sessionID) composer = const ComposerSnapshot();
        // A turn that started or ended changes the list: a new chat gets its row, a
        // finished one its title and time.
        if (wasRunning != chat.isRunning) unawaited(refreshSessions());
        // Whichever way the chat came on screen (a click, New chat), it shows next time.
        if (chat.storedSessionID case final stored? when chat.profile != null) {
          final id = '${chat.profile}/$stored';
          if (settings.lastSession != id) _remember(session: id);
        }
    }
    notifyListeners();
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
    notifyListeners();
    await _run('selectProfile', {'profile': profile});
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

  @override
  void dispose() {
    _events.cancel();
    super.dispose();
  }
}
