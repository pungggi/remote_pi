import 'package:cockpit/app/cockpit/domain/contracts/dismissed_update_store.dart';
import 'package:cockpit/app/core/data/setup/json_state_store.dart';

/// Persiste a versão de atualização dispensada numa chave própria do store de
/// settings (reusa o store — só uma String).
class JsonDismissedUpdateStore implements DismissedUpdateStore {
  JsonDismissedUpdateStore(this._store);

  final JsonStateStore _store;

  static const String _key = 'dismissed_update_version';

  @override
  String? dismissedVersion() {
    final raw = _store.get(_key);
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  @override
  Future<void> dismiss(String version) => _store.put(_key, version);
}
