import 'dart:async';
import 'dart:io' show Platform;

import 'package:app/data/notifications/local_notifications.dart';
import 'package:app/data/notifications/session_completion_notifications.dart';
import 'package:app/data/notifications/waiting_input_notifications.dart';
import 'package:app/data/preferences/preferences.dart';
import 'package:app/data/push/push_payload.dart';
import 'package:app/data/push/push_registration_store.dart';
import 'package:app/data/transport/balanced_connection_controller.dart';
import 'package:app/data/transport/connection_manager.dart';
import 'package:app/data/transport/epk_encoding.dart';
import 'package:app/data/transport/keep_alive_controller.dart';
import 'package:app/data/transport/relay_config.dart';
import 'package:app/domain/contracts/service.dart';
import 'package:app/pairing/storage.dart';
import 'package:app/protocol/protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:unifiedpush_android/unifiedpush_android.dart';
import 'package:unifiedpush_platform_interface/data/failed_reason.dart';
import 'package:unifiedpush_platform_interface/data/push_endpoint.dart';
import 'package:unifiedpush_platform_interface/data/push_message.dart';
import 'package:unifiedpush_platform_interface/unifiedpush_platform_interface.dart';

abstract interface class UnifiedPushConnector {
  Future<bool> initialize({
    required void Function(PushEndpoint endpoint, String instance)
    onNewEndpoint,
    required void Function(FailedReason reason, String instance)
    onRegistrationFailed,
    required void Function(String instance) onUnregistered,
    required void Function(PushMessage message, String instance) onMessage,
    required void Function(String instance) onTempUnavailable,
  });
  Future<void> register(String instance, {String? vapid});
  Future<void> unregister(String instance);
  Future<bool> tryUseCurrentOrDefaultDistributor();
  Future<List<String>> getDistributors();
  Future<String?> getDistributor();
  Future<void> saveDistributor(String distributor);
}

class FlutterUnifiedPushConnector implements UnifiedPushConnector {
  UnifiedPushPlatform get _platform => UnifiedPushPlatform.instance;

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
    // Use the official Android implementation directly. The umbrella package
    // also pulls its Linux/WebCrypto native build, which is unnecessary here.
    UnifiedPushAndroid.registerWith();
    await _platform.initializeCallback(
      onNewEndpoint: onNewEndpoint,
      onRegistrationFailed: onRegistrationFailed,
      onUnregistered: onUnregistered,
      onMessage: onMessage,
    );
    await _platform.initializeOnTempUnavailable(onTempUnavailable);
    return await _platform.getDistributor() != null;
  }

  @override
  Future<void> register(String instance, {String? vapid}) =>
      _platform.register(instance, const [], null, vapid);

  @override
  Future<void> unregister(String instance) => _platform.unregister(instance);

  @override
  Future<bool> tryUseCurrentOrDefaultDistributor() =>
      _platform.tryUseCurrentOrDefaultDistributor();

  @override
  Future<List<String>> getDistributors() => _platform.getDistributors(const []);

  @override
  Future<String?> getDistributor() => _platform.getDistributor();

  @override
  Future<void> saveDistributor(String distributor) =>
      _platform.saveDistributor(distributor);
}

enum UnifiedPushStatus {
  disabled,
  needsDistributor,
  registering,
  pendingValidation,
  validated,
  temporarilyUnavailable,
  unavailable,
  insecureTransport,
  error,
}

/// Plan 153 — connector, secure registration queue, validation and wake fan-out.
class UnifiedPushService extends ChangeNotifier implements Service {
  UnifiedPushService(
    this._prefs,
    this._conn,
    this._storage,
    this._balanced,
    this._keepAlive,
    this._completion,
    this._waiting, {
    UnifiedPushConnector? connector,
    PushRegistrationStore? store,
    LocalNotifications? localNotifications,
    bool Function()? isAndroid,
  }) : _connector = connector ?? FlutterUnifiedPushConnector(),
       _store = store ?? PushRegistrationStore(),
       _localNotifications = localNotifications,
       _isAndroid = isAndroid ?? _defaultIsAndroid;

  final Preferences _prefs;
  final ConnectionManager _conn;
  final PairingStorage _storage;
  final BalancedConnectionController _balanced;
  final KeepAliveController _keepAlive;
  final SessionCompletionNotifications _completion;
  final WaitingInputNotifications _waiting;
  final UnifiedPushConnector _connector;
  final PushRegistrationStore _store;
  final LocalNotifications? _localNotifications;
  final bool Function() _isAndroid;

  StreamSubscription<ControlInbound>? _pushSub;
  StreamSubscription<ConnectionStatus>? _statusSub;
  Future<void>? _initializing;
  Future<void> _messageChain = Future<void>.value();
  String? _registrationId;
  String? _vapidPublicKey;
  bool _configInFlight = false;
  bool _attached = false;
  bool _disposed = false;
  KeepAliveMode? _lastKeepAliveMode;
  UnifiedPushStatus _status = UnifiedPushStatus.disabled;
  String? _statusMessage;
  String? _distributor;
  List<String> _availableDistributors = const [];
  final Map<String, DateTime> _seenEvents = <String, DateTime>{};
  ({String epk, String roomId})? _lastRunWake;

  UnifiedPushStatus get status => _status;
  String? get statusMessage => _statusMessage;
  String? get distributor => _distributor;
  List<String> get availableDistributors => _availableDistributors;

  Future<void> attach({bool backgrounded = false}) {
    if (backgrounded) {
      _keepAlive.setBackgrounded(true);
      _balanced.setBackgrounded(true);
      _completion.setBackgrounded(true);
      _waiting.setBackgrounded(true);
    }
    return _initializing ??= _attach();
  }

  Future<void> _attach() async {
    if (_attached || _disposed) return;
    _attached = true;
    if (!_isAndroid()) {
      _setStatus(UnifiedPushStatus.unavailable, 'Android only');
      return;
    }
    _registrationId = await _store.getOrCreateRegistrationId();
    _vapidPublicKey = await _store.readVapidPublicKey();
    _lastKeepAliveMode = _prefs.keepAliveMode;
    _prefs.addListener(_onModeChanged);
    _storage.addListener(_onPeersChanged);
    _completion.addListener(updateRegistration);
    _pushSub = _conn.pushControlStream.listen(_onControl);
    _statusSub = _conn.statusStream.listen(_onConnectionStatus);
    try {
      await _connector.initialize(
        onNewEndpoint: (endpoint, instance) {
          unawaited(_onNewEndpoint(endpoint, instance));
        },
        onRegistrationFailed: (reason, instance) {
          _onRegistrationFailed(reason);
        },
        onUnregistered: (instance) {
          unawaited(_onUnregistered(instance));
        },
        onMessage: (message, instance) {
          // Connector callbacks are synchronous, but authorization and wake
          // handling are async. Serialize them so clear cannot overtake start.
          _messageChain = _messageChain
              .then((_) => _onMessage(message))
              .onError((_, _) {});
        },
        onTempUnavailable: (_) {
          _setStatus(
            UnifiedPushStatus.temporarilyUnavailable,
            'Distributor temporarily unavailable; local Balanced still works.',
          );
        },
      );
      _distributor = await _connector.getDistributor();
      await refreshDistributors();
      // Resolve an older unregister before any new registration can win the
      // race on a reconnect or a quick off/on mode switch.
      await _sendPendingUnregister();
      if (_prefs.keepAliveMode == KeepAliveMode.balanced) {
        await _registerWithDistributor();
        await updateRegistration();
      } else {
        _setStatus(UnifiedPushStatus.disabled);
      }
    } on Exception {
      _setStatus(
        UnifiedPushStatus.unavailable,
        'UnifiedPush is unavailable; local Balanced still works.',
      );
    }
  }

  Future<void> refreshDistributors() async {
    if (!_isAndroid()) return;
    try {
      final values = await _connector.getDistributors();
      if (_disposed) return;
      _availableDistributors = List.unmodifiable(values);
      notifyListeners();
    } on Exception {
      // The current status already explains distributor unavailability.
    }
  }

  Future<void> selectDistributor(String value) async {
    if (_disposed || value.isEmpty) return;
    try {
      await _connector.saveDistributor(value);
      _distributor = value;
      await _registerWithDistributor();
    } on Exception {
      _setStatus(UnifiedPushStatus.error, 'Could not select distributor.');
    }
  }

  Future<void> retry() async {
    if (_disposed) return;
    _configInFlight = false;
    await _registerWithDistributor();
    await updateRegistration();
  }

  Future<void> _registerWithDistributor() async {
    final id = _registrationId;
    if (id == null || _prefs.keepAliveMode != KeepAliveMode.balanced) return;
    final vapid = _vapidPublicKey;
    if (vapid == null || vapid.isEmpty) {
      _setStatus(UnifiedPushStatus.registering, 'Requesting relay push key…');
      _requestConfig();
      return;
    }
    try {
      final selected = await _connector.tryUseCurrentOrDefaultDistributor();
      _distributor = await _connector.getDistributor();
      if (!selected) {
        _setStatus(
          UnifiedPushStatus.needsDistributor,
          _availableDistributors.isEmpty
              ? 'Install a UnifiedPush distributor to wake new PC runs.'
              : 'Choose a UnifiedPush distributor.',
        );
        return;
      }
      _setStatus(UnifiedPushStatus.registering);
      await _connector.register(id, vapid: vapid);
    } on Exception {
      _setStatus(
        UnifiedPushStatus.unavailable,
        'Distributor unavailable; local Balanced still works.',
      );
    }
  }

  Future<void> _onNewEndpoint(PushEndpoint endpoint, String instance) async {
    if (_disposed || instance != _registrationId) return;
    if (_prefs.keepAliveMode != KeepAliveMode.balanced) {
      await unregister();
      return;
    }
    final keys = endpoint.pubKeySet;
    if (keys == null || keys.pubKey.isEmpty || keys.auth.isEmpty) {
      _setStatus(
        UnifiedPushStatus.error,
        'Distributor did not provide Web Push encryption keys.',
      );
      return;
    }
    final id = _registrationId!;
    final previous = await _store.read();
    final unchanged =
        previous != null &&
        previous.endpoint == endpoint.url &&
        previous.p256dh == keys.pubKey &&
        previous.auth == keys.auth;
    final registration = StoredPushRegistration(
      registrationId: id,
      endpoint: endpoint.url,
      p256dh: keys.pubKey,
      auth: keys.auth,
      temporary: endpoint.temporary,
      validated: unchanged && previous.validated,
    );
    await _store.write(registration);
    _setStatus(
      registration.validated
          ? UnifiedPushStatus.validated
          : UnifiedPushStatus.pendingValidation,
    );
    await _sendRegistration();
  }

  Future<void> updateRegistration() async {
    if (_disposed || !_attached) return;
    if (_prefs.keepAliveMode != KeepAliveMode.balanced) return;
    if ((await _pairedPeers()).isEmpty) {
      await unregister();
      return;
    }
    await _sendRegistration();
  }

  Future<void> _sendRegistration() async {
    final registration = await _store.read();
    if (registration == null ||
        _prefs.keepAliveMode != KeepAliveMode.balanced) {
      return;
    }
    if (_conn.status is! StatusOnline) return;
    if (!_hasProtectedTransport) {
      _setStatus(
        UnifiedPushStatus.insecureTransport,
        'Push registration needs wss, loopback, or the Tailscale VPN. '
        'Local Balanced remains available.',
      );
      return;
    }
    final peers = await _pairedPeers();
    if (peers.isEmpty) return;
    final completionRooms = <({String peer, String room})>[];
    for (final entry in _conn.roomsSnapshot.entries) {
      if (!peers.contains(entry.key)) continue;
      for (final room in entry.value) {
        if (_completion.isEnabled(entry.key, room.roomId)) {
          completionRooms.add((peer: entry.key, room: room.roomId));
        }
      }
    }
    // A mode switch or distributor callback may have unregistered while the
    // secure store and peer list were being read. Never resurrect that state.
    if (_prefs.keepAliveMode != KeepAliveMode.balanced ||
        await _store.readPendingUnregister() != null) {
      return;
    }
    final latest = await _store.read();
    if (latest == null ||
        latest.endpoint != registration.endpoint ||
        latest.p256dh != registration.p256dh ||
        latest.auth != registration.auth) {
      return;
    }
    final sent = _conn.sendPushControl(
      pushRegisterFrame(
        registrationId: registration.registrationId,
        deviceId: 'android-${registration.registrationId}',
        endpoint: registration.endpoint,
        p256dh: registration.p256dh,
        auth: registration.auth,
        temporary: registration.temporary,
        peers: peers.toList()..sort(),
        completionRooms: completionRooms,
      ),
    );
    if (sent) {
      _setStatus(
        registration.validated
            ? UnifiedPushStatus.validated
            : UnifiedPushStatus.pendingValidation,
      );
    }
  }

  Future<void> _onControl(ControlInbound frame) async {
    if (_disposed) return;
    switch (frame) {
      case PushConfig(:final enabled, :final vapidPublicKey, :final errorCode):
        _configInFlight = false;
        if (!enabled || vapidPublicKey == null || vapidPublicKey.isEmpty) {
          _setStatus(
            UnifiedPushStatus.unavailable,
            'Relay push is disabled${errorCode == null ? '' : ' ($errorCode)'}; '
            'local Balanced still works.',
          );
          return;
        }
        _vapidPublicKey = vapidPublicKey;
        await _store.writeVapidPublicKey(vapidPublicKey);
        await _registerWithDistributor();
      case PushRegisterOk(:final registrationId, :final state):
        if (registrationId != _registrationId) return;
        final current = await _store.read();
        if (current == null) return;
        final validated = state == 'validated';
        await _store.write(current.copyWith(validated: validated));
        _setStatus(
          validated
              ? UnifiedPushStatus.validated
              : UnifiedPushStatus.pendingValidation,
        );
      case PushValidateOk(:final registrationId):
        if (registrationId != _registrationId) return;
        final current = await _store.read();
        if (current == null) return;
        await _store.write(current.copyWith(validated: true));
        _setStatus(UnifiedPushStatus.validated);
      case PushUnregisterOk(:final registrationId):
        await _store.clearPendingUnregister();
        final current = await _store.read();
        if (current?.registrationId == registrationId) {
          await _store.clear();
        }
        if (_prefs.keepAliveMode == KeepAliveMode.balanced) {
          await _registerWithDistributor();
          await _sendRegistration();
        }
      case PushError(:final registrationId, :final code, :final message):
        _configInFlight = false;
        if (code == 'unknown_registration' && registrationId != null) {
          await _store.clearPendingUnregister();
          if (_prefs.keepAliveMode == KeepAliveMode.balanced) {
            await _registerWithDistributor();
            await _sendRegistration();
          }
          return;
        }
        if (code == 'registration_not_found' ||
            code == 'unknown_registration' ||
            code == 'stale_endpoint' ||
            code == 'endpoint_stale') {
          final current = await _store.read();
          if (current != null) {
            await _store.write(current.copyWith(validated: false));
          }
          await _sendRegistration();
        }
        _setStatus(UnifiedPushStatus.error, '$code: $message');
      default:
        return;
    }
  }

  Future<void> _onMessage(PushMessage message) async {
    if (_disposed || !message.decrypted) return;
    final allowedPeers = (await _pairedPeers()).toSet();
    final payload = PushPayload.tryParse(
      message.content,
      allowedPeers: allowedPeers,
    );
    if (payload == null || !_rememberEvent(payload.eventId)) return;
    if (payload.event == PushEventType.validate) {
      if (payload.registrationId != _registrationId) return;
      await _balanced.wakeForValidation();
      await _conn.resumeFromBalancedSleep();
      if (!_hasProtectedTransport || _conn.status is! StatusOnline) return;
      _conn.sendPushControl(
        pushValidateFrame(
          registrationId: payload.registrationId!,
          token: payload.token!,
        ),
      );
      return;
    }
    if (_prefs.keepAliveMode != KeepAliveMode.balanced) return;
    final epk = payload.peer!;
    final roomId = payload.roomId!;
    switch (payload.event) {
      case PushEventType.runStarted:
        _lastRunWake = (epk: epk, roomId: roomId);
        await _balanced.wakeForRunStarted();
        if (_keepAlive.isStartBlocked) await handleStartRefused();
      case PushEventType.runFinished:
        _lastRunWake = null;
        _balanced.noteRunFinished();
      case PushEventType.runDone:
        _lastRunWake = null;
        await _completion.showPush(
          epk: epk,
          roomId: roomId,
          endedAtMs: payload.endedAtMs!,
        );
        _balanced.noteRunFinished();
      case PushEventType.waitingStarted:
        await _balanced.wakeForWaiting();
        await _waiting.handlePush(epk: epk, roomId: roomId, waiting: true);
      case PushEventType.waitingCleared:
        await _waiting.handlePush(epk: epk, roomId: roomId, waiting: false);
      case PushEventType.validate:
        return;
    }
  }

  /// Generic notification fallback when Android refuses the run-wake FGS.
  /// The normal FGS notification remains the primary run-started indication.
  Future<void> handleStartRefused() async {
    final target = _lastRunWake;
    final local = _localNotifications;
    if (target == null || local == null || _disposed) return;
    final key = SessionCompletionNotifications.prefsKey(
      target.epk,
      target.roomId,
    );
    final title = SessionCompletionNotifications.roomTitleFor(
      _conn,
      target.epk,
      target.roomId,
    );
    await local.show(
      id: SessionCompletionNotifications.stableNotificationId('wake|$key'),
      title: title == null || title.isEmpty ? 'Session' : title,
      body: 'New activity — tap to open.',
      payload: key,
    );
  }

  bool _rememberEvent(String id) {
    final now = DateTime.now();
    _seenEvents.removeWhere(
      (_, seenAt) => now.difference(seenAt) > const Duration(hours: 24),
    );
    if (_seenEvents.containsKey(id)) return false;
    _seenEvents[id] = now;
    if (_seenEvents.length > 512) _seenEvents.remove(_seenEvents.keys.first);
    return true;
  }

  void _onRegistrationFailed(FailedReason reason) {
    final message = switch (reason) {
      FailedReason.network =>
        'Distributor network unavailable; local Balanced still works.',
      FailedReason.actionRequired =>
        'Open the distributor and complete its required setup.',
      FailedReason.vapidRequired =>
        'Distributor requires a valid relay VAPID key.',
      FailedReason.internalError =>
        'Distributor registration failed; local Balanced still works.',
    };
    _setStatus(UnifiedPushStatus.unavailable, message);
  }

  Future<void> _onUnregistered(String instance) async {
    if (instance != _registrationId) return;
    await unregister();
    _setStatus(
      UnifiedPushStatus.unavailable,
      'Distributor removed the registration. Tap Retry to recover.',
    );
  }

  void _onConnectionStatus(ConnectionStatus status) {
    if (status is! StatusOnline) return;
    unawaited(_sendPendingUnregister());
    if (_prefs.keepAliveMode == KeepAliveMode.balanced) {
      _requestConfig();
      unawaited(_sendRegistration());
    }
  }

  void _onPeersChanged() {
    if (_disposed || _prefs.keepAliveMode != KeepAliveMode.balanced) return;
    unawaited(updateRegistration());
  }

  void _onModeChanged() {
    if (_disposed) return;
    final mode = _prefs.keepAliveMode;
    if (mode == _lastKeepAliveMode) return;
    _lastKeepAliveMode = mode;
    if (mode == KeepAliveMode.balanced) {
      unawaited(_registerWithDistributor());
      unawaited(updateRegistration());
    } else {
      _lastRunWake = null;
      unawaited(unregister());
    }
  }

  void _requestConfig() {
    if (_configInFlight || _conn.status is! StatusOnline) return;
    if (_conn.sendPushControl(pushConfigRequestFrame())) {
      _configInFlight = true;
    }
  }

  Future<void> unregister() async {
    final id = _registrationId;
    if (id == null) return;
    await _store.writePendingUnregister(id);
    await _store.clear();
    _setStatus(UnifiedPushStatus.disabled);
    await _sendPendingUnregister();
    try {
      await _connector.unregister(id);
    } on Exception {
      // The relay tombstone remains queued; local mode switching still works.
    }
  }

  Future<void> _sendPendingUnregister() async {
    final id = await _store.readPendingUnregister();
    if (id == null || _conn.status is! StatusOnline) return;
    _conn.sendPushControl(pushUnregisterFrame(id));
  }

  Future<List<String>> _pairedPeers() async {
    final peers = await _storage.listPeers();
    return peers.map((peer) => toStandardB64(peer.remoteEpk)).toList();
  }

  bool get _hasProtectedTransport {
    if (_conn.isTransportSecure) return true;
    final raw = _prefs.lastGoodRelayUrl ?? resolveRelayUrl(_prefs);
    final uri = Uri.tryParse(raw);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    if (host.endsWith('.ts.net')) return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    return a == 100 && b != null && b >= 64 && b <= 127;
  }

  void _setStatus(UnifiedPushStatus value, [String? message]) {
    if (_disposed) return;
    if (_status == value && _statusMessage == message) return;
    _status = value;
    _statusMessage = message;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pushSub?.cancel();
    _statusSub?.cancel();
    if (_attached && _isAndroid()) {
      _prefs.removeListener(_onModeChanged);
      _storage.removeListener(_onPeersChanged);
      _completion.removeListener(updateRegistration);
    }
    super.dispose();
  }
}

bool _defaultIsAndroid() => Platform.isAndroid;
