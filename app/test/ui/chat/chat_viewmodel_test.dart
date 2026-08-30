// Plan/31 — ChatViewModel is a thin composer over the SSOT. A message written
// to the DB (via the channel → SyncService) must surface in ChatState.

import 'dart:async';
import 'dart:io';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/repositories/session_read_repository.dart';
import 'package:app/data/sync/sync_service.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/domain/session_state.dart';
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
  @override
  Stream<ServerMessage> get serverMessages => _ctrl.stream;
  @override
  Stream<ControlInbound> get controlFrames => _control.stream;
  @override
  void sendControl(Map<String, dynamic> json) {}
  @override
  Future<void> send(ClientMessage msg) async => sent.add(msg);
  @override
  Future<void> close() async {
    await _ctrl.close();
    await _control.close();
  }

  void push(ServerMessage m) => _ctrl.add(m);
  void pushControl(ControlInbound m) => _control.add(m);
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
  remoteEpk: 'epk_chat',
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

  // In-memory rooms so a RoomAnnounced landing on the real ConnectionManager
  // (_persistRoomsForPeer) never touches flutter_secure_storage.
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

late Directory _dir;

void main() {
  setUpAll(() async {
    _dir = Directory.systemTemp.createTempSync('rp_v2_chatvm_');
    await LocalBoxes.initForTest(_dir.path);
  });
  tearDownAll(() async {
    await Hive.close();
    await _dir.delete(recursive: true);
  });

  test('a message written to the DB surfaces in ChatState', () async {
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

    final vm = ChatViewModel(read, sync, conn, prefs, storage);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // The Pi rebroadcasts a user message → SyncService writes a row →
    // SessionReadRepository emits → ChatViewModel recomposes.
    ch.push(UserInput(id: 'u1', text: 'hello from db'));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = vm.state;
    expect(state, isA<ChatReady>());
    final messages = (state as ChatReady).messages;
    expect(
      messages.whereType<UserMsg>().map((m) => m.text),
      contains('hello from db'),
    );

    // BUG fix (smoke): the chat "working" pill must be on for the whole turn,
    // not just the token-streaming window — and the composer locks + the send
    // button becomes "stop" (cancelTargetId points at the in-flight turn).
    expect(vm.isWorking, isTrue, reason: 'turn started → working');
    expect(vm.cancelTargetId, 'u1', reason: 'stop button cancels this turn');
    ch.push(AgentDone(inReplyTo: 'u1'));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(vm.isWorking, isFalse, reason: 'agent_done → idle');
    expect(vm.cancelTargetId, isNull, reason: 'no turn to cancel when idle');

    vm.dispose();
    sync.dispose();
    conn.dispose();
  });

  test(
    'cancelled clears the stop state without deleting the user row',
    () async {
      final ch = _FakeChannel();
      final storage = _FakeStorage();
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
      );
      final boxes = LocalBoxes();
      final msgBox = await boxes.msgsBox(_peer.remoteEpk, 'main');
      await msgBox.clear();
      final sync = SyncService(conn, boxes);
      final read = SessionReadRepository(boxes);
      final prefs = Preferences(_FakeSecureStorage());
      await prefs.setSelectedPeerEpk(_peer.remoteEpk);
      await prefs.setSelectedRoom(epk: _peer.remoteEpk, roomId: 'main');

      conn.adopt(ch, _peer);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final vm = ChatViewModel(read, sync, conn, prefs, storage);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      ch.push(UserInput(id: 'cancel-u1', text: 'please stop'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      ch.push(AgentChunk(inReplyTo: 'cancel-u1', delta: 'partial'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(vm.isWorking, isTrue);
      expect(vm.cancelTargetId, 'cancel-u1');
      expect((vm.state as ChatReady).streaming, isNotNull);

      ch.push(Cancelled(inReplyTo: 'cancel-1', targetId: 'cancel-u1'));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final state = vm.state as ChatReady;
      expect(vm.isWorking, isFalse);
      expect(vm.cancelTargetId, isNull);
      expect(state.streaming, isNull);
      expect(
        state.messages.whereType<UserMsg>().map((m) => m.text),
        contains('please stop'),
      );
      expect(
        state.messages.whereType<UserMsg>().single.status,
        UserMsgStatus.confirmed,
      );

      vm.dispose();
      sync.dispose();
      conn.dispose();
    },
  );

  test(
    'plan/134: a waiting_for_input flip recomposes ChatReady (pill repaint) without touching working',
    () async {
      final ch = _FakeChannel();
      final storage = _FakeStorage();
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      final boxes = LocalBoxes();
      final sync = SyncService(conn, boxes);
      final read = SessionReadRepository(boxes);
      final prefs = Preferences(_FakeSecureStorage());
      await prefs.setSelectedPeerEpk(_peer.remoteEpk);
      await prefs.setSelectedRoom(epk: _peer.remoteEpk, roomId: 'main');

      conn.adopt(ch, _peer);
      // Cache the room so the meta patch has a place to land (mirrors the
      // relay announcing the room before any meta flows).
      ch.pushControl(const RoomAnnounced(
        peer: 'epk_chat',
        roomId: 'main',
        startedAt: 1,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final vm = ChatViewModel(read, sync, conn, prefs, storage);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(vm.isWaitingForInput, isFalse, reason: 'idle before the prompt');
      final before = vm.state;

      // Blocking prompt opens — relay broadcasts waiting_for_input=true.
      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_chat',
        roomId: 'main',
        waitingForInput: true,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(vm.isWaitingForInput, isTrue);
      expect(vm.isWorking, isFalse,
          reason: 'waiting is independent of working (no turn in flight)');
      // THE regression guard: the pill/composer read the VM getter, so a
      // pure waiting flip MUST produce a different ChatReady or
      // ViewModel.emit skips notifyListeners and the UI never repaints.
      final during = vm.state;
      expect(during, isNot(before),
          reason: 'ChatReady identity must include isWaitingForInput');
      expect((during as ChatReady).isWaitingForInput, isTrue);

      // Prompt answered — flag clears and the state recomposes again.
      ch.pushControl(const RoomMetaUpdated(
        peer: 'epk_chat',
        roomId: 'main',
        waitingForInput: false,
        hasModel: false,
        hasThinking: false,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(vm.isWaitingForInput, isFalse);
      expect(vm.state, isNot(during));

      vm.dispose();
      sync.dispose();
      conn.dispose();
    },
  );

  test(
    'working send uses steer behavior and preserves current target',
    () async {
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
      final vm = ChatViewModel(read, sync, conn, prefs, storage);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      ch.push(UserInput(id: 'u1', text: 'primary'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(vm.isWorking, isTrue, reason: 'set up an active turn');
      final originalTarget = vm.cancelTargetId;
      expect(originalTarget, 'u1');

      await vm.sendMessage('steer follow-up');
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final sent = ch.sent.whereType<UserMessage>().lastWhere(
        (m) => m.text == 'steer follow-up',
      );
      expect(sent.streamingBehavior, UserMessageStreamingBehavior.steer);
      expect(vm.cancelTargetId, equals(originalTarget));

      vm.dispose();
      sync.dispose();
      conn.dispose();
    },
  );

  test(
    'plan/127: explicit followUp behavior is passed through and preserves target',
    () async {
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
      final vm = ChatViewModel(read, sync, conn, prefs, storage);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      ch.push(UserInput(id: 'u1', text: 'primary'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(vm.isWorking, isTrue);
      final originalTarget = vm.cancelTargetId;

      await vm.sendMessage(
        'then run tests',
        streamingBehavior: UserMessageStreamingBehavior.followUp,
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final sent = ch.sent.whereType<UserMessage>().lastWhere(
        (m) => m.text == 'then run tests',
      );
      expect(sent.streamingBehavior, UserMessageStreamingBehavior.followUp);
      expect(vm.cancelTargetId, equals(originalTarget));

      vm.dispose();
      sync.dispose();
      conn.dispose();
    },
  );

  test('queued state and commands roundtrip through ChatViewModel', () async {
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
    final vm = ChatViewModel(read, sync, conn, prefs, storage);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    ch.push(
      QueuedMessageState(
        items: [
          QueuedMessageItem(
            id: 'q1',
            text: 'queued from pi',
            editable: true,
            createdAt: DateTime.fromMillisecondsSinceEpoch(123),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));

    final state = vm.state as ChatReady;
    expect(state.queuedMessages, hasLength(1));
    expect(state.queuedMessages.single.id, 'q1');
    expect(state.queuedMessages.single.text, 'queued from pi');
    expect(state.queuedText, 'queued from pi');

    vm.queueMessage(' next queued ');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final set = ch.sent.whereType<QueuedMessageSet>().last;
    expect(set.text, 'next queued');
    expect((vm.state as ChatReady).queuedMessages.map((q) => q.text), contains('next queued'));

    vm.clearQueuedMessage('q1');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final clear = ch.sent.whereType<QueuedMessageClear>().last;
    expect(clear.targetId, 'q1');
    expect(
      (vm.state as ChatReady).queuedMessages.map((q) => q.id),
      isNot(contains('q1')),
    );

    ch.push(QueuedMessageState());
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect((vm.state as ChatReady).queuedMessages, isEmpty);

    vm.dispose();
    sync.dispose();
    conn.dispose();
  });

  test(
    'an empty session reaches ChatReady with no messages → the chat shows the '
    'default "Nothing here" placeholder (plan/32)',
    () async {
      final ch = _FakeChannel();
      final storage = _FakeStorage();
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
      );
      final boxes = LocalBoxes();
      // The msgs box is shared across tests in this file (setUpAll) — start
      // this one from a clean slate so "empty session" really is empty.
      (await boxes.msgsBox(_peer.remoteEpk, 'main')).clear();
      final sync = SyncService(conn, boxes);
      final read = SessionReadRepository(boxes);
      final prefs = Preferences(_FakeSecureStorage());
      await prefs.setSelectedPeerEpk(_peer.remoteEpk);
      await prefs.setSelectedRoom(epk: _peer.remoteEpk, roomId: 'main');

      conn.adopt(ch, _peer);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final vm = ChatViewModel(read, sync, conn, prefs, storage);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final state = vm.state;
      expect(state, isA<ChatReady>());
      state as ChatReady;
      // Empty + nothing streaming → _buildBody renders the default Pi-icon +
      // "Nothing here" placeholder (shown whenever the body is empty).
      expect(state.messages, isEmpty);
      expect(state.streaming, isNull);

      vm.dispose();
      sync.dispose();
      conn.dispose();
    },
  );

  test('working pill follows the relay per-room broadcast (same mechanism as '
      'Home) and the flip rebuilds the state (plan/32)', () async {
    final ch = _FakeChannel();
    final storage = _FakeStorage();
    final conn = ConnectionManager(
      factory: (_, _) async => ch,
      storage: storage,
      emitDebounce: Duration.zero,
    );
    final boxes = LocalBoxes();
    final sync = SyncService(conn, boxes);
    final read = SessionReadRepository(boxes);
    final prefs = Preferences(_FakeSecureStorage());
    await prefs.setSelectedPeerEpk(_peer.remoteEpk);
    await prefs.setSelectedRoom(epk: _peer.remoteEpk, roomId: 'main');

    conn.adopt(ch, _peer);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final vm = ChatViewModel(read, sync, conn, prefs, storage);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    // Room comes online idle (no local turn started in THIS chat).
    ch.pushControl(
      const RoomAnnounced(peer: 'epk_chat', roomId: 'main', startedAt: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(vm.isWorking, isFalse);

    // The relay broadcasts meta.working=true for this room (turn_start) —
    // no local send/echo, purely the per-room signal that also drives Home.
    ch.pushControl(
      const RoomMetaUpdated(
        peer: 'epk_chat',
        roomId: 'main',
        working: true,
        hasModel: false,
        hasThinking: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(
      vm.isWorking,
      isTrue,
      reason: 'relay per-room working drives the pill',
    );
    expect(
      (vm.state as ChatReady).isWorking,
      isTrue,
      reason: 'state carries isWorking so the flip rebuilds the UI',
    );
    expect(
      vm.cancelTargetId,
      'working',
      reason: 'compaction/room-meta working has no turn id but still cancels',
    );

    await vm.sendMessage('meta-only steer');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final sentSteer = ch.sent.whereType<UserMessage>().lastWhere(
      (m) => m.text == 'meta-only steer',
    );
    expect(sentSteer.streamingBehavior, UserMessageStreamingBehavior.steer);

    await vm.cancel(vm.cancelTargetId!);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final sentCancel = ch.sent.whereType<Cancel>().last;
    expect(sentCancel.targetId, 'working');

    // If the app sees agent_done but the relay's meta.working=false
    // broadcast is delayed/missed, the active chat must not stay stuck on
    // the stop button. The local channel observation clears the room flag.
    ch.push(AgentDone(inReplyTo: 'u1'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(vm.isWorking, isFalse);
    expect((vm.state as ChatReady).isWorking, isFalse);

    // A later turn_end broadcast remains idempotent.
    ch.pushControl(
      const RoomMetaUpdated(
        peer: 'epk_chat',
        roomId: 'main',
        working: false,
        hasModel: false,
        hasThinking: false,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(vm.isWorking, isFalse);
    expect((vm.state as ChatReady).isWorking, isFalse);

    vm.dispose();
    sync.dispose();
    conn.dispose();
  });

  test(
    'model_set → room_meta_updated rebuilds ChatReady with the new model '
    '(UI bug: model was a side-channel, ChatReady.== skipped notifyListeners)',
    () async {
      final ch = _FakeChannel();
      final storage = _FakeStorage();
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      final boxes = LocalBoxes();
      final sync = SyncService(conn, boxes);
      final read = SessionReadRepository(boxes);
      final prefs = Preferences(_FakeSecureStorage());
      await prefs.setSelectedPeerEpk(_peer.remoteEpk);
      await prefs.setSelectedRoom(epk: _peer.remoteEpk, roomId: 'main');

      conn.adopt(ch, _peer);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final vm = ChatViewModel(read, sync, conn, prefs, storage);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Seed room with the OLD model (what the PC was running).
      ch.pushControl(
        const RoomAnnounced(
          peer: 'epk_chat',
          roomId: 'main',
          startedAt: 1,
          model: 'old-model',
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        (vm.state as ChatReady).model,
        'old-model',
        reason: 'state identity carries the seed model',
      );
      expect(vm.activeRoom?.model, 'old-model');

      // Pure model flip — nothing else in ChatReady changes. Pre-fix this
      // produced an equal ChatReady and ViewModel.emit skipped notifyListeners,
      // so the AppBar / composer kept showing old-model while the PC switched.
      ch.pushControl(
        const RoomMetaUpdated(
          peer: 'epk_chat',
          roomId: 'main',
          model: 'new-model',
          hasThinking: false,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(
        vm.activeRoom?.model,
        'new-model',
        reason: 'ConnectionManager applied the room_meta patch',
      );
      expect(
        (vm.state as ChatReady).model,
        'new-model',
        reason: 'ChatReady.model is part of state identity → rebuild fires',
      );

      // Same for a pure context-usage tick (plan/115 header gauge).
      ch.pushControl(
        const RoomMetaUpdated(
          peer: 'epk_chat',
          roomId: 'main',
          hasModel: false,
          hasThinking: false,
          contextUsage: ContextUsage(
            tokens: 12000,
            contextWindow: 200000,
            percent: 6,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        (vm.state as ChatReady).contextUsage?.tokens,
        12000,
        reason: 'usage ticks must also rebuild the header',
      );
      // Model preserved across a usage-only patch.
      expect((vm.state as ChatReady).model, 'new-model');

      vm.dispose();
      sync.dispose();
      conn.dispose();
    },
  );

  group('Plan/137 — ask recovery card + route_error', () {
    test('pending ask_user without a sheet shows the recovery card (after '
        'the anti-flash delay), and the arriving sheet hides it', () async {
      final ch = _FakeChannel();
      final storage = _FakeStorage();
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      final boxes = LocalBoxes();
      final msgBox = await boxes.msgsBox(_peer.remoteEpk, 'main');
      await msgBox.clear();
      final sync = SyncService(conn, boxes);
      final read = SessionReadRepository(boxes);
      final prefs = Preferences(_FakeSecureStorage());
      await prefs.setSelectedPeerEpk(_peer.remoteEpk);
      await prefs.setSelectedRoom(epk: _peer.remoteEpk, roomId: 'main');

      conn.adopt(ch, _peer);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final vm = ChatViewModel(read, sync, conn, prefs, storage);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Turn opens, the agent calls ask_user — but the question frame is
      // lost (the incident this plan fixes).
      ch.push(UserInput(id: 'ask-u1', text: 'plan m6'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      ch.push(ToolRequest(
        toolCallId: 'tc_ask1',
        tool: 'ask_user',
        args: null,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Anti-flash window: not yet.
      expect((vm.state as ChatReady).askRecovery, isFalse,
          reason: 'request frame may still be in flight');

      // After the delay the card appears — nothing else fires while the
      // agent is blocked in the tool.
      await Future<void>.delayed(const Duration(milliseconds: 3500));
      expect((vm.state as ChatReady).askRecovery, isTrue);

      // Retry path works: the sheet arriving (bridge replay) hides it.
      ch.push(const ExtensionUiRequest(
        id: 'tool:tc_ask1',
        method: ExtensionUiMethod.select,
        title: 'Direction',
        options: ['Alpha', 'Beta'],
      ));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((vm.state as ChatReady).askRecovery, isFalse,
          reason: 'open sheet is the answer path, no card needed');
      expect((vm.state as ChatReady).pendingUiRequest?.id, 'tool:tc_ask1');

      // And once the tool completes, no card even without a sheet.
      ch.push(ToolResult(toolCallId: 'tc_ask1', result: 'answered'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((vm.state as ChatReady).askRecovery, isFalse);

      vm.dispose();
      sync.dispose();
      conn.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('a SECOND ask_user flow re-arms the recovery timer (PR #59 review #1)',
        () async {
      final ch = _FakeChannel();
      final storage = _FakeStorage();
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      final boxes = LocalBoxes();
      final msgBox = await boxes.msgsBox(_peer.remoteEpk, 'main');
      await msgBox.clear();
      final sync = SyncService(conn, boxes);
      final read = SessionReadRepository(boxes);
      final prefs = Preferences(_FakeSecureStorage());
      await prefs.setSelectedPeerEpk(_peer.remoteEpk);
      await prefs.setSelectedRoom(epk: _peer.remoteEpk, roomId: 'main');

      conn.adopt(ch, _peer);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final vm = ChatViewModel(read, sync, conn, prefs, storage);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Flow 1: pending, no sheet → card after the delay; then answered.
      ch.push(UserInput(id: 'ask-a1', text: 'first question'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      ch.push(ToolRequest(
        toolCallId: 'tc_a1',
        tool: 'ask_user',
        args: null,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 3500));
      expect((vm.state as ChatReady).askRecovery, isTrue,
          reason: 'first flow armed and fired its timer');
      ch.push(ToolResult(toolCallId: 'tc_a1', result: 'answered'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect((vm.state as ChatReady).askRecovery, isFalse);

      // Flow 2 with NO other state change in between: the one-shot timer
      // must re-arm. Pre-fix the slot stayed non-null after the first fire,
      // so nothing recomputed and the second card never appeared.
      ch.push(UserInput(id: 'ask-a2', text: 'second question'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      ch.push(ToolRequest(
        toolCallId: 'tc_a2',
        tool: 'ask_user',
        args: null,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 3500));
      expect((vm.state as ChatReady).askRecovery, isTrue,
          reason: 'second flow must arm its own delayed recompute');

      vm.dispose();
      sync.dispose();
      conn.dispose();
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('route_error for the active room clears the steering label and '
        'surfaces a warning row', () async {
      final ch = _FakeChannel();
      final storage = _FakeStorage();
      final conn = ConnectionManager(
        factory: (_, _) async => ch,
        storage: storage,
        emitDebounce: Duration.zero,
      );
      final boxes = LocalBoxes();
      final msgBox = await boxes.msgsBox(_peer.remoteEpk, 'main');
      await msgBox.clear();
      final sync = SyncService(conn, boxes);
      final read = SessionReadRepository(boxes);
      final prefs = Preferences(_FakeSecureStorage());
      await prefs.setSelectedPeerEpk(_peer.remoteEpk);
      await prefs.setSelectedRoom(epk: _peer.remoteEpk, roomId: 'main');

      conn.adopt(ch, _peer);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final vm = ChatViewModel(read, sync, conn, prefs, storage);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // A confirmed steer whose consumption never comes (dead destination).
      ch.push(UserInput(
        id: 'steer-1',
        text: 'Re-propose the Ask User tool please',
        streamingBehavior: UserMessageStreamingBehavior.steer,
      ));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final steerRow = (vm.state as ChatReady)
          .messages
          .whereType<UserMsg>()
          .singleWhere((m) => m.id == 'steer-1');
      expect(steerRow.steering, isTrue,
          reason: 'precondition: label spins while unconsumed');

      // The relay NACKs the destination (peer, room).
      ch.pushControl(const RouteError(peer: 'epk_chat', room: 'main'));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final after = (vm.state as ChatReady).messages;
      final cleared = after.whereType<UserMsg>().singleWhere((m) => m.id == 'steer-1');
      expect(cleared.steering, isFalse,
          reason: 'route_error must end the unbounded steering… spinner');
      expect(
        after.whereType<AssistantMsg>().map((m) => m.text).any(
          (t) => t.contains('Not delivered'),
        ),
        isTrue,
        reason: 'the ⚠ row explains why the message went nowhere',
      );

      vm.dispose();
      sync.dispose();
      conn.dispose();
    });
  });
}
