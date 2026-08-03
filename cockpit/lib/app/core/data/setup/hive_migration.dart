import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/core/data/diagnostics/diagnostics_log.dart';
import 'package:cockpit/app/core/data/setup/json_state_store.dart';
import 'package:cockpit/app/core/data/setup/storage_location.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

/// Migração **one-shot** Hive→JSON. Este é o ÚNICO arquivo do app que ainda
/// importa `hive` — o pacote fica no pubspec só enquanto este migrador existir
/// (remoção total fica pra uma release futura, quando a base instalada tiver
/// migrado).
///
/// Contrato:
/// - `state/migration.json` existe → skip total (Hive nem é tocado).
/// - Senão, procura boxes legadas nos [StorageLocation.legacyHiveDirCandidates]
///   (override → AppData → Documents); a primeira pasta com boxes vence. Isso
///   substitui a antiga cópia Documents→AppData do Windows: o conteúdo migra
///   direto pro JSON no local novo.
/// - Cada box é despejada em `state/<nome>.json` (escrita atômica). Box que
///   falhar ao abrir/ler → JSON vazio + entrada em `failed` + DiagnosticsLog.
///   Nunca aborta a migração inteira por uma box.
/// - `migration.json` é gravado POR ÚLTIMO — é o commit. Morte no meio →
///   próximo boot refaz tudo (idempotente: os JSONs são reescritos do zero).
/// - As boxes `.hive` NÃO são apagadas (backup/rollback manual).
/// - Instalação fresca (nem JSON nem Hive) → grava o marcador com `from: null`
///   e os JSONs nascem sob demanda.
class HiveToJsonMigration {
  const HiveToJsonMigration({
    this.appVersion,
    this.stateDirOverride,
    this.legacyDirCandidatesOverride,
  });

  /// Versão do app registrada no marcador (informativa; pode faltar quando o
  /// PackageInfo não resolve — ex. testes).
  final String? appVersion;

  /// Overrides pra teste (evitam o path_provider): destino dos JSONs e a lista
  /// de pastas candidatas a boxes legadas. `null` = resolver via
  /// [StorageLocation].
  final String? stateDirOverride;
  final List<String>? legacyDirCandidatesOverride;

  /// As 5 boxes históricas do Cockpit.
  static const List<String> boxNames = [
    'settings',
    'window_state',
    'projects',
    'layouts',
    'realms',
  ];

  static const String markerFileName = 'migration.json';

  /// Roda a migração se o marcador ainda não existe. Retorna `true` quando
  /// esta chamada efetivamente migrou (ou selou uma instalação fresca).
  Future<bool> runIfNeeded() async {
    final stateDir = stateDirOverride ?? await StorageLocation.stateDir();
    final marker = File(p.join(stateDir, markerFileName));
    if (await marker.exists()) return false;

    final sourceDir = await _findLegacyHiveDir();
    final failed = <String>[];

    if (sourceDir != null) {
      Hive.init(sourceDir);
      const emptyPayload = '{"version":1,"data":{}}';
      for (final name in boxNames) {
        // O encode fica DENTRO do try: valor não-encodável (ex. double não
        // finito) também vira box "failed" em vez de abortar a migração.
        String payload;
        try {
          final box = await _openBoxWithRetry(name);
          payload = jsonEncode({
            'version': 1,
            'data': _jsonSafeMap(box.toMap()),
          });
          await box.close();
        } catch (e, stack) {
          DiagnosticsLog.instance.logError('hive-migration', e, stack);
          failed.add(name);
          payload = emptyPayload;
        }
        await JsonStateStore.writeAtomic(
          File(p.join(stateDir, '$name.json')),
          payload,
        );
      }
    }

    // Commit por último: só com o marcador no disco a migração "aconteceu".
    await JsonStateStore.writeAtomic(
      marker,
      jsonEncode({
        'from': sourceDir,
        'at': DateTime.now().toIso8601String(),
        'appVersion': appVersion,
        'failed': failed,
      }),
    );
    return true;
  }

  /// Primeira pasta candidata que contenha ao menos uma das boxes conhecidas.
  Future<String?> _findLegacyHiveDir() async {
    final candidates =
        legacyDirCandidatesOverride ??
        await StorageLocation.legacyHiveDirCandidates();
    for (final dir in candidates) {
      for (final name in boxNames) {
        if (await File(p.join(dir, '$name.hive')).exists()) return dir;
      }
    }
    return null;
  }

  /// Mesmo retry de lock do bootstrap antigo: o SO/OneDrive pode segurar o
  /// `.lock` por instantes depois de outra instância morrer (Windows).
  Future<Box<dynamic>> _openBoxWithRetry(String name) async {
    Object? last;
    for (var i = 0; i < 10; i++) {
      try {
        return await Hive.openBox<dynamic>(name);
      } on FileSystemException catch (e) {
        last = e;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    throw last!;
  }

  /// Converte o conteúdo da box pra algo JSON-encodável: chaves viram String
  /// e mapas aninhados (o Hive devolve `Map<dynamic, dynamic>`) são normalizados
  /// recursivamente. Valores não representáveis são descartáveis por definição
  /// (as boxes só guardam primitivos/String/Map/List).
  static Map<String, dynamic> _jsonSafeMap(Map<dynamic, dynamic> map) => {
    for (final entry in map.entries) '${entry.key}': _jsonSafe(entry.value),
  };

  static dynamic _jsonSafe(dynamic value) {
    if (value is Map) return _jsonSafeMap(value);
    if (value is List) return value.map(_jsonSafe).toList();
    return value;
  }
}
