import 'package:cockpit/app/cockpit/domain/contracts/remote_hosts_store.dart';
import 'package:cockpit/app/cockpit/domain/entities/remote_host.dart';
import 'package:cockpit/app/cockpit/domain/entities/remote_workspace_pin.dart';
import 'package:cockpit/app/core/data/setup/json_state_store.dart';

/// Hosts remotos no store JSON de estado (mesmo mecanismo pós-Hive).
class JsonRemoteHostsStore implements RemoteHostsStore {
  JsonRemoteHostsStore(this._store);

  final JsonStateStore _store;

  static const String _key = 'remote_hosts';
  static const String _pinsKey = 'remote_workspace_pins';

  @override
  List<RemoteHost> hosts() {
    final raw = _store.get(_key);
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) RemoteHost.fromJson(item.cast<String, Object?>()),
    ];
  }

  @override
  Future<void> save(RemoteHost host) {
    final all = [...hosts().where((h) => h.id != host.id), host];
    return _store.put(_key, [for (final h in all) h.toJson()]);
  }

  @override
  Future<void> remove(String id) {
    final all = hosts().where((h) => h.id != id);
    return _store.put(_key, [for (final h in all) h.toJson()]);
  }

  @override
  List<RemoteWorkspacePin> pins() {
    final raw = _store.get(_pinsKey);
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          RemoteWorkspacePin.fromJson(item.cast<String, Object?>()),
    ];
  }

  @override
  Future<void> savePin(RemoteWorkspacePin pin) {
    final all = [...pins().where((p) => p.id != pin.id), pin];
    return _store.put(_pinsKey, [for (final p in all) p.toJson()]);
  }

  @override
  Future<void> removePin(String id) {
    final all = pins().where((p) => p.id != id);
    return _store.put(_pinsKey, [for (final p in all) p.toJson()]);
  }
}
