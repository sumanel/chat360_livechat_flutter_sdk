import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:example/main.dart';

void main() {
  testWidgets('shows the login form', (WidgetTester tester) async {
    await tester.pumpWidget(const DemoApp());

    expect(find.text('Log in'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(3));
  });
}
