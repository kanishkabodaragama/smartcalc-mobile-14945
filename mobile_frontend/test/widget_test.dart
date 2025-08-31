import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_frontend/main.dart';

void main() {
  testWidgets('SmartCalc loads main screen and shows basic controls', (tester) async {
    await tester.pumpWidget(const SmartCalcApp());
    await tester.pumpAndSettle();

    // Expect SmartCalc title in display panel
    expect(find.text('SmartCalc'), findsOneWidget);

    // Expect some keypad buttons
    expect(find.text('7'), findsOneWidget);
    expect(find.text('sin'), findsOneWidget);
    expect(find.text('='), findsOneWidget);
  });
}
