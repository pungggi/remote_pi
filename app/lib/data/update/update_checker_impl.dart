import 'dart:convert';

import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/entities/update_info.dart';
import 'package:dio/dio.dart';

/// Busca o `latest.json` do app via HTTP (Dio — mesmo client já usado pelo
/// mesh, plano 24). Timeout curto; qualquer falha → `null` (nunca lança), pra
/// que o aviso seja totalmente silencioso quando offline/indisponível.
///
/// Espelha o schema do manifest do Cockpit (plano 43/44), com 1 artefato
/// `android`/`apk`. O parsing/validação fica em [UpdateInfo.fromJson].
class UpdateCheckerImpl implements UpdateChecker {
  UpdateCheckerImpl({
    String? manifestUrl,
    Duration timeout = const Duration(seconds: 5),
    Dio? dio,
  })  : manifestUrl = manifestUrl ?? defaultManifestUrl,
        _dio = dio ?? _defaultDio(timeout);

  /// Manifest do **fork**, servido pelo branch `downloads` deste repositório.
  ///
  /// O upstream serve o dele de um host próprio (rp-s3 numa VPS); o fork não tem
  /// essa infra, e apontar pra lá faria o Piper oferecer builds do Remote Pi.
  /// `raw.githubusercontent` dá URL estável sem host novo — o gate de publicação
  /// deixa de ser "copiar o arquivo no volume" e passa a ser um commit naquele
  /// branch.
  ///
  /// Não dá pra usar `/releases/latest/download/`: as releases do repo se
  /// dividem em `app-v*` e `cockpit-v*`, e `latest` devolveria a mais recente
  /// entre as duas — ora o app, ora o Cockpit.
  static const String defaultManifestUrl =
      'https://raw.githubusercontent.com/pungggi/remote_pi/downloads/app/latest.json';

  final String manifestUrl;
  final Dio _dio;

  static Dio _defaultDio(Duration timeout) {
    return Dio(
      BaseOptions(
        connectTimeout: timeout,
        sendTimeout: timeout,
        receiveTimeout: timeout,
        // Tratamos status não-2xx manualmente — não deixa o Dio lançar.
        validateStatus: (_) => true,
        // Plain: jsonDecode manual, não deixa o parser do Dio tropeçar num
        // corpo vazio/não-JSON num 4xx/5xx.
        responseType: ResponseType.plain,
      ),
    );
  }

  @override
  Future<UpdateInfo?> fetchLatest() async {
    try {
      final response = await _dio.getUri<Object?>(Uri.parse(manifestUrl));
      if (response.statusCode != 200) return null;
      final data = response.data;
      final body = data is String ? data : null;
      if (body == null || body.isEmpty) return null;
      return UpdateInfo.fromJson(jsonDecode(body));
    } catch (_) {
      // sem rede / 404 / JSON inválido / schema errado → silencioso.
      return null;
    }
  }
}
