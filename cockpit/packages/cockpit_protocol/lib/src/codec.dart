import 'dart:convert';

import 'messages.dart';

/// Codec JSONL do protocolo: uma mensagem por linha, UTF-8.
///
/// O despacho é POR LINHA (nunca por onDone do socket) — a lição registrada
/// do socket da CLI interna: esperar onDone deadlocka request/response.
class RemoteMessageCodec {
  const RemoteMessageCodec();

  String encode(RemoteMessage message) => '${jsonEncode(message.toJson())}\n';

  RemoteMessage decodeLine(String line) {
    final decoded = jsonDecode(line);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('message is not a JSON object');
    }
    return RemoteMessage.fromJson(decoded);
  }

  /// Transforma o stream de bytes do socket em mensagens (split por linha).
  Stream<RemoteMessage> decodeStream(Stream<List<int>> bytes) => bytes
      // O stream do Socket é Stream<Uint8List> em runtime; sem o cast o
      // transform(utf8.decoder) lança type error.
      .cast<List<int>>()
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .where((line) => line.trim().isNotEmpty)
      .map(decodeLine);
}
