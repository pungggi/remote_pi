import 'package:app/data/preferences/preferences.dart' show HomeGroupBy;
import 'package:app/ui/home/widgets/session_grouping.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HomeGroupingControl', () {
    testWidgets('shows the selected mode and reports changes', (tester) async {
      HomeGroupBy? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: HomeGroupingControl(
              value: HomeGroupBy.model,
              onChanged: (value) => changed = value,
            ),
          ),
        ),
      );

      final control = tester.widget<SegmentedButton<HomeGroupBy>>(
        find.byType(SegmentedButton<HomeGroupBy>),
      );
      expect(control.selected, {HomeGroupBy.model});
      expect(find.text('GROUP BY'), findsOneWidget);
      expect(find.text('Model'), findsOneWidget);
      expect(find.text('Repo'), findsOneWidget);

      await tester.tap(find.text('Repo'));
      expect(changed, HomeGroupBy.repository);
    });
  });

  group('SessionGroupHeader', () {
    testWidgets('shows the group label and session count', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SessionGroupHeader(label: 'pungggi/pi-reflex', count: 2),
          ),
        ),
      );

      expect(find.text('pungggi/pi-reflex'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });
  });
}
