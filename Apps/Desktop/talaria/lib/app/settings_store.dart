import 'dart:convert';
import 'dart:io';

import '../platform/system.dart';
import '../platform/win32.dart';

/// How the app signs in to the dashboard: the ways `HermesBridge`'s `connect` takes
/// (docs/desktop-bridge.md).
enum SignIn {
  /// Username and password, the dashboard's basic provider.
  password('Username and password'),

  /// A bearer access token.
  accessToken('Access token'),

  /// The session token of a dashboard on this machine that has no sign-in.
  sessionToken('Session token');

  const SignIn(this.label);
  final String label;
}

/// The server and the app's preferences. Everything but the secret is kept in
/// `%APPDATA%\Talaria\settings.json`; the secret in Credential Manager.
class Settings {
  Settings({
    this.serverUrl = '',
    this.signIn = SignIn.password,
    this.username = '',
    this.theme = AppTheme.system,
    this.lastProfile,
    this.lastSession,
  });

  String serverUrl;
  SignIn signIn;
  String username;
  AppTheme theme;

  /// The profile picked last, and the session shown last: shown again at launch, as
  /// the Mac app goes back to the chat a profile showed last.
  String? lastProfile;
  String? lastSession;

  bool get hasServer => serverUrl.trim().isNotEmpty;

  Map<String, Object?> toJson() => {
        'serverUrl': serverUrl,
        'signIn': signIn.name,
        'username': username,
        'theme': theme.name,
        'lastProfile': lastProfile,
        'lastSession': lastSession,
      };

  static Settings fromJson(Map<String, Object?> json) => Settings(
        serverUrl: json['serverUrl'] as String? ?? '',
        signIn: SignIn.values.asNameMap()[json['signIn']] ?? SignIn.password,
        username: json['username'] as String? ?? '',
        theme: AppTheme.values.asNameMap()[json['theme']] ?? AppTheme.system,
        lastProfile: json['lastProfile'] as String?,
        lastSession: json['lastSession'] as String?,
      );
}

class SettingsStore {
  SettingsStore({File? file, CredentialStore credentials = const CredentialStore()})
      : _file = file ?? File('${Platform.environment['APPDATA']}\\Talaria\\settings.json'),
        _credentials = credentials;

  final File _file;
  final CredentialStore _credentials;
  static const _secretKey = 'server';

  Settings load() {
    try {
      return Settings.fromJson(jsonDecode(_file.readAsStringSync()) as Map<String, Object?>);
    } on Object {
      return Settings();
    }
  }

  void save(Settings settings) {
    _file.parent.createSync(recursive: true);
    _file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(settings.toJson()));
  }

  String? readSecret() => _credentials.read(_secretKey);

  void writeSecret(String secret, {String userName = ''}) =>
      _credentials.write(_secretKey, secret, userName: userName);

  void deleteSecret() => _credentials.delete(_secretKey);
}
