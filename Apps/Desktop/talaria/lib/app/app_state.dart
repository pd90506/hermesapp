import 'dart:async';

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
  }

  final HermesBridge _bridge;
  final SettingsStore _store;
  late final StreamSubscription<Map<String, Object?>> _events;

  Settings settings;
  ConnectionSnapshot connection = const ConnectionSnapshot();
  ChatSnapshot chat = const ChatSnapshot();

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

  void _receive(Map<String, Object?> event) {
    switch (event['type']) {
      case 'connection':
        connection = ConnectionSnapshot.fromJson(event);
        if (selectedProfile == null && connection.bots.isNotEmpty) {
          final pick = connection.bots.firstWhere((b) => b.isDefault, orElse: () => connection.bots.first);
          unawaited(selectProfile(pick.name));
        }
      case 'chat':
        chat = ChatSnapshot.fromJson(event);
    }
    notifyListeners();
  }

  Future<void> _run(String method, [Map<String, Object?> params = const {}]) async {
    try {
      await _bridge.call(method, params);
    } on BridgeException catch (e) {
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
    selectedProfile = profile;
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

  Future<bool> send(String text) async {
    try {
      await _bridge.call('send', {'text': text});
      return true;
    } on BridgeException catch (e) {
      error = e.message;
      notifyListeners();
      return false;
    }
  }

  Future<void> interrupt() => _run('interrupt');

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
