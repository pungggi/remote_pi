import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cockpit/app/cockpit/domain/contracts/update_checker.dart';
import 'package:cockpit/app/cockpit/domain/entities/update_info.dart';

/// Busca o `latest.json` via HTTP (dart:io, sem dep extra). Timeout curto;
/// qualquer falha → `null` (nunca lança), pra que o aviso seja totalmente
/// silencioso quando offline/indisponível.
class UpdateCheckerImpl implements UpdateChecker {
  const UpdateCheckerImpl({
    this.manifestUrl = defaultManifestUrl,
    this.timeout = const Duration(seconds: 5),
  });

  /// Manifest do **fork**, servido pelo branch `downloads` deste repositório.
  ///
  /// O upstream serve o dele de um host próprio (rp-s3 numa VPS); o fork não tem
  /// essa infra, e apontar pra lá faria o Piper Cockpit oferecer builds do
  /// Remote Pi. `raw.githubusercontent` dá URL estável sem host novo — o gate de
  /// publicação deixa de ser "copiar o arquivo no volume" e passa a ser um
  /// commit naquele branch.
  ///
  /// Não dá pra usar `/releases/latest/download/`: as releases do repo se
  /// dividem em `app-v*` e `cockpit-v*`, e `latest` devolveria a mais recente
  /// entre as duas — ora o app, ora o Cockpit.
  static const String defaultManifestUrl =
      'https://raw.githubusercontent.com/pungggi/remote_pi/downloads/cockpit/latest.json';

  final String manifestUrl;
  final Duration timeout;

  @override
  Future<UpdateInfo?> fetchLatest() async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client
          .getUrl(Uri.parse(manifestUrl))
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) {
        await response.drain<void>();
        return null;
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      return UpdateInfo.fromJson(jsonDecode(body));
    } catch (_) {
      // sem rede / 404 / JSON inválido / schema errado → silencioso.
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
