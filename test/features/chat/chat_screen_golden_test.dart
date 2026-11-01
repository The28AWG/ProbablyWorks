import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_view.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:probably_works/test_support/golden_fonts.dart';
import 'package:probably_works/test_support/seeded_chat_bloc.dart';

final _host = Host(
  id: 'local',
  name: 'Local',
  kind: HostKind.local,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

final _model = LlmModelInfo(
  id: 'anthropic/claude-sonnet',
  name: 'Claude Sonnet',
  contextLength: 200000,
);

Chat _chat({int compactedUntilSeq = 0, String? summary}) => Chat(
  id: 'c',
  hostId: 'local',
  title: 'Проверка сборки',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
  model: _model.id,
  workspace: '/home/me/projects/probably_works',
  contextLength: 200000,
  compactedUntilSeq: compactedUntilSeq,
  compactionSummary: summary,
);

ChatMessage _message(String id, int seq, MessageRole role, String text) =>
    ChatMessage(
      id: id,
      chatId: 'c',
      seq: seq,
      role: role,
      createdAt: DateTime(2026),
      text: text,
    );

ToolRun _run(
  String id,
  String command,
  ToolRunStatus status, {
  int seconds = 4,
  String? output,
}) {
  final start = DateTime(2026, 1, 1, 12);
  return ToolRun(
    id: id,
    chatId: 'c',
    messageId: 'a2',
    toolName: 'run_command',
    argsJson: '{}',
    command: command,
    status: status,
    startedAt: start,
    finishedAt: start.add(Duration(seconds: seconds)),
    outputText: output,
    exitCode: status == ToolRunStatus.failed ? 1 : 0,
  );
}

ChatState _empty() =>
    ChatState(chatId: 'c', chat: _chat(), hosts: [_host], models: [_model]);

ChatState _conversation() => ChatState(
  chatId: 'c',
  chat: _chat(
    compactedUntilSeq: 2,
    summary: 'Пользователь просил проверить проект. Найдено два неиспользуемых импорта в `chat_view.dart`.',
  ),
  hosts: [_host],
  models: [_model],
  messages: [
    _message(
      'u0',
      1,
      MessageRole.user,
      'Проверь проект и скажи, что нужно поправить',
    ),
    _message(
      'a0',
      2,
      MessageRole.assistant,
      'Нашёл два неиспользуемых импорта.',
    ),
    _message('u1', 3, MessageRole.user, 'Исправь импорты и прогони анализатор'),
    _message('a1', 4, MessageRole.assistant, _assistantText),
    _message('u2', 5, MessageRole.user, 'Теперь запусти тесты чата'),
    _message(
      'a2',
      6,
      MessageRole.assistant,
      'Запускаю тесты. Один из них падает, смотрю вывод.',
    ),
  ],
  runs: [
    _run(
      'r1',
      'flutter analyze',
      ToolRunStatus.done,
      output: 'No issues found!',
    ),
    _run(
      'r2',
      'flutter test test/features/chat',
      ToolRunStatus.done,
      seconds: 38,
    ),
    _run(
      'r3',
      'flutter test test/core',
      ToolRunStatus.failed,
      seconds: 12,
      output: 'Expected: <3>\n  Actual: <2>\nFAILED: test/core/util/short_time_test.dart',
    ),
  ],
  approvals: const [
    ApprovalRequest(
      id: 'ap1',
      chatId: 'c',
      toolName: 'edit_file',
      summary: 'lib/features/chat/presentation/widgets/chat_timeline.dart',
      reason: 'Изменение файла требует подтверждения.',
      diff: '-  final visible = <ChatMessage>[];\n+  final visible = [for (final m in messages) m];',
    ),
  ],
  isRunning: true,
  promptTokens: 96000,
  contextLimit: 200000,
);

const _assistantText = '''
Исправил импорты. Теперь `flutter analyze` чистый:

- убрал `dart:io` из `chat_view.dart`
- переименовал приватный виджет

```dart
final visible = [for (final m in messages) if (m.role != MessageRole.tool) m];
```
''';

Future<void> _pump(
  WidgetTester tester,
  ChatState state,
  Brightness brightness,
) async {
  await tester.binding.setSurfaceSize(const Size(1000, 760));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.light ? AppTheme.light : AppTheme.dark,
      locale: const Locale('ru'),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: BlocProvider<ChatBloc>.value(
          value: SeededChatBloc(state),
          child: const ChatBody(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(GoldenFonts.load);

  for (final brightness in Brightness.values) {
    testWidgets('chat screen: empty chat (${brightness.name})', (tester) async {
      await _pump(tester, _empty(), brightness);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/chat_screen_empty_${brightness.name}.png'),
      );
    });

    testWidgets('chat screen: running with approval (${brightness.name})', (
      tester,
    ) async {
      await _pump(tester, _conversation(), brightness);
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile(
          'goldens/chat_screen_conversation_${brightness.name}.png',
        ),
      );
    });
  }
}
