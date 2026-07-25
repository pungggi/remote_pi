import 'dart:async';

import 'package:cockpit/app/cockpit/data/update/noop_self_updater.dart';
import 'package:cockpit/app/cockpit/domain/contracts/dismissed_update_store.dart';
import 'package:cockpit/app/cockpit/domain/contracts/self_updater.dart';
import 'package:cockpit/app/cockpit/domain/contracts/update_checker.dart';
import 'package:cockpit/app/cockpit/domain/contracts/url_opener.dart';
import 'package:cockpit/app/cockpit/domain/entities/update_info.dart';
import 'package:cockpit/app/cockpit/domain/value_objects/update_target.dart';
import 'package:cockpit/app/cockpit/ui/viewmodels/update_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Motor de self-update controlável: os testes empurram fases à mão, como o
/// Sparkle/WinSparkle fariam.
class _FakeSelfUpdater implements SelfUpdater {
  @override
  final bool isSupported = true;

  final _controller = StreamController<SelfUpdateState>.broadcast();
  SelfUpdateState _state = const SelfUpdateState.idle();

  int applyCount = 0;

  /// Registra o `inBackground` de cada checagem — é o que distingue a checagem
  /// de boot (silenciosa) da pedida pelo usuário (foreground).
  final checks = <bool>[];

  void emit(SelfUpdateState next) {
    _state = next;
    _controller.add(next);
  }

  @override
  SelfUpdateState get state => _state;

  @override
  Stream<SelfUpdateState> get changes => _controller.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> checkForUpdates({bool inBackground = true}) async =>
      checks.add(inBackground);

  @override
  Future<void> applyUpdate() async => applyCount++;

  @override
  void dispose() => _controller.close();
}

class _FakeChecker implements UpdateChecker {
  _FakeChecker(this.latest);
  final UpdateInfo? latest;
  int calls = 0;

  @override
  Future<UpdateInfo?> fetchLatest() async {
    calls++;
    return latest;
  }
}

class _FakeDismissed implements DismissedUpdateStore {
  String? _v;
  @override
  String? dismissedVersion() => _v;
  @override
  Future<void> dismiss(String version) async => _v = version;
}

class _FakeOpener implements UrlOpener {
  final opened = <String>[];
  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return true;
  }
}

const _kWindowsTarget = UpdateTarget(
  version: '1.8.3',
  platform: 'windows',
  format: 'exe',
  arch: 'x64',
  selfUpdateFeedUrl: 'https://example.test/appcast-windows.xml',
);

/// Linux: sem self-update, com canal (notify pelo `latest.json`).
const _kLinuxTarget = UpdateTarget(
  version: '1.8.3',
  platform: 'linux',
  format: 'deb',
  arch: 'x64',
);

/// macOS: sem canal nenhum — o fork não publica build de macOS.
const _kMacTarget = UpdateTarget(
  version: '1.8.3',
  platform: 'macos',
  format: 'dmg',
  arch: 'universal',
  hasUpdateChannel: false,
);

UpdateInfo _info(String version) =>
    UpdateInfo(version: version, date: '', notes: '', artifacts: const []);

void main() {
  group('UpdateViewModel — self-update no Windows (fase available)', () {
    late _FakeSelfUpdater updater;
    late _FakeChecker checker;
    late UpdateViewModel vm;

    setUp(() {
      updater = _FakeSelfUpdater();
      checker = _FakeChecker(_info('1.8.4'));
      vm = UpdateViewModel(
        checker,
        _FakeDismissed(),
        _FakeOpener(),
        _kWindowsTarget,
        updater,
      );
    });
    tearDown(() {
      vm.dispose();
      updater.dispose();
    });

    test('available → card aparece com "click to install"', () async {
      await vm.check();
      updater.emit(
        const SelfUpdateState(SelfUpdatePhase.available, version: '1.8.4'),
      );

      expect(vm.hasUpdate, isTrue);
      expect(vm.cardTitle, 'Update available');
      expect(vm.cardSubtitle, 'v1.8.4 — click to install');
      // Nada foi baixado: não pode prometer "restart to install".
      expect(vm.isReadyToInstall, isFalse);
    });

    test('toque aciona o updater (era no-op antes do fix)', () async {
      await vm.check();
      updater.emit(const SelfUpdateState(SelfUpdatePhase.available));

      await vm.primaryAction();

      expect(updater.applyCount, 1);
    });

    test(
      'versão desconhecida (AppcastItem null) → completa pelo latest.json',
      () async {
        await vm.check();
        // Como o plugin Windows manda o evento sem versão.
        updater.emit(const SelfUpdateState(SelfUpdatePhase.available));

        // Sem fallback o card diria "v — click to install".
        await pumpEventQueue();

        expect(vm.updateVersion, '1.8.4');
        expect(vm.cardSubtitle, 'v1.8.4 — click to install');
      },
    );

    test(
      'não busca o latest.json quando o motor já informa a versão',
      () async {
        await vm.check();
        updater.emit(
          const SelfUpdateState(SelfUpdatePhase.available, version: '1.8.4'),
        );
        await pumpEventQueue();

        expect(checker.calls, 0);
      },
    );

    test('idle → sem card', () async {
      await vm.check();
      updater.emit(const SelfUpdateState.idle());

      expect(vm.hasUpdate, isFalse);
    });

    test('check() de boot é silenciosa (inBackground: true)', () async {
      await vm.check();
      expect(updater.checks, [true]);
    });

    test(
      'checkNow() do menu é foreground → ignora "Skip this version"',
      () async {
        await vm.checkNow();
        expect(updater.checks, [false]);
      },
    );

    test('checkNow() traz de volta um card dispensado na sessão', () async {
      await vm.check();
      updater.emit(const SelfUpdateState(SelfUpdatePhase.available));
      await vm.dismiss();
      expect(vm.hasUpdate, isFalse);

      await vm.checkNow();

      expect(vm.hasUpdate, isTrue);
    });

    test('dismiss esconde o card na sessão', () async {
      await vm.check();
      updater.emit(const SelfUpdateState(SelfUpdatePhase.available));

      await vm.dismiss();

      expect(vm.hasUpdate, isFalse);
    });
  });

  group('UpdateViewModel — macOS não tem canal de release', () {
    late _FakeSelfUpdater updater;
    late _FakeChecker checker;
    late _FakeOpener opener;
    late UpdateViewModel vm;

    setUp(() {
      updater = _FakeSelfUpdater();
      checker = _FakeChecker(_info('1.8.4')); // haveria update, se houvesse canal
      opener = _FakeOpener();
      vm = UpdateViewModel(
        checker,
        _FakeDismissed(),
        opener,
        _kMacTarget,
        updater,
      );
    });
    tearDown(() {
      vm.dispose();
      updater.dispose();
    });

    test('check() não toca no motor nem no manifest', () async {
      await vm.check();

      expect(updater.checks, isEmpty);
      expect(checker.calls, 0);
      expect(vm.hasUpdate, isFalse);
    });

    test('checkNow() do menu também é no-op', () async {
      await vm.checkNow();

      expect(updater.checks, isEmpty);
      expect(checker.calls, 0);
      expect(vm.hasUpdate, isFalse);
    });

    test('card não aparece nem se o motor emitir update disponível', () async {
      await vm.check();
      updater.emit(
        const SelfUpdateState(SelfUpdatePhase.available, version: '1.8.4'),
      );

      expect(vm.hasUpdate, isFalse);
    });

    test('primaryAction não abre URL nem aciona o motor', () async {
      await vm.check();
      await vm.primaryAction();

      expect(opener.opened, isEmpty);
      expect(updater.applyCount, 0);
    });
  });

  group('UpdateViewModel — Linux mantém o canal de notify', () {
    test('check() lê o manifest e mostra o card', () async {
      final checker = _FakeChecker(_info('1.8.4'));
      final vm = UpdateViewModel(
        checker,
        _FakeDismissed(),
        _FakeOpener(),
        _kLinuxTarget,
        const NoopSelfUpdater(),
      );
      addTearDown(vm.dispose);

      await vm.check();

      expect(checker.calls, 1);
      expect(vm.hasUpdate, isTrue);
      expect(vm.cardSubtitle, 'v1.8.4 — click to download');
    });
  });

  group('UpdateViewModel — fases de auto-download do motor', () {
    late _FakeSelfUpdater updater;
    late UpdateViewModel vm;

    setUp(() {
      updater = _FakeSelfUpdater();
      vm = UpdateViewModel(
        _FakeChecker(null),
        _FakeDismissed(),
        _FakeOpener(),
        _kWindowsTarget,
        updater,
      );
    });
    tearDown(() {
      vm.dispose();
      updater.dispose();
    });

    test('downloading → mostra progresso, sem ação', () async {
      await vm.check();
      updater.emit(
        const SelfUpdateState(SelfUpdatePhase.downloading, version: '1.8.4'),
      );

      expect(vm.cardSubtitle, 'Downloading v1.8.4…');
      expect(vm.isReadyToInstall, isFalse);
    });

    test('downloaded → "restart to install"', () async {
      await vm.check();
      updater.emit(
        const SelfUpdateState(SelfUpdatePhase.downloaded, version: '1.8.4'),
      );

      expect(vm.cardTitle, 'Update ready');
      expect(vm.cardSubtitle, 'v1.8.4 — restart to install');
      expect(vm.isReadyToInstall, isTrue);
    });
  });
}
