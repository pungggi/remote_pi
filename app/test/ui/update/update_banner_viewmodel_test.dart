import 'package:app/domain/contracts/dismissed_update_store.dart';
import 'package:app/domain/contracts/update_checker.dart';
import 'package:app/domain/contracts/url_opener.dart';
import 'package:app/domain/entities/update_info.dart';
import 'package:app/ui/update/states/update_banner_state.dart';
import 'package:app/ui/update/viewmodels/update_banner_viewmodel.dart';
import 'package:flutter_test/flutter_test.dart';

// ── Hand-written fakes (no mocktail in this repo) ──────────────────────────

class _FakeChecker implements UpdateChecker {
  _FakeChecker(this.result);
  UpdateInfo? result;
  int calls = 0;
  @override
  Future<UpdateInfo?> fetchLatest() async {
    calls++;
    return result;
  }
}

class _FakeDismissedStore implements DismissedUpdateStore {
  _FakeDismissedStore([this._version]);
  String? _version;
  final List<String> dismissedCalls = [];
  @override
  Future<String?> dismissedVersion() async => _version;
  @override
  Future<void> dismiss(String version) async {
    dismissedCalls.add(version);
    _version = version;
  }
}

class _FakeOpener implements UrlOpener {
  final List<String> opened = [];
  bool result = true;
  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return result;
  }
}

UpdateInfo _info(
  String version, {
  List<UpdateArtifact>? artifacts,
}) =>
    UpdateInfo(
      version: version,
      date: '2026-06-12',
      notes: '',
      artifacts: artifacts ??
          const [
            UpdateArtifact(
              platform: 'android',
              arch: 'universal',
              format: 'apk',
              url: 'https://example.com/RemotePi.apk',
              sha256: '',
              size: 0,
            ),
          ],
    );

UpdateBannerViewModel _vm(
  _FakeChecker checker, {
  bool enabled = true,
  String current = '1.1.0',
  _FakeDismissedStore? store,
  _FakeOpener? opener,
}) =>
    UpdateBannerViewModel(
      checker,
      store ?? _FakeDismissedStore(),
      opener ?? _FakeOpener(),
      currentVersion: current,
      enabled: enabled,
    );

void main() {
  group('UpdateBannerViewModel.check — gating', () {
    test('newer + not dismissed → Visible', () async {
      final vm = _vm(_FakeChecker(_info('1.2.0')));
      await vm.check();
      expect(vm.state, isA<UpdateBannerVisible>());
      expect((vm.state as UpdateBannerVisible).info.version, '1.2.0');
    });

    test('disabled (iOS) → never fetches, stays Hidden', () async {
      final checker = _FakeChecker(_info('9.9.9'));
      final vm = _vm(checker, enabled: false);
      await vm.check();
      expect(vm.state, isA<UpdateBannerHidden>());
      expect(checker.calls, 0, reason: 'iOS gate short-circuits before fetch');
    });

    test('manifest unavailable (null) → Hidden', () async {
      final vm = _vm(_FakeChecker(null));
      await vm.check();
      expect(vm.state, isA<UpdateBannerHidden>());
    });

    test('equal version → Hidden', () async {
      final vm = _vm(_FakeChecker(_info('1.1.0')), current: '1.1.0');
      await vm.check();
      expect(vm.state, isA<UpdateBannerHidden>());
    });

    test('lower version → Hidden', () async {
      final vm = _vm(_FakeChecker(_info('1.0.0')), current: '1.1.0');
      await vm.check();
      expect(vm.state, isA<UpdateBannerHidden>());
    });

    test('already dismissed this version → Hidden', () async {
      final vm = _vm(
        _FakeChecker(_info('1.2.0')),
        store: _FakeDismissedStore('1.2.0'),
      );
      await vm.check();
      expect(vm.state, isA<UpdateBannerHidden>());
    });

    test('dismissed an OLDER version → still Visible for the newer one', () async {
      final vm = _vm(
        _FakeChecker(_info('1.3.0')),
        store: _FakeDismissedStore('1.2.0'),
      );
      await vm.check();
      expect(vm.state, isA<UpdateBannerVisible>());
    });

    test('check is idempotent per instance (single fetch)', () async {
      final checker = _FakeChecker(_info('1.2.0'));
      final vm = _vm(checker);
      await vm.check();
      await vm.check();
      expect(checker.calls, 1);
    });
  });

  group('UpdateBannerViewModel.dismiss', () {
    test('hides the card and persists the version', () async {
      final store = _FakeDismissedStore();
      final vm = _vm(_FakeChecker(_info('1.2.0')), store: store);
      await vm.check();
      expect(vm.state, isA<UpdateBannerVisible>());

      await vm.dismiss();
      expect(vm.state, isA<UpdateBannerHidden>());
      expect(store.dismissedCalls, ['1.2.0']);
    });

    test('no-op when nothing is visible', () async {
      final store = _FakeDismissedStore();
      final vm = _vm(_FakeChecker(null), store: store);
      await vm.check();
      await vm.dismiss();
      expect(store.dismissedCalls, isEmpty);
    });
  });

  group('UpdateBannerViewModel.download', () {
    test('opens the android/apk artifact url', () async {
      final opener = _FakeOpener();
      final vm = _vm(_FakeChecker(_info('1.2.0')), opener: opener);
      await vm.check();
      await vm.download();
      expect(opener.opened, ['https://example.com/RemotePi.apk']);
    });

    test('falls back to the download page when no apk artifact', () async {
      final opener = _FakeOpener();
      final info = _info(
        '1.2.0',
        artifacts: const [
          UpdateArtifact(
            platform: 'macos',
            arch: 'universal',
            format: 'dmg',
            url: 'https://example.com/RemotePi.dmg',
            sha256: '',
            size: 0,
          ),
        ],
      );
      final vm = _vm(_FakeChecker(info), opener: opener);
      await vm.check();
      await vm.download();
      expect(opener.opened, ['https://github.com/pungggi/remote_pi/releases']);
    });
  });
}
