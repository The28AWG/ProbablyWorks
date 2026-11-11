import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_timeline.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

ChatMessage _msg(int i) => ChatMessage(
  id: 'm$i',
  chatId: 'c',
  seq: i,
  role: i.isEven ? MessageRole.user : MessageRole.assistant,
  createdAt: DateTime(2026),
  text: i.isEven ? 'Question $i' : 'Answer $i',
);

ChatState _state(Map<String, String> live) => ChatState(
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
  messages: [for (var i = 1; i <= 6; i++) _msg(i)],
  runs: [
    ToolRun(
      id: 'r1',
      chatId: 'c',
      messageId: 'm6',
      toolName: 'run_command',
      argsJson: '{}',
      command: 'make',
      status: ToolRunStatus.running,
      startedAt: DateTime(2026),
    ),
  ],
  live: live,
  isRunning: true,
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
      body: SizedBox(height: 800, child: ChatTimeline(state: state)),
    ),
  );
}

void main() {
  testWidgets(
    'an expanded step keeps its output state when the chat state rebuilds',
    (tester) async {
      await tester.pumpWidget(_TestApp(_state({'r1': 'a'})));
      await tester.pumpAndSettle();
      if (find.byType(CommandOutput).evaluate().isEmpty) {
        await tester.tap(find.text('make'));
        await tester.pumpAndSettle();
      }

      final before = tester.element(find.byType(CommandOutput));
      await tester.pumpWidget(_TestApp(_state({'r1': 'a\nb'})));
      await tester.pumpWidget(_TestApp(_state({'r1': 'a\nb\nc'})));
      await tester.pumpAndSettle();

      expect(
        identical(tester.element(find.byType(CommandOutput)), before),
        isTrue,
      );
    },
  );
}
