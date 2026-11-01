import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/features/chat/presentation/widgets/composer_input.dart';

void main() {
  late TextEditingController controller;
  final submits = <bool>[];

  setUp(() {
    controller = TextEditingController(text: 'hello');
    submits.clear();
  });

  tearDown(() => controller.dispose());

  Future<void> pump(WidgetTester tester, {bool busy = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ComposerInput(
            controller: controller,
            hint: 'Message',
            busy: busy,
            onSubmit: submits.add,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
  }

  testWidgets('Enter submits without modifier and keeps text intact', (
    tester,
  ) async {
    await pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(submits, [false]);
    expect(controller.text, 'hello');
  });

  testWidgets('Shift+Enter does not submit', (tester) async {
    await pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(submits, isEmpty);
  });

  testWidgets('Ctrl+Enter while busy requests send-now', (tester) async {
    await pump(tester, busy: true);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(submits, [true]);
  });

  testWidgets('Ctrl+Enter while idle is a plain submit', (tester) async {
    await pump(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(submits, [false]);
  });
}
