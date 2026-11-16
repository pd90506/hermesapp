/// Dart side of the HermesBridge C interface (docs/desktop-bridge.md).
///
/// Loads the HermesBridge library built from Packages/HermesKit, sends JSON commands,
/// and turns the bridge's events into a stream. Uses `dart:ffi` only.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

typedef _EventNative = Void Function(Pointer<Uint8>);

/// One loaded bridge. Create it on the main isolate: its events, and Swift's main actor,
/// run on that isolate's thread.
class HermesBridge {
  HermesBridge._(this._lib)
      : _version = _lib.lookupFunction<Int32 Function(), int Function()>('hb_version'),
        _start = _lib.lookupFunction<Void Function(Pointer<NativeFunction<_EventNative>>),
            void Function(Pointer<NativeFunction<_EventNative>>)>('hb_start'),
        _command = _lib.lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>(
            'hb_command'),
        _pump = _lib.lookupFunction<Void Function(), void Function()>('hb_pump'),
        _alloc = _lib.lookupFunction<Pointer<Uint8> Function(IntPtr), Pointer<Uint8> Function(int)>(
            'hb_alloc'),
        _free = _lib.lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>(
            'hb_free');

  /// Loads the library at [path] and starts the bridge.
  ///
  /// [pumpInterval]: how often Swift's main-actor work is run (see `hb_pump`). On Windows
  /// nothing else runs it; one frame (16 ms) keeps the delay below what the eye notices.
  factory HermesBridge.open(String path, {Duration pumpInterval = const Duration(milliseconds: 16)}) {
    final bridge = HermesBridge._(DynamicLibrary.open(path));
    if (bridge._version() != supportedVersion) {
      throw StateError('HermesBridge version ${bridge._version()}, expected $supportedVersion');
    }
    bridge._listener = NativeCallable<_EventNative>.listener(bridge._receive);
    bridge._start(bridge._listener!.nativeFunction);
    bridge._pumpTimer = Timer.periodic(pumpInterval, (_) => bridge._pump());
    return bridge;
  }

  static const supportedVersion = 1;

  final DynamicLibrary _lib;
  final int Function() _version;
  final void Function(Pointer<NativeFunction<_EventNative>>) _start;
  final void Function(Pointer<Uint8>) _command;
  final void Function() _pump;
  final Pointer<Uint8> Function(int) _alloc;
  final void Function(Pointer<Uint8>) _free;

  NativeCallable<_EventNative>? _listener;
  Timer? _pumpTimer;
  int _nextId = 0;
  final _pending = <String, Completer<Object?>>{};
  final _events = StreamController<Map<String, Object?>>.broadcast();

  /// `connection` and `chat` snapshots, as decoded JSON objects.
  Stream<Map<String, Object?>> get events => _events.stream;

  /// Runs one command; completes with its result, or throws [BridgeException].
  Future<Object?> call(String method, [Map<String, Object?> params = const {}]) {
    final id = 'd${++_nextId}';
    final completer = Completer<Object?>();
    _pending[id] = completer;
    final bytes = utf8.encode(jsonEncode({'id': id, 'method': method, 'params': params}));
    final buffer = _alloc(bytes.length + 1);
    buffer.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    _command(buffer);
    _free(buffer);
    return completer.future;
  }

  void _receive(Pointer<Uint8> pointer) {
    var length = 0;
    while (pointer[length] != 0) {
      length++;
    }
    final text = utf8.decode(pointer.asTypedList(length));
    _free(pointer);
    final event = jsonDecode(text) as Map<String, Object?>;
    if (event['type'] == 'reply') {
      final completer = _pending.remove(event['id']);
      if (completer == null) return;
      final error = event['error'];
      if (error != null) {
        completer.completeError(BridgeException(error as String));
      } else {
        completer.complete(event['result']);
      }
    } else {
      _events.add(event);
    }
  }

  /// Stops the pump and the event listener. The library stays loaded.
  void dispose() {
    _pumpTimer?.cancel();
    _listener?.close();
    _events.close();
  }
}

class BridgeException implements Exception {
  BridgeException(this.message);
  final String message;
  @override
  String toString() => 'BridgeException: $message';
}
