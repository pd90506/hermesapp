// Live check of the bridge against a real Hermes, for the Windows host (AGENTS.md).
//
//   dart run bin/live_probe.dart <HermesBridge.dll> <dashboard url> <token> <profile>
//
// Connects, opens a new chat in <profile>, sends one prompt, prints the reply, deletes
// the chat and exits non-zero on any failure.
import 'dart:async';
import 'dart:io';

import 'package:hermes_bridge/hermes_bridge.dart';

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    stderr.writeln('usage: live_probe <library> <url> <token> <profile>');
    exit(2);
  }
  final [library, url, token, profile] = args;
  final bridge = HermesBridge.open(library);
  final watch = Stopwatch()..start();
  void log(String s) => print('${watch.elapsedMilliseconds.toString().padLeft(6)} ms  $s');

  Map<String, Object?>? lastChat;
  bridge.events.listen((event) {
    if (event['type'] == 'connection') {
      log('connection: ${event['state']}, ${(event['bots'] as List).length} bots');
    } else if (event['type'] == 'chat') {
      lastChat = event;
    }
  });

  try {
    await bridge.call('connect', {'url': url, 'token': token});
    await bridge.call('newChat', {'profile': profile});
    final marker = 'PONG-${DateTime.now().millisecondsSinceEpoch % 10000}';
    await bridge.call('send', {'text': 'Reply with exactly $marker and nothing else. Do not use tools.'});
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    String? reply;
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final chat = lastChat;
      if (chat == null || chat['isRunning'] == true) continue;
      final items = (chat['items'] as List).cast<Map<String, Object?>>();
      final answers = items.where((i) => i['role'] == 'assistant').map((i) => i['text'] as String);
      if (answers.any((t) => t.contains(marker))) {
        reply = answers.last;
        break;
      }
    }
    log('reply: ${reply ?? '(none)'}');
    await bridge.call('deleteChat');
    await bridge.call('disconnect');
    bridge.dispose();
    exit(reply != null ? 0 : 1);
  } on BridgeException catch (e) {
    log('failed: $e');
    bridge.dispose();
    exit(1);
  }
}
