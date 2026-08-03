import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/core/data/diagnostics/diagnostics_log.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Store KV persistido em **um arquivo JSON por nome** (`<dir>/<nome>.json`),
/// substituto das Boxes do Hive (que corrompiam no Windows: append-only +
/// `.lock` sob OneDrive/antivírus/shutdown sujo).
///
/// Semântica:
/// - Todo o conteúdo vive em memória (carregado no [open]); leituras são
///   síncronas, como numa Box.
/// - Escritas são **atômicas**: grava `<nome>.json.tmp` (com flush) e renomeia
///   por cima do definitivo — nunca existe um arquivo meio-escrito no disco.
///   Rename com retries curtos cobre lock transitório de antivírus/sync.
/// - `put`/`putAll`/`delete` têm **debounce** (~150ms) pra coalescer rajadas
///   (bounds de janela, layout). O `Future` retornado completa quando a rajada
///   foi persistida. [flush] força a escrita imediata.
/// - Leitura tolerante: arquivo ausente = vazio; JSON inválido = loga no
///   [DiagnosticsLog] e começa vazio — corromper NUNCA derruba o boot.
///
/// Envelope no disco: `{"version": 1, "data": {...}}`. Valores devem ser
/// JSON-encodáveis (primitivos, String, List, Map com chaves String).
class JsonStateStore {
  JsonStateStore._(this._file, this._data);

  /// Instâncias vivas por caminho absoluto — [open] é idempotente (mesmo
  /// contrato do `Hive.openBox`), o que mantém o retry do bootstrap seguro e
  /// garante que bootstrapper e módulos compartilhem o MESMO estado.
  static final Map<String, JsonStateStore> _instances = {};

  static const int _formatVersion = 1;

  /// Janela do debounce: curta o bastante pra perda máxima ser desprezível,
  /// longa o bastante pra coalescer um drag de janela inteiro em 1-2 escritas.
  static const Duration debounceWindow = Duration(milliseconds: 150);

  final File _file;
  final Map<String, dynamic> _data;

  Timer? _debounce;
  Completer<void>? _pending;
  Future<void> _writeChain = Future.value();
  bool _disposed = false;

  /// Caminho do arquivo persistido (útil em teste/diagnóstico).
  String get path => _file.path;

  /// Abre (ou devolve a instância já aberta de) `<dir>/<name>.json`.
  static Future<JsonStateStore> open(String dir, String name) async {
    // `p.join`/`p.normalize`: no Windows `dir` vem com `\` — nada de
    // interpolar `/` na mão (bug de campo com separadores mistos).
    final file = File(p.normalize(p.join(dir, '$name.json')));
    final existing = _instances[file.path];
    if (existing != null) return existing;
    final store = JsonStateStore._(file, await _load(file));
    _instances[file.path] = store;
    return store;
  }

  /// Carrega o conteúdo do disco. Qualquer problema (ausente, ilegível, JSON
  /// inválido, envelope estranho) → mapa vazio, com log quando havia arquivo.
  static Future<Map<String, dynamic>> _load(File file) async {
    try {
      if (!await file.exists()) return <String, dynamic>{};
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return <String, dynamic>{};
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final data = decoded['data'];
        if (data is Map) return data.cast<String, dynamic>();
      }
      throw const FormatException('envelope inesperado');
    } catch (e) {
      DiagnosticsLog.instance.log(
        'json-store',
        'arquivo ${file.path} ilegível/corrompido ($e) — começando vazio',
      );
      return <String, dynamic>{};
    }
  }

  // ── API KV (espelha o subconjunto de Box que o app usava) ────────────────

  dynamic get(String key) => _data[key];

  bool containsKey(String key) => _data.containsKey(key);

  Iterable<String> get keys => _data.keys;

  Iterable<dynamic> get values => _data.values;

  /// Snapshot raso do conteúdo atual.
  Map<String, dynamic> toMap() => Map<String, dynamic>.of(_data);

  Future<void> put(String key, Object? value) {
    _data[key] = value;
    return _scheduleWrite();
  }

  Future<void> putAll(Map<String, Object?> entries) {
    _data.addAll(entries);
    return _scheduleWrite();
  }

  Future<void> delete(String key) {
    _data.remove(key);
    return _scheduleWrite();
  }

  /// Persiste AGORA o que estiver pendente (cancela o debounce). Idempotente.
  Future<void> flush() {
    if (_pending == null) return _writeChain;
    _debounce?.cancel();
    return _commit();
  }

  /// Flush de todas as instâncias abertas — chamado na saída do app pra não
  /// perder a última rajada dentro da janela de debounce.
  static Future<void> flushAll() =>
      Future.wait(_instances.values.map((s) => s.flush()));

  /// Descarta a instância do cache (testes). NÃO grava pendências.
  @visibleForTesting
  static void resetCacheForTesting() {
    for (final s in _instances.values) {
      s._debounce?.cancel();
      s._disposed = true;
      final p = s._pending;
      if (p != null && !p.isCompleted) p.complete();
      s._pending = null;
    }
    _instances.clear();
  }

  Future<void> _scheduleWrite() {
    final pending = _pending ??= Completer<void>();
    _debounce?.cancel();
    _debounce = Timer(debounceWindow, () {
      unawaited(_commit());
    });
    return pending.future;
  }

  /// Fecha a rajada pendente e encadeia a escrita atômica. Serializado via
  /// [_writeChain]: nunca há dois writes simultâneos no mesmo arquivo.
  Future<void> _commit() {
    final pending = _pending;
    if (pending == null) return _writeChain;
    _pending = null;
    _debounce?.cancel();
    final snapshot = jsonEncode({'version': _formatVersion, 'data': _data});
    _writeChain = _writeChain.then((_) async {
      if (_disposed) return;
      try {
        await writeAtomic(_file, snapshot);
      } catch (e, stack) {
        // Falha de escrita não derruba nada: o estado segue em memória e a
        // próxima mutação tenta de novo. Fica no log pra forense.
        DiagnosticsLog.instance.logError('json-store', e, stack);
      }
    });
    return _writeChain.whenComplete(() {
      if (!pending.isCompleted) pending.complete();
    });
  }

  /// Escrita atômica: tmp + flush + rename por cima. Rename com retries
  /// (backoff curto) pra sobreviver a lock transitório no Windows. Também é o
  /// primitivo que a migração Hive→JSON usa pra despejar as boxes.
  static Future<void> writeAtomic(File file, String content) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    Object? last;
    for (final backoff in const [
      Duration.zero,
      Duration(milliseconds: 100),
      Duration(milliseconds: 250),
    ]) {
      if (backoff != Duration.zero) await Future<void>.delayed(backoff);
      try {
        await tmp.rename(file.path);
        return;
      } on FileSystemException catch (e) {
        last = e;
      }
    }
    throw last!;
  }
}
