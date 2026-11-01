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
            runs: [_run('r1', ToolRunStatus.running)],
            live: const {'r1': 'ok'},
          ),
        ),
      ),
    );
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
          runs: [_run('r1', ToolRunStatus.running)],
          live: {'r1': live},
        ),
      ),
    );
    await tester.pumpWidget(ledger('step 1'));
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
}
