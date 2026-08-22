// Regression test for the replay-dedup NoSuchMethodError bug (2026-08-20).
//
// The PR #24/#25 replay dedup read `(msg as dynamic).id` on every decoded
// ServerMessage. Action replies — ListProjectsResult, GitStatusResult,
// OpenTerminalResult, Pong — have NO `id` field (they correlate via
// `in_reply_to`), so the dynamic access threw NoSuchMethodError into
// _handleFrame's generic catch and the reply was SILENTLY DROPPED. Every
// remote action timed out: the phone's Projects page showed
// "Device unreachable" while the daemon logged "replying with 46 projects".

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/transport/peer_channel.dart';
import 'package:app/pairing/pair_request_flow.dart';
import 'package:flutter_test/flutter_test.dart';

/// Minimal in-memory PeerTransport: frames pushed by the test.
class _ScriptedTransport implements PeerTransport {
  final _frames = <Uint8List>[];
  final _waiters = <Completer<Uint8List>>[];
  bool closed = false;

  void push(String json) {
    final bytes = Uint8List.fromList(utf8.encode(json));
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(bytes);
    } else {
      _frames.add(bytes);
    }
  }

  @override
  Future<void> send(Uint8List data) async {}

  @override
  Future<Uint8List> receive() {
    if (_frames.isNotEmpty) return Future.value(_frames.removeAt(0));
    final c = Completer<Uint8List>();
    _waiters.add(c);
    return c.future;
  }

  @override
  Future<void> close() async {
    closed = true;
    for (final w in _waiters) {
      w.completeError(StateError('closed'));
    }
    _waiters.clear();
  }
}

void main() {
  test('ListProjectsResult (no id field) is DELIVERED, not dropped', () async {
    final t = _ScriptedTransport();
    final ch = PlainPeerChannel(transport: t);
    final received = <Object>[];
    final done = Completer<void>();
    final sub = ch.serverMessages.listen((m) {
      received.add(m);
      if (!done.isCompleted) done.complete();
    });
    t.push(jsonEncode({
      'type': 'list_projects_result',
      'in_reply_to': 'act-1',
      'ok': true,
      'projects': [
        {'path': 'C:/src/foo', 'name': 'foo'},
      ],
    }));
    await done.future.timeout(const Duration(seconds: 2));
    expect(received.length, 1);
    expect(received.first.runtimeType.toString(), contains('ListProjectsResult'));
    await sub.cancel();
    await ch.close();
  });

  test('Pong (no id field) is delivered', () async {
    final t = _ScriptedTransport();
    final ch = PlainPeerChannel(transport: t);
    final done = Completer<void>();
    final sub = ch.serverMessages.listen((_) {
      if (!done.isCompleted) done.complete();
    });
    t.push(jsonEncode({'type': 'pong', 'in_reply_to': 'p-1'}));
    await done.future.timeout(const Duration(seconds: 2));
    await sub.cancel();
    await ch.close();
  });

  test('replayed id-bearing frame is still deduped', () async {
    final t = _ScriptedTransport();
    final ch = PlainPeerChannel(transport: t);
    final received = <Object>[];
    final first = Completer<void>();
    final sub = ch.serverMessages.listen((m) {
      received.add(m);
      if (!first.isCompleted) first.complete();
    });
    final echo = jsonEncode({
      'type': 'steer_consumed',
      'id': 'same-id-1',
    });
    t.push(echo);
    await first.future.timeout(const Duration(seconds: 2));
    t.push(echo); // replay — must be dropped
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(received.length, 1, reason: 'replay must be deduped');
    await sub.cancel();
    await ch.close();
  });

  // Regression (2026-08-22, ask_user stuck sheet): the pi-ask bridge reuses
  // the REQUEST's id (the flowId) on its dismiss/warning NOTIFY frames. The
  // request is delivered first, so the notify's id was already in the replay
  // LRU and the notify was dropped — the ask sheet spun forever and submit
  // retries never surfaced pi-ask's rejection warnings.
  test(
      'extension_ui_request notify reusing the request id is DELIVERED',
      () async {
    final t = _ScriptedTransport();
    final ch = PlainPeerChannel(transport: t);
    final received = <Object>[];
    final both = Completer<void>();
    final sub = ch.serverMessages.listen((m) {
      received.add(m);
      if (received.length == 2 && !both.isCompleted) both.complete();
    });
    t.push(jsonEncode({
      'type': 'extension_ui_request',
      'id': 'tool:tc_1',
      'method': 'select',
      'title': 'Pick one',
      'options': ['Alpha', 'Beta'],
      'ask': {
        'flow_id': 'tool:tc_1',
        'source': 'tool',
        'questions': [
          {
            'id': 'goal',
            'label': 'Pick one',
            'prompt': 'Pick one',
            'type': 'single',
            'required': false,
            'options': [
              {'value': 'a', 'label': 'Alpha'},
            ],
          },
        ],
      },
    }));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    t.push(jsonEncode({
      'type': 'extension_ui_request',
      'id': 'tool:tc_1', // SAME id as the request — the bridge's contract
      'method': 'notify',
      'message': 'Clarification resolved.',
    }));
    await both.future.timeout(const Duration(seconds: 2));
    expect(received.length, 2,
        reason: 'notify with the request id must not be deduped');
    expect(received.last.runtimeType.toString(), contains('ExtensionUiRequest'));
    await sub.cancel();
    await ch.close();
  });
}
