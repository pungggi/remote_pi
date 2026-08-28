import 'package:cockpit/app/cockpit/domain/entities/remote_host.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RemoteHost.fromJson', () {
    test('legado (só ssh) → porta 22, auth chave', () {
      final h = RemoteHost.fromJson({
        'id': '1',
        'name': 'box',
        'ssh': 'jacob@host',
      });
      expect(h.sshTarget, 'jacob@host');
      expect(h.port, 22);
      expect(h.auth, RemoteHostAuth.key);
      expect(h.user, 'jacob');
      expect(h.host, 'host');
    });

    test('legado com porta embutida (user@host:2222) é extraída', () {
      final h = RemoteHost.fromJson({
        'id': '1',
        'name': 'box',
        'ssh': 'jacob@host:2222',
      });
      expect(h.sshTarget, 'jacob@host');
      expect(h.port, 2222);
    });

    test('novo formato lê port + auth password', () {
      final h = RemoteHost.fromJson({
        'id': '1',
        'name': 'box',
        'ssh': 'jacob@host',
        'port': 2200,
        'auth': 'password',
      });
      expect(h.port, 2200);
      expect(h.auth, RemoteHostAuth.password);
    });

    test('round-trip toJson→fromJson preserva tudo', () {
      const h = RemoteHost(
        id: '9',
        name: 'prod',
        sshTarget: 'deploy@1.2.3.4',
        port: 2022,
        auth: RemoteHostAuth.password,
      );
      final back = RemoteHost.fromJson(h.toJson());
      expect(back.sshTarget, h.sshTarget);
      expect(back.port, h.port);
      expect(back.auth, h.auth);
      expect(back.name, h.name);
      expect(back.id, h.id);
    });

    test('user/host derivam sem @', () {
      const h = RemoteHost(id: '1', name: 'x', sshTarget: 'onlyhost');
      expect(h.user, '');
      expect(h.host, 'onlyhost');
    });
  });
}
