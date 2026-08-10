// Plan/100 — ChatViewModel routing for extension_ui_request (ask_user via
// pi-ask): open modal, submit-result warning → retry error, completed notify →
// dismiss, and the offline fail-fast on respond.

import 'dart:async';
import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/chat/states/chat_state.dart';
import 'package:app/ui/chat/viewmodels/chat_viewmodel.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

class _FakeChannel implements IChannel, IControlLink {
  final _ctrl = StreamController<ServerMessage>.broadcast();
  final _control = StreamController<ControlInbound>.broadcast();
  final List<ClientMessage> sent = [];
  Object? sendError;
  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;
  @override
  Stream<ControlInbound> get controlFrames => _control.stream;
  @override
  void sendControl(Map<String, dynamic> json) {}
  @override
  Future<void> send(ClientMessage msg) async {
    final error = sendError;
    if (error != null) throw error;
    sent.add(msg);
  }

  @override
  Future<void> close() async {
    await _ctrl.close();
    await _control.close();
  }

  void push(ServerMessage m) => _ctrl.add(m);
}

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _s = {};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => _s[key];
  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _s.remove(key);
    } else {
      _s[key] = value;
    }
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

const _peer = PeerRecord(
  remoteEpk: 'epk_extui',
  sessionName: 'Pi',
  relayUrl: 'ws://localhost',
  pairedAt: '2026-01-01T00:00:00Z',
);

class _FakeStorage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => const [_peer];
  @override
  Future<PeerRecord?> loadPeer(String epk) async =>
      epk == _peer.remoteEpk ? _peer : null;
  @override
  Future<void> savePeer(PeerRecord r) async {}

  final Map<String, List<PersistedRoom>> _rooms = {};
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async =>
      _rooms[epk] = rooms;
  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async =>
      _rooms[epk] ?? const [];
  @override
  Future<void> deleteRooms(String epk) async => _rooms.remove(epk);
}

ExtensionUiRequest _request(String flowId) => ExtensionUiRequest(
  id: flowId,
  method: ExtensionUiMethod.select,
  title: 'Pick',
  options: const ['Alpha', 'Beta'],
  ask: AskEnrichmentWire(flowId: flowId, source: 'tool'),
);

late Directory _dir;

void main() {
  setUpAll(() async {
    _dir = Directory.systemTemp.createTempSync('rp_v2_extui_vm_');
    await LocalBoxes.initForTest(_dir.path);
  });
  tearDownAll(() async {
    await Hive.close();
    await _dir.delete(recursive: true);
  });

  /// Plan/129 — everything up to (but not including) the ChatViewModel, so a
  /// test can push a request into the channel BEFORE any viewmodel exists
  /// (reproducing "ask fired while the app was backgrounded / on Home").
  Future<
    ({
      _FakeChannel ch,
      ConnectionManager conn,
      SyncService sync,
      SessionReadRepository read,
      Preferences prefs,
      _FakeStorage storage,
    })
  >
  parts() async {
    final ch = _FakeChannel();
    final storage = _FakeStorage();
    final conn = ConnectionManager(
      factory: (_, _) async => ch,
      storage: storage,
    );
    final boxes = LocalBoxes();
    final sync = SyncService(conn, boxes);
    final read = SessionReadRepository(boxes);
    final prefs = Preferences(_FakeSecureStorage());
    await prefs.setSelectedPeerEpk(_peer.remoteEpk);
    await prefs.setSelectedRoom(epk: _peer.remoteEpk, roomId: 'main');

    conn.adopt(ch, _peer);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    // Bind the writer to this peer/room now, so a ChatViewModel created later
    // hits activate()'s early-return (no _resetTurnState) — mirroring a real
    // chat re-entry where the SyncService is already bound.
    await sync.activate(_peer.remoteEpk, 'main');
    return (
      ch: ch,
      conn: conn,
      sync: sync,
      read: read,
      prefs: prefs,
      storage: storage,
    );
  }

  Future<
    ({
      _FakeChannel ch,
      ConnectionManager conn,
      SyncService sync,
      ChatViewModel vm,
    })
  >
  harness() async {
    final p = await parts();
    final vm = ChatViewModel(p.read, p.sync, p.conn, p.prefs, p.storage);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return (ch: p.ch, conn: p.conn, sync: p.sync, vm: vm);
  }

  test(
    'request opens modal; warning notify sets error; completed dismisses',
    () async {
      final h = await harness();

      h.ch.push(_request('tool:f1'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      var state = h.vm.state as ChatReady;
      expect(state.pendingUiRequest?.id, 'tool:f1');
      expect(state.pendingUiError, isNull);

      // submit-result rejection → same id, warning → modal stays, error set.
      h.ch.push(
        const ExtensionUiRequest(
          id: 'tool:f1',
          method: ExtensionUiMethod.notify,
          message: 'Unknown option value.',
          notifyType: 'warning',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      state = h.vm.state as ChatReady;
      expect(state.pendingUiRequest?.id, 'tool:f1', reason: 'modal stays open');
      expect(state.pendingUiError, 'Unknown option value.');

      // Retry clears the error before shipping the response.
      await h.vm.respondExtensionUi(
        ExtensionUiResponse(
          id: 'tool:f1',
          ask: const AskResponseEnrichmentWire(
            flowId: 'tool:f1',
            mode: 'submit',
          ),
        ),
      );
      state = h.vm.state as ChatReady;
      expect(state.pendingUiError, isNull);
      expect(
        h.ch.sent.whereType<ExtensionUiResponse>().single.id,
        'tool:f1',
        reason: 'response shipped over the live channel',
      );

      // completed → notify without warning type, same id → dismiss.
      h.ch.push(
        const ExtensionUiRequest(
          id: 'tool:f1',
          method: ExtensionUiMethod.notify,
          message: 'Clarification resolved.',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      state = h.vm.state as ChatReady;
      expect(state.pendingUiRequest, isNull, reason: 'modal dismissed');
      expect(state.pendingUiError, isNull);

      h.vm.dispose();
      h.sync.dispose();
      h.conn.dispose();
    },
  );

  test(
    'unmatched notify is ignored; new request replaces the pending one',
    () async {
      final h = await harness();

      h.ch.push(_request('tool:f1'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // Notify for some other id → no effect on the open modal.
      h.ch.push(
        const ExtensionUiRequest(
          id: 'other',
          method: ExtensionUiMethod.notify,
          message: 'noise',
          notifyType: 'warning',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      var state = h.vm.state as ChatReady;
      expect(state.pendingUiRequest?.id, 'tool:f1');
      expect(state.pendingUiError, isNull);

      // A new interactive request replaces the pending one (and clears errors).
      h.ch.push(_request('tool:f2'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      state = h.vm.state as ChatReady;
      expect(state.pendingUiRequest?.id, 'tool:f2');

      h.vm.dispose();
      h.sync.dispose();
      h.conn.dispose();
    },
  );

  test(
    'respond with no live channel fails fast with a retryable error',
    () async {
      final ch = _FakeChannel();
      final storage = _FakeStorage();
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
      );
      final boxes = LocalBoxes();
      final sync = SyncService(conn, boxes);

      // No adopt → no live channel → nothing sent, false returned.
      final sent = await sync.respondExtensionUi(
        ExtensionUiResponse(id: 'tool:f1', cancelled: true),
      );
      expect(sent, isFalse);
      expect(ch.sent, isEmpty);

      sync.dispose();
      conn.dispose();
    },
  );

  test('send exception becomes a retryable modal error', () async {
    final h = await harness();

    h.ch.push(_request('tool:f1'));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    h.ch.sent.clear(); // discard harness startup SessionSync
    h.ch.sendError = StateError('socket closed');

    await expectLater(
      h.vm.respondExtensionUi(
        ExtensionUiResponse(id: 'tool:f1', cancelled: true),
      ),
      completes,
    );

    final state = h.vm.state as ChatReady;
    expect(state.pendingUiRequest?.id, 'tool:f1', reason: 'modal stays open');
    expect(
      state.pendingUiError,
      'Not connected — check the link to Pi and retry.',
    );
    expect(h.ch.sent, isEmpty);

    h.vm.dispose();
    h.sync.dispose();
    h.conn.dispose();
  });

  test(
    'request that arrived with no viewmodel mounted still shows (plan/129)',
    () async {
      // Reproduces the bug: ask_user fires while the app is backgrounded /
      // cold-started on Home — no ChatViewModel is listening on the broadcast
      // stream. The durable SyncService cache must surface it when the chat
      // later opens.
      final p = await parts();

      // No viewmodel yet: push straight into the channel (broadcast stream,
      // no listener). SyncService caches it.
      p.ch.push(_request('tool:f1'));
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // Now mount the chat (late).
      final vm = ChatViewModel(p.read, p.sync, p.conn, p.prefs, p.storage);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final state = vm.state as ChatReady;
      expect(
        state.pendingUiRequest?.id,
        'tool:f1',
        reason: 'a request missed live must surface on late mount',
      );

      vm.dispose();
      p.sync.dispose();
      p.conn.dispose();
    },
  );

  test(
    'a flow that resolved while unmounted is not re-surfaced (plan/129)',
    () async {
      // No phantom sheet: the completed notify cleared the cache before the
      // viewmodel mounted.
      final p = await parts();

      p.ch.push(_request('tool:f1'));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      p.ch.push(
        const ExtensionUiRequest(
          id: 'tool:f1',
          method: ExtensionUiMethod.notify,
          message: 'Clarification resolved.',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      final vm = ChatViewModel(p.read, p.sync, p.conn, p.prefs, p.storage);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final state = vm.state as ChatReady;
      expect(
        state.pendingUiRequest,
        isNull,
        reason: 'a resolved flow must not haunt a late mount',
      );

      vm.dispose();
      p.sync.dispose();
      p.conn.dispose();
    },
  );
}
