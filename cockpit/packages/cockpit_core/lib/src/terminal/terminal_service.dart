import 'dart:async';
import 'dart:typed_data';

/// Especificação de spawn de um PTY.
class PtySpawnSpec {
  const PtySpawnSpec({
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment = const {},
    this.rows = 24,
    this.columns = 80,
    this.flowControlled = false,
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String> environment;
  final int rows;
  final int columns;

  /// Backpressure fim-a-fim (plano 57): a leitura nativa é gateada por uma
  /// janela de créditos; o consumidor devolve [TerminalService.ack] por chunk
  /// consumido. Sem consumidor anexado, a leitura corre livre (scrollback).
  final bool flowControlled;
}

/// Metadados de uma sessão viva (ou finalizada e ainda anexável).
class PtySessionInfo {
  const PtySessionInfo({
    required this.id,
    required this.pid,
    required this.executable,
    required this.rows,
    required this.columns,
    required this.scrollbackLength,
    this.exitCode,
  });

  final String id;
  final int pid;
  final String executable;
  final int rows;
  final int columns;

  /// Total de bytes já produzidos pela sessão (offset absoluto do stream).
  final int scrollbackLength;

  /// Null enquanto o processo está vivo.
  final int? exitCode;

  bool get isAlive => exitCode == null;
}

/// Um trecho do stream de saída, endereçado por offset absoluto.
///
/// `offset` é a posição do primeiro byte de `bytes` no stream total da
/// sessão desde o spawn. Permite reattach sem perda nem duplicação.
class PtyOutputChunk {
  const PtyOutputChunk({required this.offset, required this.bytes});

  final int offset;
  final Uint8List bytes;
}

/// Eventos de uma sessão anexada.
sealed class PtyEvent {
  const PtyEvent();
}

class PtyOutputEvent extends PtyEvent {
  const PtyOutputEvent(this.chunk);
  final PtyOutputChunk chunk;
}

class PtyExitEvent extends PtyEvent {
  const PtyExitEvent(this.exitCode);
  final int exitCode;
}

/// Erros tipados do domínio de terminais (frases nascem na borda da UI).
enum TerminalErrorKind { sessionNotFound, spawnFailed, protocol, transport }

class TerminalException implements Exception {
  const TerminalException(this.kind, [this.detail]);
  final TerminalErrorKind kind;

  /// Texto cru de terceiros (errno, stderr); nunca frase user-facing nossa.
  final String? detail;

  @override
  String toString() =>
      'TerminalException(${kind.name}'
      '${detail == null ? '' : ': $detail'})';
}

/// Contrato do domínio Terminais.
///
/// Implementado nativamente pelo `cockpit_engine` (dentro do cockpit-server)
/// e remotamente pelo `cockpit_remote` (proxy falando o protocolo). Sessões
/// pertencem ao serviço, não a quem anexa: sobrevivem a detach de clientes.
abstract interface class TerminalService {
  /// Abre uma sessão nova e devolve seus metadados.
  Future<PtySessionInfo> open(PtySpawnSpec spec);

  /// Sessões existentes (vivas ou finalizadas com scrollback retido).
  Future<List<PtySessionInfo>> sessions();

  /// Anexa ao stream da sessão a partir de [fromOffset] (replay do
  /// scrollback retido + live). Cancelar a subscription é detach: a sessão
  /// continua viva.
  Stream<PtyEvent> attach(String sessionId, {int fromOffset = 0});

  /// Escreve bytes no stdin do PTY.
  Future<void> write(String sessionId, Uint8List data);

  Future<void> resize(String sessionId, int rows, int columns);

  /// Devolve crédito de flow control: [bytes] de output foram consumidos.
  /// No-op em sessões abertas sem [PtySpawnSpec.flowControlled].
  Future<void> ack(String sessionId, int bytes);

  /// Mata o processo e descarta a sessão (scrollback incluso).
  Future<void> kill(String sessionId);

  /// Libera recursos do serviço (não mata sessões no caso remoto).
  Future<void> dispose();
}
