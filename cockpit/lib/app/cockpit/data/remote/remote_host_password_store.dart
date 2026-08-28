import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Guarda a senha SSH de um host no **Keychain/Keystore** (via
/// `flutter_secure_storage`), keyed por `host.id` — nunca no JSON de hosts
/// (plano 60, Wave C, decisão A). Funciona nos dois lados: mobile passa a senha
/// ao dartssh2; desktop injeta via `SSH_ASKPASS`.
class RemoteHostPasswordStore {
  RemoteHostPasswordStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _prefix = 'cockpit.ssh.password.';

  /// Teto de cada chamada. O Keychain é IPC com um serviço do sistema: além de
  /// lançar, ele pode simplesmente não responder (diálogo de permissão que não
  /// aparece, keychain travado). Sem teto, a operação do usuário fica pendurada
  /// para sempre — e como o future costuma ser descartado no `onPressed`, some
  /// sem erro nenhum na tela.
  static const _timeout = Duration(seconds: 5);

  String _key(String hostId) => '$_prefix$hostId';

  /// Senha do host, ou `null` se não houver (ou se o Keychain falhar).
  Future<String?> read(String hostId) async =>
      await _guard<String?>('read', () => _storage.read(key: _key(hostId)));

  /// Grava (ou remove, se [password] for `null`/vazia) a senha do host.
  Future<void> write(String hostId, String? password) async {
    if (password == null || password.isEmpty) {
      await remove(hostId);
      return;
    }
    await _guard(
      'write',
      () => _storage.write(key: _key(hostId), value: password),
    );
  }

  /// Apaga a senha do host (ao remover o host, ou ao trocar pra auth por chave).
  Future<void> remove(String hostId) =>
      _guard('delete', () => _storage.delete(key: _key(hostId)));

  /// Nenhuma falha do Keychain pode derrubar a operação que a chamou.
  ///
  /// Guardar senha é ACESSÓRIO: a fonte da verdade dos hosts é o JSON. Quando
  /// isto propagava, editar ou remover um host morria antes de salvar — e
  /// como só editar/remover mexem no Keychain (adicionar com auth por chave
  /// não mexe), o sintoma era "adicionar funciona, editar e remover não".
  Future<T?> _guard<T>(String op, Future<T> Function() action) async {
    try {
      return await action().timeout(_timeout);
    } on Object catch (e) {
      debugPrint('remote host password: $op falhou ($e)');
      return null;
    }
  }
}
