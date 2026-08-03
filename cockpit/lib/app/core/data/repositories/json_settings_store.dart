import 'package:cockpit/app/core/data/setup/json_state_store.dart';
import 'package:cockpit/app/core/domain/contracts/settings_store.dart';
import 'package:cockpit/app/core/domain/entities/app_settings.dart';

/// Persiste as [AppSettings] num [JsonStateStore] (um único registro JSON sob
/// a chave [_key]). Substitui o antigo `HiveSettingsStore` — mesma semântica.
class JsonSettingsStore implements SettingsStore {
  JsonSettingsStore(this._store);

  final JsonStateStore _store;

  static const String storeName = 'settings';
  static const String _key = 'app';

  @override
  Future<AppSettings> load() async {
    final raw = _store.get(_key);
    if (raw is Map) {
      final settings = AppSettings.fromJson(raw);
      // Migração: um registro salvo por uma versão ANTERIOR à flag `enableAgent`
      // não tem essa chave. Esses usuários já usavam agentes → preservamos
      // ligando a flag (e persistindo, pra não re-migrar). Instalação nova nunca
      // cai aqui: ou não tem registro (fresh), ou já grava a chave (= false).
      if (!raw.containsKey('enableAgent')) {
        final migrated = settings.copyWith(enableAgent: true);
        await save(migrated);
        return migrated;
      }
      // Migração: registro sem `showCockpit` (versão anterior à flag) → liga o
      // workspace de sistema e persiste (default já é true; grava pra não
      // re-migrar e alinhar com o padrão de `enableAgent`).
      if (!raw.containsKey('showCockpit')) {
        final migrated = settings.copyWith(showCockpit: true);
        await save(migrated);
        return migrated;
      }
      return settings;
    }
    return const AppSettings();
  }

  @override
  Future<void> save(AppSettings settings) =>
      _store.put(_key, settings.toJson());
}
