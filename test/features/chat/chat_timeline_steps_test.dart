import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_timeline.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

ChatMessage _msg(int i) => ChatMessage(
  id: 'm$i',
  chatId: 'c',
  seq: i,
  role: i.isEven ? MessageRole.assistant : MessageRole.user,
  createdAt: DateTime(2026),
  text: 'Message $i',
);

/// Длинный чат: группа шагов стоит у самого старого сообщения, далеко от низа ленты.
ChatState _state({required List<ToolRun> runs}) => ChatState(
  chatId: 'c',
  chat: Chat(
    id: 'c',
    hostId: 'local',
    title: 'Chat',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  ),
  hosts: [
    Host(
      id: 'local',
      name: 'Local',
      kind: HostKind.local,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    ),
  ],
  messages: [for (var i = 1; i <= 40; i++) _msg(i)],
  runs: runs,
);

ToolRun _run() => ToolRun(
  id: 'r1',
  chatId: 'c',
  messageId: 'm2',
  toolName: 'run_command',
  argsJson: '{}',
  command: 'flutter analyze',
  outputText: 'No issues found!',
  status: ToolRunStatus.done,
  startedAt: DateTime(2026),
  finishedAt: DateTime(2026).add(const Duration(seconds: 3)),
);

class _TestApp extends StatelessWidget {
  const _TestApp(this.state);

  final ChatState state;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SizedBox(height: 500, child: ChatTimeline(state: state)),
    ),
  );
}

ScrollPosition _position(WidgetTester tester) => tester
    .stateList<ScrollableState>(
      find.descendant(
        of: find.byType(ChatTimeline),
        matching: find.byType(Scrollable),
      ),
    )
    .first
    .position;

void main() {
  testWidgets(
    'expanded step group and step output survive scrolling far away and back',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_TestApp(_state(runs: [_run()])));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(tester.element(find.byType(ChatTimeline)));
      final scroll = _position(tester);
      final historyTop = scroll.maxScrollExtent;

      // Старое сообщение с группой шагов: прокручиваем к началу ленты и раскрываем группу и строку.
      scroll.jumpTo(historyTop);
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.stepsGroupDone(1)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('flutter analyze'));
      await tester.pumpAndSettle();
      expect(find.byType(CommandOutput), findsOneWidget);

      // Уводим группу далеко за край ленты: элементы вне кэша прокрутки уничтожаются.
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('flutter analyze'), findsNothing);

      // Возвращаемся: группа и вывод команды остаются раскрытыми.
      scroll.jumpTo(historyTop);
      await tester.pumpAndSettle();
      expect(find.text('flutter analyze'), findsOneWidget);
    },
  );
}
