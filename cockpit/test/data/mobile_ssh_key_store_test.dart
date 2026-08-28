import 'dart:convert';
import 'dart:typed_data';

import 'package:cockpit/app/cockpit/data/remote/mobile_ssh_key_store.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('generateEd25519KeyPair', () {
    test('gera PEM OpenSSH que o dartssh2 lê de volta como 1 chave ed25519', () {
      final key = generateEd25519KeyPair('cockpit@test');

      // O round-trip é a validação real do layout de bytes: se público (32B) e
      // secret (64B) não baterem, fromPem lança ou a assinatura quebra.
      final pairs = SSHKeyPair.fromPem(key.pem);
      expect(pairs, hasLength(1));
    });

    test('linha authorized_keys tem formato ssh-ed25519 base64 valido', () {
      final key = generateEd25519KeyPair('cockpit@test');
      final parts = key.publicLine.split(' ');

      expect(parts, hasLength(3));
      expect(parts[0], 'ssh-ed25519');
      expect(parts[2], 'cockpit@test');

      // O blob decodifica e comeca com string("ssh-ed25519") + string(pub32).
      final blob = base64.decode(parts[1]);
      final reader = _Reader(blob);
      expect(utf8.decode(reader.readString()), 'ssh-ed25519');
      expect(reader.readString(), hasLength(32)); // chave publica ed25519
    });

    test('duas chamadas geram chaves distintas', () {
      final a = generateEd25519KeyPair('c');
      final b = generateEd25519KeyPair('c');
      expect(a.pem, isNot(b.pem));
      expect(a.publicLine, isNot(b.publicLine));
    });
  });
}

/// Leitor mínimo do formato wire (uint32be len + bytes) pro teste.
class _Reader {
  _Reader(this._bytes);
  final Uint8List _bytes;
  int _offset = 0;

  Uint8List readString() {
    final len = ByteData.sublistView(_bytes, _offset, _offset + 4).getUint32(0);
    _offset += 4;
    final out = _bytes.sublist(_offset, _offset + len);
    _offset += len;
    return out;
  }
}
