import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:app/data/local/boxes.dart';
import 'package:app/data/notifications/local_notifications.dart';
import 'package:app/data/notifications/session_completion_notifications.dart';
import 'package:app/data/notifications/waiting_input_notifications.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/push/push_registration_store.dart';
import 'package:app/data/push/unified_push_service.dart';
import 'package:app/data/transport/balanced_connection_controller.dart';
import 'package:app/data/transport/channel.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/keep_alive_controller.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unifiedpush_platform_interface/data/failed_reason.dart';
import 'package:unifiedpush_platform_interface/data/public_key_set.dart';
import 'package:unifiedpush_platform_interface/data/push_endpoint.dart';
import 'package:unifiedpush_platform_interface/data/push_message.dart';

final _epk = base64.encode(List<int>.generate(32, (i) => i + 1));
final _peer = PeerRecord(
  remoteEpk: _epk,
  sessionName: 'test',
  relayUrl: 'wss://relay.example',
  pairedAt: '2026-01-01T00:00:00Z',
);

class _SecureStore implements FlutterSecureStorage {
  final values = <String, String>{};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];
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
    if (value == null) values.remove(key);
    if (value != null) values[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values.remove(key);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Storage extends PairingStorage {
  @override
  Future<List<PeerRecord>> listPeers() async => [_peer];
  @override
  Future<List<PersistedRoom>> loadRooms(String epk) async => const [];
  @override
  Future<void> saveRooms(String epk, List<PersistedRoom> rooms) async {}
}

class _Prefs extends Preferences {
  KeepAliveMode _mode = KeepAliveMode.balanced;
  @override
  KeepAliveMode get keepAliveMode => _mode;
  void setMode(KeepAliveMode value) {
    _mode = value;
    notifyListeners();
  }

  @override
  String? get lastGoodRelayUrl => 'wss://relay.example';
}

class _KeepAlive extends KeepAliveController {
  _KeepAlive(super.prefs) : super(isAndroid: () => false);
  bool blocked = false;
  @override
  bool get isStartBlocked => blocked;
  @override
  void setBalancedActive(bool active) {}
  @override
  void setBackgrounded(bool backgrounded) {}
}

class _Channel implements IChannel, IControlLink, ITransportSecurityInfo {
  _Channel([this.secure = true]);
  final bool secure;
  final _server = StreamController<ServerMessage>.broadcast();
  final _control = StreamController<ControlInbound>.broadcast();
  final controls = <Map<String, dynamic>>[];
  @override
  bool get isTransportSecure => secure;
  @override
  Stream<ServerMessage> get serverMessages => _server.stream;
  @override
  Stream<ControlInbound> get controlFrames => _control.stream;
  @override
  void sendControl(Map<String, dynamic> json) => controls.add(json);
  @override
  Future<void> send(ClientMessage msg) async {}
  @override
  Future<void> close() async {
    await _server.close();
    await _control.close();
  }
}

class _UnusedNotifications implements LocalNotifications {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingNotifications implements LocalNotifications {
  final shown = <({int id, String title, String body, String? payload})>[];
  @override
  Future<void> show({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async => shown.add((id: id, title: title, body: body, payload: payload));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Completion extends SessionCompletionNotifications {
  _Completion() : super(boxes: LocalBoxes(), local: _UnusedNotifications());
  final pushed = <({String epk, String roomId, int endedAtMs})>[];
  @override
  Future<void> showPush({
    required String epk,
    required String roomId,
    required int endedAtMs,
  }) async => pushed.add((epk: epk, roomId: roomId, endedAtMs: endedAtMs));
  @override
  bool isEnabled(String epk, String roomId) => true;
  @override
  void setBackgrounded(bool backgrounded) {}
}

class _Waiting extends WaitingInputNotifications {
  _Waiting() : super(boxes: LocalBoxes(), local: _UnusedNotifications());
  final pushed = <({String epk, String roomId, bool waiting})>[];
  @override
  Future<void> handlePush({
    required String epk,
    required String roomId,
    required bool waiting,
  }) async => pushed.add((epk: epk, roomId: roomId, waiting: waiting));
  @override
  void setBackgrounded(bool backgrounded) {}
}

class _Connector implements UnifiedPushConnector {
  void Function(PushEndpoint endpoint, String instance)? newEndpoint;
  void Function(FailedReason reason, String instance)? failed;
  void Function(String instance)? unregistered;
  void Function(PushMessage message, String instance)? message;
  void Function(String instance)? unavailable;
  int registerCalls = 0;
  String? instance;
  String? vapid;
  String distributor = 'ntfy';

  @override
  Future<bool> initialize({
    required void Function(PushEndpoint endpoint, String instance)
    onNewEndpoint,
    required void Function(FailedReason reason, String instance)
    onRegistrationFailed,
    required void Function(String instance) onUnregistered,
    required void Function(PushMessage message, String instance) onMessage,
    required void Function(String instance) onTempUnavailable,
  }) async {
    newEndpoint = onNewEndpoint;
    failed = onRegistrationFailed;
    unregistered = onUnregistered;
    message = onMessage;
    unavailable = onTempUnavailable;
    return true;
  }

  @override
  Future<void> register(String instance, {String? vapid}) async {
    registerCalls++;
    this.instance = instance;
    this.vapid = vapid;
  }

  @override
  Future<void> unregister(String instance) async {}
  @override
  Future<bool> tryUseCurrentOrDefaultDistributor() async => true;
  @override
  Future<List<String>> getDistributors() async => ['ntfy', 'other'];
  @override
  Future<String?> getDistributor() async => distributor;
  @override
  Future<void> saveDistributor(String value) async => distributor = value;

  void endpoint({bool temporary = false}) => newEndpoint?.call(
    PushEndpoint(
      'https://push.example/endpoint',
      PublicKeySet('p256dh', 'auth'),
      temporary: temporary,
    ),
    instance!,
  );

  void push(Map<String, dynamic> payload, {bool decrypted = true}) =>
      message?.call(
        PushMessage(
          Uint8List.fromList(utf8.encode(jsonEncode(payload))),
          decrypted,
        ),
        instance ?? 'pending',
      );
}

Map<String, dynamic> _event(String event, String id) => {
  'v': 1,
  'event': event,
  'event_id': id,
  'peer': _epk,
  'room': 'main',
  'occurred_at': 1790000000000,
  if (event == 'run_done') 'ended_at': 1790000000001,
};

Future<void> _flush() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'registration, validation, dedupe and wake use the relay contract',
    () async {
      final prefs = _Prefs();
      final channels = <_Channel>[];
      final cm = ConnectionManager(
        factory: (_, _) async {
          final channel = _Channel();
          channels.add(channel);
          return channel;
        },
        storage: _Storage(),
        emitDebounce: Duration.zero,
      );
      await cm.boot();
      final keepAlive = _KeepAlive(prefs);
      final balanced = BalancedConnectionController(prefs, cm, keepAlive)
        ..attach();
      balanced.setBackgrounded(true);
      final completion = _Completion();
      final waiting = _Waiting();
      final connector = _Connector();
      final local = _RecordingNotifications();
      final service = UnifiedPushService(
        prefs,
        cm,
        _Storage(),
        balanced,
        keepAlive,
        completion,
        waiting,
        connector: connector,
        store: PushRegistrationStore(_SecureStore()),
        localNotifications: local,
        isAndroid: () => true,
      );
      await service.attach();
      channels.single._control.add(
        const PushConfig(enabled: true, vapidPublicKey: 'vapid-public'),
      );
      await _flush();
      expect(connector.registerCalls, greaterThanOrEqualTo(1));
      expect(connector.vapid, 'vapid-public');
      final registrationsBefore = connector.registerCalls;
      final unregisterBefore = channels.single.controls
          .where((frame) => frame['type'] == 'push_unregister')
          .length;
      prefs.notifyListeners();
      await _flush();
      expect(connector.registerCalls, registrationsBefore);
      expect(
        channels.single.controls.where(
          (frame) => frame['type'] == 'push_unregister',
        ),
        hasLength(unregisterBefore),
      );

      connector.endpoint(temporary: true);
      await _flush();
      final registration = channels.single.controls.lastWhere(
        (frame) => frame['type'] == 'push_register',
      );
      expect(registration['endpoint'], 'https://push.example/endpoint');
      expect(registration['temporary'], isTrue);
      expect(registration['peers'], [_epk]);
      expect(registration['completion_rooms'], isEmpty);
      expect(service.status, UnifiedPushStatus.pendingValidation);

      channels.single._control.add(
        PushRegisterOk(registrationId: connector.instance!, state: 'pending'),
      );
      await _flush();
      connector.push({
        'v': 1,
        'event': 'push_validate',
        'event_id': 'validate-1',
        'registration_id': connector.instance,
        'token': 'validation-token',
        'occurred_at': 1790000000000,
      });
      await _flush();
      final validation = channels.single.controls.lastWhere(
        (frame) => frame['type'] == 'push_validate',
      );
      expect(validation['token'], 'validation-token');
      channels.single._control.add(
        PushValidateOk(registrationId: connector.instance!, state: 'validated'),
      );
      await _flush();
      expect(service.status, UnifiedPushStatus.validated);

      connector.push(_event('run_done', 'done-1'));
      connector.push(_event('run_done', 'done-1'));
      await _flush();
      expect(completion.pushed, hasLength(1));

      await cm.suspendForBalancedSleep();
      connector.push(_event('run_done', 'done-2'));
      await _flush();
      expect(
        channels,
        hasLength(1),
        reason: 'completion must not wake a socket',
      );
      expect(completion.pushed, hasLength(2));

      keepAlive.blocked = true;
      connector.push(_event('run_started', 'start-1'));
      await _flush();
      expect(channels, hasLength(2));
      expect(cm.status, isA<StatusOnline>());
      expect(local.shown, hasLength(1));
      expect(local.shown.single.body, 'New activity — tap to open.');

      connector.push(_event('waiting_started', 'wait-1'));
      connector.push(_event('waiting_cleared', 'wait-clear-1'));
      await _flush();
      expect(waiting.pushed.map((e) => e.waiting), [true, false]);
      connector.push(_event('run_finished', 'finish-1'));
      await _flush();
      await service.handleStartRefused();
      expect(local.shown, hasLength(1), reason: 'finished wake must be stale');

      connector.push(_event('run_started', 'undecrypted'), decrypted: false);
      await _flush();
      expect(channels, hasLength(2));

      service.dispose();
      balanced.dispose();
      completion.dispose();
      waiting.dispose();
      keepAlive.dispose();
      cm.dispose();
    },
  );

  test(
    'private cleartext relay blocks upload but keeps local Balanced',
    () async {
      final prefs = _Prefs();
      final channel = _Channel(false);
      final cm = ConnectionManager(
        factory: (_, _) async => channel,
        storage: _Storage(),
        emitDebounce: Duration.zero,
      );
      // A cleartext LAN endpoint is not a protected registration path.
      await cm.boot();
      final keepAlive = _KeepAlive(prefs);
      final balanced = BalancedConnectionController(prefs, cm, keepAlive)
        ..attach();
      balanced.setBackgrounded(true);
      final connector = _Connector();
      final service = UnifiedPushService(
        prefs,
        cm,
        _Storage(),
        balanced,
        keepAlive,
        _Completion(),
        _Waiting(),
        connector: connector,
        store: PushRegistrationStore(_SecureStore()),
        isAndroid: () => true,
      );
      await service.attach();
      channel._control.add(
        const PushConfig(enabled: true, vapidPublicKey: 'vapid-public'),
      );
      await _flush();
      connector.endpoint();
      await _flush();
      expect(service.status, UnifiedPushStatus.insecureTransport);
      expect(
        channel.controls.where((f) => f['type'] == 'push_register'),
        isEmpty,
      );

      service.dispose();
      balanced.dispose();
      keepAlive.dispose();
      cm.dispose();
    },
  );

  test('quick off/on waits for unregister ACK before re-registering', () async {
    final prefs = _Prefs();
    final channel = _Channel();
    final cm = ConnectionManager(
      factory: (_, _) async => channel,
      storage: _Storage(),
      emitDebounce: Duration.zero,
    );
    await cm.boot();
    final keepAlive = _KeepAlive(prefs);
    final balanced = BalancedConnectionController(prefs, cm, keepAlive)
      ..attach();
    final connector = _Connector();
    final secure = _SecureStore();
    final store = PushRegistrationStore(secure);
    final service = UnifiedPushService(
      prefs,
      cm,
      _Storage(),
      balanced,
      keepAlive,
      _Completion(),
      _Waiting(),
      connector: connector,
      store: store,
      isAndroid: () => true,
    );
    await service.attach();
    channel._control.add(
      const PushConfig(enabled: true, vapidPublicKey: 'vapid-public'),
    );
    await _flush();
    connector.endpoint();
    await _flush();
    final sentBefore = channel.controls
        .where((frame) => frame['type'] == 'push_register')
        .length;

    prefs.setMode(KeepAliveMode.off);
    await _flush();
    expect(await store.read(), isNull);
    expect(await store.readPendingUnregister(), connector.instance);
    prefs.setMode(KeepAliveMode.balanced);
    await _flush();
    expect(
      channel.controls.where((frame) => frame['type'] == 'push_register'),
      hasLength(sentBefore),
      reason: 'stale unregister must resolve before a new registration',
    );

    channel._control.add(PushUnregisterOk(registrationId: connector.instance!));
    await _flush();
    expect(await store.readPendingUnregister(), isNull);
    connector.endpoint();
    await _flush();
    expect(
      channel.controls.where((frame) => frame['type'] == 'push_register'),
      hasLength(sentBefore + 1),
    );

    service.dispose();
    balanced.dispose();
    keepAlive.dispose();
    cm.dispose();
  });
}
