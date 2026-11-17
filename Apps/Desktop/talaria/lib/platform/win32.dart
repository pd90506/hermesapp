/// The few Win32 calls the app makes, through `dart:ffi` (no plugins: a Flutter plugin
/// with native code needs Windows' Developer Mode to build).
library;

import 'dart:ffi';
import 'dart:typed_data';

final _ucrt = DynamicLibrary.open('ucrtbase.dll');
final _advapi = DynamicLibrary.open('advapi32.dll');

final _malloc = _ucrt.lookupFunction<Pointer<Uint8> Function(IntPtr), Pointer<Uint8> Function(int)>('malloc');
final _free = _ucrt.lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>('free');

/// Native memory for one call; [freeAll] releases everything it handed out.
class Arena {
  final _blocks = <Pointer<Uint8>>[];

  Pointer<Uint8> bytes(int size) {
    final p = _malloc(size == 0 ? 1 : size);
    for (var i = 0; i < size; i++) {
      p[i] = 0;
    }
    _blocks.add(p);
    return p;
  }

  /// A NUL-terminated UTF-16 string, as Win32's `W` functions take.
  Pointer<Uint16> wide(String s) {
    final units = s.codeUnits;
    final p = bytes((units.length + 1) * 2).cast<Uint16>();
    p.asTypedList(units.length + 1)
      ..setAll(0, units)
      ..[units.length] = 0;
    return p;
  }

  void freeAll() {
    for (final p in _blocks) {
      _free(p);
    }
    _blocks.clear();
  }
}

// --- Credential Manager ------------------------------------------------------------

/// `CREDENTIALW` (wincred.h).
final class _Credential extends Struct {
  @Uint32()
  external int flags;
  @Uint32()
  external int type;
  external Pointer<Uint16> targetName;
  external Pointer<Uint16> comment;
  @Uint32()
  external int lastWrittenLow;
  @Uint32()
  external int lastWrittenHigh;
  @Uint32()
  external int credentialBlobSize;
  external Pointer<Uint8> credentialBlob;
  @Uint32()
  external int persist;
  @Uint32()
  external int attributeCount;
  external Pointer<Void> attributes;
  external Pointer<Uint16> targetAlias;
  external Pointer<Uint16> userName;
}

const _credTypeGeneric = 1;
const _credPersistLocalMachine = 2;

final _credWrite = _advapi.lookupFunction<Int32 Function(Pointer<_Credential>, Uint32),
    int Function(Pointer<_Credential>, int)>('CredWriteW');
final _credRead = _advapi.lookupFunction<Int32 Function(Pointer<Uint16>, Uint32, Uint32, Pointer<Pointer<_Credential>>),
    int Function(Pointer<Uint16>, int, int, Pointer<Pointer<_Credential>>)>('CredReadW');
final _credDelete =
    _advapi.lookupFunction<Int32 Function(Pointer<Uint16>, Uint32, Uint32), int Function(Pointer<Uint16>, int, int)>(
        'CredDeleteW');
final _credFree = _advapi.lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>('CredFree');

/// Windows Credential Manager, the place Windows keeps an app's secrets for its user
/// (as the Mac app keeps them in the Keychain). Entries are generic credentials
/// named `Talaria:<key>`, visible in Control Panel > Credential Manager.
class CredentialStore {
  const CredentialStore();

  static String _target(String key) => 'Talaria:$key';

  void write(String key, String secret, {String userName = ''}) {
    final arena = Arena();
    try {
      // UTF-16LE, as Windows stores a password (what `cmdkey /pass` writes).
      final blob = Uint8List.view(Uint16List.fromList(secret.codeUnits).buffer);
      final cred = arena.bytes(sizeOf<_Credential>()).cast<_Credential>();
      final data = arena.bytes(blob.length);
      data.asTypedList(blob.length).setAll(0, blob);
      cred.ref
        ..type = _credTypeGeneric
        ..targetName = arena.wide(_target(key))
        ..credentialBlobSize = blob.length
        ..credentialBlob = data
        ..persist = _credPersistLocalMachine
        ..userName = arena.wide(userName);
      if (_credWrite(cred, 0) == 0) throw StateError('CredWriteW failed for ${_target(key)}');
    } finally {
      arena.freeAll();
    }
  }

  String? read(String key) {
    final arena = Arena();
    try {
      final out = arena.bytes(sizeOf<Pointer>()).cast<Pointer<_Credential>>();
      if (_credRead(arena.wide(_target(key)), _credTypeGeneric, 0, out) == 0) return null;
      final cred = out.value;
      try {
        final size = cred.ref.credentialBlobSize;
        final bytes = Uint8List.fromList(cred.ref.credentialBlob.asTypedList(size));
        return String.fromCharCodes(Uint16List.view(bytes.buffer, 0, size ~/ 2));
      } finally {
        _credFree(cred.cast());
      }
    } finally {
      arena.freeAll();
    }
  }

  void delete(String key) {
    final arena = Arena();
    try {
      _credDelete(arena.wide(_target(key)), _credTypeGeneric, 0);
    } finally {
      arena.freeAll();
    }
  }
}

// --- Registry ----------------------------------------------------------------------

const _hkeyCurrentUser = 0x80000001;
const _rrfRtAny = 0x0000ffff;

final _regGetValue = _advapi.lookupFunction<
    Int32 Function(IntPtr, Pointer<Uint16>, Pointer<Uint16>, Uint32, Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>),
    int Function(int, Pointer<Uint16>, Pointer<Uint16>, int, Pointer<Uint32>, Pointer<Uint8>, Pointer<Uint32>)>(
  'RegGetValueW',
);

/// A value under HKEY_CURRENT_USER as raw bytes, or null when it isn't there.
Uint8List? readUserRegistry(String key, String value) {
  final arena = Arena();
  try {
    final size = arena.bytes(4).cast<Uint32>()..value = 256;
    final data = arena.bytes(256);
    final status =
        _regGetValue(_hkeyCurrentUser, arena.wide(key), arena.wide(value), _rrfRtAny, nullptr, data, size);
    if (status != 0) return null;
    return Uint8List.fromList(data.asTypedList(size.value));
  } finally {
    arena.freeAll();
  }
}


// --- Shell -------------------------------------------------------------------------

final _shell32 = DynamicLibrary.open('shell32.dll');
final _shellExecute = _shell32.lookupFunction<
    IntPtr Function(IntPtr, Pointer<Uint16>, Pointer<Uint16>, Pointer<Uint16>, Pointer<Uint16>, Int32),
    int Function(int, Pointer<Uint16>, Pointer<Uint16>, Pointer<Uint16>, Pointer<Uint16>, int)>('ShellExecuteW');

/// Opens a web or mail link in the user's default app (`ShellExecuteW`, "open"). Other
/// schemes are refused: a link in a reply must not start a program.
bool openLink(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !const {'http', 'https', 'mailto'}.contains(uri.scheme.toLowerCase())) return false;
  final arena = Arena();
  try {
    const swShowNormal = 1;
    return _shellExecute(0, arena.wide('open'), arena.wide(uri.toString()), nullptr, nullptr, swShowNormal) > 32;
  } finally {
    arena.freeAll();
  }
}
