import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class StoredPushRegistration {
  const StoredPushRegistration({
    required this.registrationId,
    required this.endpoint,
    required this.p256dh,
    required this.auth,
    required this.temporary,
    this.validated = false,
  });

  final String registrationId;
  final String endpoint;
  final String p256dh;
  final String auth;
  final bool temporary;
  final bool validated;

  StoredPushRegistration copyWith({bool? validated}) => StoredPushRegistration(
    registrationId: registrationId,
    endpoint: endpoint,
    p256dh: p256dh,
    auth: auth,
    temporary: temporary,
    validated: validated ?? this.validated,
  );

  Map<String, dynamic> toJson() => {
    'registration_id': registrationId,
    'endpoint': endpoint,
    'p256dh': p256dh,
    'auth': auth,
    'temporary': temporary,
    'validated': validated,
  };

  static StoredPushRegistration? fromJson(Map<String, dynamic> json) {
    final id = json['registration_id'];
    final endpoint = json['endpoint'];
    final p256dh = json['p256dh'];
    final auth = json['auth'];
    final temporary = json['temporary'];
    if (id is! String ||
        id.isEmpty ||
        endpoint is! String ||
        !_validEndpoint(endpoint) ||
        p256dh is! String ||
        p256dh.isEmpty ||
        auth is! String ||
        auth.isEmpty ||
        temporary is! bool) {
      return null;
    }
    return StoredPushRegistration(
      registrationId: id,
      endpoint: endpoint,
      p256dh: p256dh,
      auth: auth,
      temporary: temporary,
      validated: json['validated'] == true,
    );
  }

  static bool _validEndpoint(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.isNotEmpty;
  }
}

/// Sensitive endpoint/key material lives only in platform secure storage.
/// No getter or method in this store logs registration contents.
class PushRegistrationStore {
  PushRegistrationStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _registrationKey = 'push.registration.v1';
  static const _registrationIdKey = 'push.registration_id.v1';
  static const _vapidKey = 'push.vapid_public.v1';
  static const _pendingUnregisterKey = 'push.pending_unregister.v1';

  Future<StoredPushRegistration?> read() async {
    final raw = await _storage.read(key: _registrationKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        await _storage.delete(key: _registrationKey);
        return null;
      }
      final registration = StoredPushRegistration.fromJson(decoded);
      if (registration == null) await _storage.delete(key: _registrationKey);
      return registration;
    } on FormatException {
      await _storage.delete(key: _registrationKey);
      return null;
    }
  }

  Future<void> write(StoredPushRegistration registration) => _storage.write(
    key: _registrationKey,
    value: jsonEncode(registration.toJson()),
  );

  Future<void> clear() => _storage.delete(key: _registrationKey);

  Future<String> getOrCreateRegistrationId() async {
    final existing = await _storage.read(key: _registrationIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final id = base64Url.encode(bytes);
    await _storage.write(key: _registrationIdKey, value: id);
    return id;
  }

  Future<String?> readVapidPublicKey() => _storage.read(key: _vapidKey);

  Future<void> writeVapidPublicKey(String value) =>
      _storage.write(key: _vapidKey, value: value);

  Future<void> clearVapidPublicKey() => _storage.delete(key: _vapidKey);

  Future<String?> readPendingUnregister() =>
      _storage.read(key: _pendingUnregisterKey);

  Future<void> writePendingUnregister(String registrationId) =>
      _storage.write(key: _pendingUnregisterKey, value: registrationId);

  Future<void> clearPendingUnregister() =>
      _storage.delete(key: _pendingUnregisterKey);
}
