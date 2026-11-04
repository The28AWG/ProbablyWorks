import 'package:flutter/foundation.dart';
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

  Future<void> pump(
    WidgetTester tester, {
    bool busy = false,
    int maxLines = 8,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: ComposerInput(
            controller: controller,
            hint: 'Message',
            busy: busy,
            loading: false,
            maxLines: maxLines,
            onSubmit: submits.add,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pump();
  }

  /// Как в ChatBody: композер исключён из фокуса, пока чат загружается.
  Future<void> pumpExcluded(WidgetTester tester, {required bool loading}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: Scaffold(
            body: ExcludeFocus(
              excluding: loading,
              child: ComposerInput(
                controller: controller,
                hint: 'Message',
                busy: false,
                loading: loading,
                maxLines: 8,
                onSubmit: submits.add,
              ),
            ),
          ),
        ),
      );

  bool hasFocus(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus;

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

  testWidgets('field grows up to maxLines and then scrolls', (tester) async {
    await pump(tester, maxLines: 5);
    expect(tester.widget<TextField>(find.byType(TextField)).maxLines, 5);
  });

  testWidgets('hint is a single line that is cut with an ellipsis', (
    tester,
  ) async {
    await pump(tester);
    final decoration = tester
        .widget<TextField>(find.byType(TextField))
        .decoration;
    expect(decoration?.hintMaxLines, 1);
  });

  _platformTest(
    'takes focus on appear when the chat is already loaded',
    TargetPlatform.linux,
    (tester) async {
      await pumpExcluded(tester, loading: false);
      await tester.pump();
      expect(hasFocus(tester), isTrue);
    },
  );

  _platformTest(
    'takes focus once the chat finishes loading',
    TargetPlatform.linux,
    (tester) async {
      // Новый экземпляр на открытии из списка: поле создаётся, пока чат ещё грузится.
      await pumpExcluded(tester, loading: true);
      await tester.pump();
      expect(hasFocus(tester), isFalse);

      await pumpExcluded(tester, loading: false);
      await tester.pump();
      expect(hasFocus(tester), isTrue);
    },
  );

  _platformTest(
    'does not take focus on open on mobile (no keyboard)',
    TargetPlatform.android,
    (tester) async {
      await pumpExcluded(tester, loading: false);
      await tester.pump();
      expect(hasFocus(tester), isFalse);

      await pumpExcluded(tester, loading: true);
      await pumpExcluded(tester, loading: false);
      await tester.pump();
      expect(hasFocus(tester), isFalse);
    },
  );

  _platformTest(
    'a tap still focuses the field on mobile',
    TargetPlatform.android,
    (tester) async {
      await pumpExcluded(tester, loading: false);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(hasFocus(tester), isTrue);
    },
  );
}

/// `testWidgets` с заданной платформой. Flutter в тестах по умолчанию считается Android, поэтому
/// тесты фокуса на десктопе задают платформу явно. Override сбрасывается внутри тела, потому что
/// flutter_test проверяет переменные фонда до `tearDown`.
void _platformTest(
  String description,
  TargetPlatform platform,
  WidgetTesterCallback body,
) {
  // Проверки лежат в body, которое передаёт вызывающий тест; DCM не видит их через обёртку.
  // ignore: missing-test-assertion
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
