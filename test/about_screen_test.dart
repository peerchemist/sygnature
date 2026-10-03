import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sygnature_ng/ui/about_screen.dart';

void main() {
  testWidgets('shows app summary and opens licenses', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AboutScreen()));

    expect(find.text('About'), findsOneWidget);
    expect(find.textContaining('Peercoin light wallet'), findsOneWidget);
    expect(find.text('Licenses'), findsOneWidget);

    await tester.tap(find.byKey(const Key('licenses-button')));
    await tester.pumpAndSettle();

    expect(find.text('Licenses'), findsOneWidget);
    expect(find.text('Sygnature'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
