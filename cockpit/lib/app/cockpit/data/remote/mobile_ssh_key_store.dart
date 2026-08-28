import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pinenacl/ed25519.dart' show SigningKey;

/// Identidade SSH do dispositivo (plano 59, decisão E). O iPad/Android não tem
/// `~/.ssh`, então geramos um par **ed25519** na primeira conexão e guardamos a
/// chave privada no **Keychain/Keystore** (via `flutter_secure_storage`). A
/// linha pública (`ssh-ed25519 ... cockpit@mobile`) é o que o usuário cola no
/// `~/.ssh/authorized_keys` do host.
///
/// Só o mobile usa isto: no desktop o transporte segue no `ssh` do sistema (com
/// `~/.ssh`/agent). Ver [[project_cockpit_ipad_plan59]].
class MobileSshKeyStore {
  MobileSshKeyStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _pemKey = 'cockpit.ssh.ed25519.pem';
  static const _pubKey = 'cockpit.ssh.ed25519.pub';
  static const _comment = 'cockpit@mobile';

  /// Identidades pro `SSHClient` (gera+persiste na 1ª vez).
  Future<List<SSHKeyPair>> identities() async =>
      SSHKeyPair.fromPem(await _ensurePem());

  /// Linha `authorized_keys` pra o usuário copiar pro host.
  Future<String> publicKeyLine() async {
    final existing = await _storage.read(key: _pubKey);
    if (existing != null && existing.isNotEmpty) return existing;
    // Sem a pública salva (chave antiga só com PEM): regenera a partir do zero
    // não serve; mas geramos as duas juntas, então isto só ocorre em migração.
    await _ensurePem();
    return (await _storage.read(key: _pubKey)) ?? '';
  }

  Future<String> _ensurePem() async {
    final existing = await _storage.read(key: _pemKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final pair = generateEd25519KeyPair(_comment);
    await _storage.write(key: _pemKey, value: pair.pem);
    await _storage.write(key: _pubKey, value: pair.publicLine);
    return pair.pem;
  }
}

/// Par ed25519 recém-gerado: PEM OpenSSH (privada) + linha `authorized_keys`.
typedef GeneratedSshKey = ({String pem, String publicLine});

/// Gera um par **ed25519** e devolve o PEM OpenSSH (não-cifrado) + a linha
/// pública. Função pura (sem IO) pra ser testável — o layout de bytes do
/// ed25519 (público 32B, secret 64B = seed+público) precisa bater com o que o
/// `dartssh2` lê de volta.
GeneratedSshKey generateEd25519KeyPair(String comment) {
  final signing = SigningKey.generate();
  // SigningKey/VerifyKey são ByteList (List<int>): a SigningKey carrega o secret
  // de 64B (seed+público); a VerifyKey, os 32B públicos.
  final publicKey = Uint8List.fromList(signing.verifyKey); // 32B
  final privateKey = Uint8List.fromList(signing); // 64B (seed+público)
  final pair = OpenSSHEd25519KeyPair(publicKey, privateKey, comment);
  return (
    pem: pair.toPem(),
    publicLine: _authorizedKeyLine(publicKey, comment),
  );
}

/// Monta a linha `authorized_keys`: `ssh-ed25519 <base64(blob)> <comment>`, onde
/// `blob = string("ssh-ed25519") + string(publicKey)` no formato wire do SSH
/// (`string x = uint32be(len) + x`).
String _authorizedKeyLine(Uint8List publicKey, String comment) {
  final blob = BytesBuilder();
  void writeString(List<int> bytes) {
    final len = ByteData(4)..setUint32(0, bytes.length);
    blob.add(len.buffer.asUint8List());
    blob.add(bytes);
  }

  writeString(ascii.encode('ssh-ed25519'));
  writeString(publicKey);
  return 'ssh-ed25519 ${base64.encode(blob.toBytes())} $comment';
}
