import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_step_ledger.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:xterm/xterm.dart';

class _TestApp extends StatelessWidget {
  const _TestApp(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

ToolRun _run(String id, ToolRunStatus status, {String? output}) {
  final start = DateTime(2026, 1, 1, 12);
  return ToolRun(
    id: id,
    chatId: 'c',
    messageId: 'a1',
    toolName: 'run_command',
    argsJson: '{}',
    command: 'flutter test',
    status: status,
    startedAt: start,
    finishedAt: status == ToolRunStatus.running
        ? null
        : start.add(const Duration(seconds: 3)),
    outputText: output,
  );
}

void main() {
  testWidgets('command card fills the full width of the ledger', (
    tester,
  ) async {
    // Короткий вывод: без растягивания карточка сжалась бы до текста.
    await tester.pumpWidget(
      _TestApp(
        SizedBox(
          width: 600,
          child: ChatStepLedger(
            steps: [RunStep(_run('r1', ToolRunStatus.running))],
            live: const {'r1': 'ok'},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('flutter test'));
    await tester.pumpAndSettle();

    final ledger = tester.getRect(find.byType(ChatStepLedger));
    final card = tester.getRect(find.byType(CommandOutput));
    expect(card.right, closeTo(ledger.right, 0.5));
    expect(card.width, greaterThan(400));
  });
  testWidgets('live output of a running command streams into the terminal', (
    tester,
  ) async {
    Widget ledger(String live) => _TestApp(
      SizedBox(
        width: 600,
        child: ChatStepLedger(
          steps: [RunStep(_run('r1', ToolRunStatus.running))],
          live: {'r1': live},
        ),
      ),
    );
    await tester.pumpWidget(ledger('step 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('flutter test'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(ledger('step 1\nstep 2'));
    await tester.pumpAndSettle();

    final terminal = tester
        .widget<TerminalView>(find.byType(TerminalView))
        .terminal;
    expect(
      terminal.buffer
          .getText()
          .trimRight()
          .split('\n')
          .map((l) => l.trimRight()),
      ['\$ flutter test', 'step 1', 'step 2'],
    );
  });

  testWidgets('a thought shows its first line and expands to the full text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestApp(
        const SizedBox(
          width: 600,
          child: ChatStepLedger(
            steps: [
              ThoughtStep(id: 't1', text: 'Первая строка\nВторая строка'),
            ],
            live: {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Первая строка'), findsOneWidget);
    expect(find.textContaining('Вторая строка'), findsNothing);

    await tester.tap(find.text('Первая строка'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Вторая строка'), findsOneWidget);
  });

  testWidgets('thoughts and commands of one response share one group', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestApp(
        SizedBox(
          width: 600,
          child: ChatStepLedger(
            steps: [
              const ThoughtStep(id: 't1', text: 'Сначала посмотрю файлы'),
              RunStep(_run('r1', ToolRunStatus.done)),
              const ThoughtStep(id: 't2', text: 'Теперь проверю результат'),
            ],
            live: const {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('3 steps'), findsOneWidget);
    expect(find.text('Сначала посмотрю файлы'), findsNothing);
  });

  testWidgets('a streaming thought starts collapsed and counts as running', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestApp(
        SizedBox(
          width: 600,
          child: ChatStepLedger(
            steps: [
              RunStep(_run('r1', ToolRunStatus.done)),
              const ThoughtStep(id: 'live', text: 'Ищу конфиг', live: true),
            ],
            live: const {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Running: 1 of 2'), findsOneWidget);
    expect(find.text('Ищу конфиг'), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
  });

  testWidgets('a running command starts collapsed', (tester) async {
    await tester.pumpWidget(
      _TestApp(
        SizedBox(
          width: 600,
          child: ChatStepLedger(
            steps: [RunStep(_run('r1', ToolRunStatus.running))],
            live: const {'r1': 'step 1'},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('flutter test'), findsOneWidget);
    expect(find.byType(CommandOutput), findsNothing);
  });

  group('thought row identity', () {
    Widget journal(List<LedgerStep> steps) => _TestApp(
      SizedBox(
        width: 600,
        child: ChatStepLedger(steps: steps, live: const {}),
      ),
    );

    testWidgets('a live thought keeps its row when a command starts after it', (
      tester,
    ) async {
      await tester.pumpWidget(
        journal([const ThoughtStep(id: 't1', text: 'Ищу конфиг', live: true)]),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ищу конфиг'));
      await tester.pumpAndSettle();
      final before = tester.element(find.byType(SelectableText));

      await tester.pumpWidget(
        journal([
          const ThoughtStep(id: 't1', text: 'Ищу конфиг', live: true),
          RunStep(_run('r1', ToolRunStatus.running)),
        ]),
      );
      await tester.pump();

      expect(find.byType(SelectableText), findsOneWidget);
      expect(tester.element(find.byType(SelectableText)), same(before));
    });

    testWidgets(
      'a saved thought keeps its row when the message replaces the stream',
      (tester) async {
        await tester.pumpWidget(
          journal([
            const ThoughtStep(
              id: 'thought:live',
              text: 'Ищу конфиг',
              live: true,
            ),
          ]),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Ищу конфиг'));
        await tester.pumpAndSettle();
        final before = tester.element(find.byType(SelectableText));

        await tester.pumpWidget(
          journal([
            const ThoughtStep(id: 'thought:m1', text: 'Ищу конфиг'),
            RunStep(_run('r1', ToolRunStatus.running)),
          ]),
        );
        await tester.pump();

        expect(find.byType(SelectableText), findsOneWidget);
        expect(tester.element(find.byType(SelectableText)), same(before));
      },
    );
  });

  group('streaming thought scroll', () {
    String lines(int count) =>
        [for (var i = 0; i < count; i++) 'строка $i'].join('\n');

    Widget ledger(String text) => _TestApp(
      SizedBox(
        width: 600,
        child: ChatStepLedger(
          steps: [ThoughtStep(id: 'live', text: text, live: true)],
          live: const {},
        ),
      ),
    );

    // Прокрутка самого блока рассуждения: ближайший Scrollable над текстом, а не список журнала.
    final thoughtScroll = find
        .ancestor(
          of: find.byType(SelectableText),
          matching: find.byType(Scrollable),
        )
        .first;

    ScrollPosition position(WidgetTester tester) =>
        tester.state<ScrollableState>(thoughtScroll).position;

    testWidgets('new text does not pull a reader who scrolled up', (
      tester,
    ) async {
      final scroll = thoughtScroll;
      await tester.pumpWidget(ledger(lines(40)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('строка 0'));
      await tester.pumpAndSettle();
      await tester.drag(scroll, const Offset(0, -2000));
      await tester.pumpAndSettle();
      await tester.drag(scroll, const Offset(0, 200));
      await tester.pumpAndSettle();
      final readingAt = position(tester).pixels;
      expect(position(tester).extentAfter, greaterThan(24));

      await tester.pumpWidget(ledger(lines(41)));
      await tester.pumpAndSettle();

      expect(position(tester).pixels, closeTo(readingAt, 1));
    });

    testWidgets('a reader at the end keeps following new text', (tester) async {
      final scroll = thoughtScroll;
      await tester.pumpWidget(ledger(lines(40)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('строка 0'));
      await tester.pumpAndSettle();
      await tester.drag(scroll, const Offset(0, -2000));
      await tester.pumpAndSettle();

      await tester.pumpWidget(ledger(lines(41)));
      await tester.pumpAndSettle();

      expect(position(tester).pixels, greaterThan(0));
      expect(position(tester).extentAfter, lessThan(1));
    });
  });
}
