import 'package:app/data/preferences/preferences.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/settings/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class _FakeSecureStorage implements FlutterSecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _store[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _store.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation i) => super.noSuchMethod(i);
}

Widget _wrap(Preferences prefs) {
  return ChangeNotifierProvider<Preferences>.value(
    value: prefs,
    child: MaterialApp(
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.dark,
      home: const Scaffold(body: FontScalePicker()),
    ),
  );
}

SegmentedButton<UiFontScale> _button(WidgetTester tester) {
  return tester.widget<SegmentedButton<UiFontScale>>(
    find.byType(SegmentedButton<UiFontScale>),
  );
}

void main() {
  testWidgets('renders the four plan-131 presets with Default selected',
      (tester) async {
    final prefs = Preferences(_FakeSecureStorage());
    await tester.pumpWidget(_wrap(prefs));

    expect(find.text('Font size'), findsOneWidget);
    for (final label in ['Small', 'Default', 'Large', 'XL']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(_button(tester).selected, {UiFontScale.normal});
  });

  testWidgets('tapping a preset persists it to Preferences', (tester) async {
    final store = _FakeSecureStorage();
    final prefs = Preferences(store);
    await tester.pumpWidget(_wrap(prefs));

    await tester.tap(find.text('Large'));
    await tester.pumpAndSettle();

    expect(prefs.uiFontScale, UiFontScale.large);
    expect(_button(tester).selected, {UiFontScale.large});
    expect(await store.read(key: 'prefs.ui_font_scale'), 'large');
  });

  testWidgets('reflects a hydrated preference (cold start with preset)',
      (tester) async {
    final store = _FakeSecureStorage();
    await store.write(key: 'prefs.ui_font_scale', value: 'extraLarge');
    final prefs = Preferences(store);
    await prefs.load();
    await tester.pumpWidget(_wrap(prefs));

    expect(_button(tester).selected, {UiFontScale.extraLarge});
  });
}
