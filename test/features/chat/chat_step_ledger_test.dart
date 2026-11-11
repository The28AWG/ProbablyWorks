import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
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

ToolRun _fileRun({
  required String tool,
  required String args,
  String? command,
  String? output,
  String id = 'file',
  ToolRunStatus status = ToolRunStatus.done,
}) {
  final start = DateTime(2026, 1, 1, 12);
  return ToolRun(
    id: id,
    chatId: 'c',
    messageId: 'a1',
    toolName: tool,
    argsJson: args,
    command: command,
    status: status,
    startedAt: start,
    finishedAt: start.add(const Duration(seconds: 1)),
    outputText: output,
  );
}

/// Зазор от правого края [left] до подписи на той же строке. Несколько длительностей
/// не мешают: берётся та, что стоит напротив счётчика.
double _gap(WidgetTester tester, String left, String right) {
  final leftBox = tester.getRect(find.text(left));
  final matches = find.text(right);
  final count = tester.widgetList(matches).length;
  var gap = double.negativeInfinity;
  for (var index = 0; index < count; index++) {
    final box = tester.getRect(matches.at(index));
    if ((box.center.dy - leftBox.center.dy).abs() > 4) continue;
    gap = box.left - leftBox.right;
  }
  return gap;
}

void main() {
  testWidgets('delegate card offers opening the subagent chat', (tester) async {
    final run = ToolRun(
      id: 'd1',
      chatId: 'c',
      messageId: 'a1',
      toolName: ToolNames.delegateTask,
      argsJson: '{"task":"child"}',
      command: 'delegate: child',
      status: ToolRunStatus.done,
      startedAt: DateTime(2026, 1, 1, 12),
      finishedAt: DateTime(2026, 1, 1, 12, 1),
      outputText: 'subagent started: 550e8400-e29b-41d4-a716-446655440000',
    );
    await tester.pumpWidget(
      _TestApp(
        SizedBox(
          width: 600,
          child: ChatStepLedger(steps: [RunStep(run)], live: const {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('delegate: child'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('open-subagent')), findsOneWidget);
    expect(find.byKey(const ValueKey('step-copy')), findsNothing);
  });

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

  testWidgets('write_file opens as a new file, not an empty command', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestApp(
        SizedBox(
          width: 640,
          child: ChatStepLedger(
            steps: [
              RunStep(
                _fileRun(
                  tool: 'write_file',
                  args: '{"path":"lib/a.dart","content":"alpha\\nbeta"}',
                  command: 'write /work/lib/a.dart',
                ),
              ),
            ],
            live: const {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('write /work/lib/a.dart'), findsOneWidget);
    expect(find.text('New file'), findsNothing);
    expect(find.text('+2'), findsOneWidget);
    expect(find.byType(FileChangeView), findsNothing);

    await tester.tap(find.text('write /work/lib/a.dart'));
    await tester.pumpAndSettle();

    expect(find.byType(FileChangeView), findsOneWidget);
    expect(find.byType(CommandOutput), findsNothing);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('@@ -0,0 +1,2 @@'), findsOneWidget);
    expect(find.text('-'), findsNothing);
  });

  testWidgets('edit_file opens as a diff and not as a new file', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestApp(
        SizedBox(
          width: 640,
          child: ChatStepLedger(
            steps: [
              RunStep(
                _fileRun(
                  tool: 'edit_file',
                  args: '{"path":"lib/a.dart","old_string":"alpha\\nbeta","new_string":"alpha\\ngamma"}',
                  command: 'write /work/lib/a.dart',
                ),
              ),
            ],
            live: const {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('edit /work/lib/a.dart'), findsOneWidget);
    expect(find.text('write /work/lib/a.dart'), findsNothing);
    expect(find.text('New file'), findsNothing);
    expect(find.text('+1'), findsOneWidget);
    expect(find.text('-1'), findsOneWidget);
    expect(find.byType(FileChangeView), findsNothing);

    await tester.tap(find.text('edit /work/lib/a.dart'));
    await tester.pumpAndSettle();

    expect(find.byType(CommandOutput), findsNothing);
    expect(find.text('@@ -1,2 +1,2 @@'), findsOneWidget);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('gamma'), findsOneWidget);
  });

  testWidgets('apply_patch opens as a diff with a patch verb', (tester) async {
    const patch = '''
@@ -1,2 +1,3 @@
 alpha
-beta
+gamma
+delta''';
    await tester.pumpWidget(
      _TestApp(
        SizedBox(
          width: 640,
          child: ChatStepLedger(
            workspace: '/work',
            steps: [
              RunStep(
                _fileRun(
                  tool: 'apply_patch',
                  args: '{"path":"lib/a.dart","patch":${jsonEncode(patch)}}',
                  command: 'write /work/lib/a.dart',
                ),
              ),
            ],
            live: const {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('patch a.dart'), findsOneWidget);
    expect(find.text('edit a.dart'), findsNothing);
    expect(find.byType(FileChangeView), findsNothing);

    await tester.tap(find.text('patch a.dart'));
    await tester.pumpAndSettle();

    expect(find.byType(FileChangeView), findsOneWidget);
    expect(find.byType(CommandOutput), findsNothing);
    expect(find.text('@@ -1,2 +1,3 @@'), findsOneWidget);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('beta'), findsOneWidget);
    expect(find.text('gamma'), findsOneWidget);
    expect(find.text('delta'), findsOneWidget);
  });

  testWidgets('path and run tools keep the same compact journal style', (
    tester,
  ) async {
    Future<void> check(
      String tool,
      String command,
      String title, {
      String output = '',
    }) async {
      await tester.pumpWidget(
        _TestApp(
          SizedBox(
            width: 640,
            child: ChatStepLedger(
              workspace: '/work',
              steps: [
                RunStep(
                  _fileRun(
                    tool: tool,
                    args: '{}',
                    command: command,
                    output: output,
                  ),
                ),
              ],
              live: const {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(title), findsOneWidget);
      expect(find.byType(FileChangeView), findsNothing);
    }

    await check('delete_file', 'delete /work/a.txt', 'delete a.txt');
    await check(
      'move_path',
      'move /work/a.txt -> /work/b.txt',
      'move a.txt → b.txt',
    );
    await check(
      'copy_path',
      'copy /work/a.txt -> /work/b.txt',
      'copy a.txt → b.txt',
    );
    await check('make_dir', 'mkdir /work/new', 'mkdir new');
    await check(
      'stat_path',
      'stat /work/a.txt',
      'stat a.txt',
      output: 'file 1700000000\n',
    );
    await check(
      'glob',
      'glob *.dart /work',
      'glob *.dart /work',
      output: '/work/a.dart\n',
    );
    await check('list_runs', 'list runs', 'list runs', output: 'run | done\n');
    await check(
      'read_run_output',
      'read run seed',
      'read run seed',
      output: 'output\n',
    );
    await check('stop_run', 'stop run seed', 'stop run seed');
  });

  testWidgets(
    'файл проекта подписан именем, счётчик не слипается со временем',
    (tester) async {
      final steps = [
        RunStep(
          _fileRun(
            tool: 'write_file',
            args: '{"path":"lib/a.dart","content":"alpha\\nbeta"}',
            command: 'write /work/lib/a.dart',
          ),
        ),
        RunStep(
          ToolRun(
            id: 'read',
            chatId: 'c',
            messageId: 'a1',
            toolName: 'read_file',
            argsJson: '{}',
            command: 'read /work/test_write.txt',
            status: ToolRunStatus.done,
            startedAt: DateTime(2026, 1, 1, 12),
            finishedAt: DateTime(2026, 1, 1, 12, 0, 1),
            outputText: '[file: 1 lines, 1 bytes]\n1: a\n[end of file]\n',
          ),
        ),
        RunStep(
          _fileRun(
            tool: 'write_file',
            args: '{"path":"/etc/hosts","content":"x"}',
            command: 'write /etc/hosts',
            id: 'outside',
          ),
        ),
      ];
      await tester.pumpWidget(
        _TestApp(
          SizedBox(
            width: 640,
            child: ChatStepLedger(
              workspace: '/work',
              steps: steps,
              live: const {},
              expandTools: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('write a.dart'), findsOneWidget);
      expect(find.text('read test_write.txt'), findsOneWidget);
      expect(find.text('write /etc/hosts'), findsOneWidget);

      // Раскрытая узкая карточка: свободное место в шапке кончается, зазор остаётся.
      await tester.pumpWidget(
        _TestApp(
          SizedBox(
            width: 220,
            child: ChatStepLedger(
              workspace: '/work',
              steps: steps,
              live: const {},
              expandTools: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_gap(tester, '+2', '1 s'), greaterThanOrEqualTo(AppSpacing.sm));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a failed write still shows the new file and the host error', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestApp(
        SizedBox(
          width: 640,
          child: ChatStepLedger(
            steps: [
              RunStep(
                _fileRun(
                  tool: 'write_file',
                  args: '{"content":"alpha"}',
                  command: 'write /work/a.txt',
                  status: ToolRunStatus.failed,
                  output: 'file changed after it was read; nothing was written',
                ),
              ),
            ],
            live: const {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('write /work/a.txt'));
    await tester.pumpAndSettle();

    expect(find.text('alpha'), findsOneWidget);
    expect(
      find.text('file changed after it was read; nothing was written'),
      findsOneWidget,
    );
  });

  testWidgets('шапка не переполняется на узкой карточке', (tester) async {
    const read =
        '[file: 3 lines, 20 bytes]\n1: alpha\n2: beta\n3: gamma\n[end of file]\n';
    const path = 'read /home/the28awg/Development/ProbablyWorks/test_write.txt';
    final start = DateTime(2026, 1, 1, 12);
    final steps = [
      RunStep(
        _fileRun(
          tool: 'write_file',
          args: '{"path":"lib/a.dart","content":"alpha\\nbeta"}',
          command: 'write /home/the28awg/Development/ProbablyWorks/lib/a.dart',
        ),
      ),
      RunStep(
        ToolRun(
          id: 'read',
          chatId: 'c',
          messageId: 'a1',
          toolName: 'read_file',
          argsJson: '{}',
          command: path,
          status: ToolRunStatus.done,
          startedAt: start,
          finishedAt: start.add(const Duration(seconds: 1)),
          outputText: read,
        ),
      ),
      RunStep(
        ToolRun(
          id: 'live',
          chatId: 'c',
          messageId: 'a1',
          toolName: 'run_command',
          argsJson: '{}',
          command: 'flutter test --reporter expanded',
          status: ToolRunStatus.running,
          startedAt: start,
          background: true,
        ),
      ),
    ];

    Future<void> pump(double width) => tester.pumpWidget(
      _TestApp(
        SizedBox(
          width: width,
          child: ChatStepLedger(steps: steps, live: const {'live': 'ok'}),
        ),
      ),
    );

    await pump(170);
    await tester.pump();
    expect(find.text('New file'), findsNothing);
    expect(find.text('+2'), findsOneWidget);
    expect(find.text(path), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text(path));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await pump(120);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
