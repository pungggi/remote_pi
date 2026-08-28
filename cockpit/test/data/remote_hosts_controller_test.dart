import 'dart:async';

import 'package:cockpit/app/cockpit/data/remote/remote_host_password_store.dart';
import 'package:cockpit/app/cockpit/domain/contracts/remote_hosts_store.dart';
import 'package:cockpit/app/cockpit/domain/entities/remote_host.dart';
import 'package:cockpit/app/cockpit/domain/entities/remote_workspace_pin.dart';
import 'package:cockpit/app/cockpit/ui/remote/remote_hosts_controller.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guardar senha é ACESSÓRIO — a fonte da verdade dos hosts é o JSON. Quando o
/// Keychain vinha antes do save e não respondia, editar e remover host
/// simplesmente não aconteciam, sem erro na tela (o future do onPressed é
/// descartado). Adicionar funcionava porque, na auth por chave, ele nem toca no
/// Keychain — foi essa assimetria que denunciou o bug.
void main() {
  late _FakeStore store;
  late RemoteHostsController controller;

  setUp(() {
    store = _FakeStore();
    controller = RemoteHostsController(store)
      ..passwordStoreForTest = RemoteHostPasswordStore(
        storage: const _HangingStorage(),
      );
  });

  test('editar a chave salva mesmo com o Keychain pendurado', () async {
    await store.save(
      const RemoteHost(
        id: '1',
        name: 'Rog',
        sshTarget: 'jacob@host',
        identityFile: '/Users/jacob/.ssh/id_ed25519.pub',
      ),
    );

    await controller
        .editHost('1', identityFile: '/Users/jacob/.ssh/id_ed25519')
        .timeout(const Duration(seconds: 2));

    expect(store.hosts().single.identityFile, '/Users/jacob/.ssh/id_ed25519');
  });

  test('remover host acontece mesmo com o Keychain pendurado', () async {
    await store.save(
      const RemoteHost(id: '1', name: 'Rog', sshTarget: 'jacob@host'),
    );

    await controller.removeHost('1').timeout(const Duration(seconds: 2));

    expect(store.hosts(), isEmpty);
  });
}

/// Keychain que NUNCA responde — o pior caso, e o que não deixava rastro.
class _HangingStorage implements FlutterSecureStorage {
  const _HangingStorage();

  @override
  dynamic noSuchMethod(Invocation invocation) => Completer<void>().future;
}

class _FakeStore implements RemoteHostsStore {
  final List<RemoteHost> _hosts = [];

  @override
  List<RemoteHost> hosts() => List.unmodifiable(_hosts);

  @override
  Future<void> save(RemoteHost host) async {
    _hosts
      ..removeWhere((h) => h.id == host.id)
      ..add(host);
  }

  @override
  Future<void> remove(String id) async => _hosts.removeWhere((h) => h.id == id);

  @override
  List<RemoteWorkspacePin> pins() => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
