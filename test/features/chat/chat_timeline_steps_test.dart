import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/domain/steps_display.dart';
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
  testWidgets('expanded step output survives scrolling far away and back', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_TestApp(_state(runs: [_run()])));
    await tester.pumpAndSettle();
    final scroll = _position(tester);
    final historyTop = scroll.maxScrollExtent;

    // Старое сообщение с шагом: прокручиваем к началу ленты и раскрываем строку команды.
    scroll.jumpTo(historyTop);
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
  });

  testWidgets('steps of one response form one group, reasoning is shown', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final state = ChatState(
      chatId: 'c',
      chat: Chat(
        id: 'c',
        hostId: 'local',
        title: 'Chat',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
      messages: [
        ChatMessage(
          id: 'm1',
          chatId: 'c',
          seq: 1,
          role: MessageRole.user,
          createdAt: DateTime(2026),
          text: 'Вопрос',
        ),
        ChatMessage(
          id: 'm2',
          chatId: 'c',
          seq: 2,
          role: MessageRole.assistant,
          createdAt: DateTime(2026),
          reasoning: 'Сначала посмотрю каталог',
          toolCalls: const [
            ToolCallRef(id: 'k1', name: 'run_command', arguments: '{}'),
          ],
        ),
        ChatMessage(
          id: 'm3',
          chatId: 'c',
          seq: 4,
          role: MessageRole.assistant,
          createdAt: DateTime(2026),
          reasoning: 'Проверю результат',
          text: 'Готово',
        ),
      ],
      runs: [_run()],
    );
    await tester.pumpWidget(_TestApp(state));
    await tester.pumpAndSettle();

    // Мысль, команда и мысль перед текстом ответа — одна группа; текст стоит после неё.
    expect(find.text('3 steps'), findsOneWidget);
    expect(find.textContaining('Готово'), findsOneWidget);
  });

  testWidgets(
    'an assistant step with only whitespace text leaves no empty block',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final state = ChatState(
        chatId: 'c',
        chat: Chat(
          id: 'c',
          hostId: 'local',
          title: 'Chat',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
        messages: [
          ChatMessage(
            id: 'm2',
            chatId: 'c',
            seq: 2,
            role: MessageRole.assistant,
            createdAt: DateTime(2026),
            text: '\n\n\n',
            toolCalls: const [
              ToolCallRef(id: 'k1', name: 'run_command', arguments: '{}'),
            ],
          ),
        ],
        runs: [_run()],
      );
      await tester.pumpWidget(_TestApp(state));
      await tester.pumpAndSettle();

      // Пустой ответ не рисует блок с кнопкой «копировать»: остаётся только строка команды.
      expect(find.byIcon(Icons.copy_outlined), findsNothing);
      expect(find.text('flutter analyze'), findsOneWidget);
    },
  );

  /// Один ответ: вопрос, мысль с текстом и команды. Настройки задаются по тесту.
  ChatState response({
    required StepsDisplay display,
    String? streamReasoning,
    List<ToolRun>? runs,
    String reasoning = 'Старая мысль',
  }) => ChatState(
    chatId: 'c',
    chat: Chat(
      id: 'c',
      hostId: 'local',
      title: 'Chat',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    ),
    messages: [
      ChatMessage(
        id: 'm1',
        chatId: 'c',
        seq: 1,
        role: MessageRole.user,
        createdAt: DateTime(2026),
        text: 'Вопрос',
      ),
      ChatMessage(
        id: 'm2',
        chatId: 'c',
        seq: 2,
        role: MessageRole.assistant,
        createdAt: DateTime(2026),
        reasoning: reasoning,
        toolCalls: const [
          ToolCallRef(id: 'k1', name: 'run_command', arguments: '{}'),
        ],
      ),
      ChatMessage(
        id: 'm3',
        chatId: 'c',
        seq: 3,
        role: MessageRole.assistant,
        createdAt: DateTime(2026),
        text: 'Готово',
      ),
    ],
    runs: runs ?? [_run()],
    streamReasoning: streamReasoning ?? '',
    stepsDisplay: display,
  );

  ToolRun runningRun() => ToolRun(
    id: 'r2',
    chatId: 'c',
    messageId: 'm2',
    toolName: 'run_command',
    argsJson: '{}',
    command: 'npm test',
    status: ToolRunStatus.running,
    startedAt: DateTime(2026),
  );

  testWidgets(
    'thoughts "current" hides saved thoughts and keeps the streamed one',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _TestApp(
          response(
            display: const StepsDisplay(thoughts: ThoughtsVisibility.current),
            streamReasoning: 'Новая мысль',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Старая мысль'), findsNothing);
      expect(find.text('Новая мысль'), findsOneWidget);
    },
  );

  testWidgets('tool calls "active" hide finished calls and keep running ones', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _TestApp(
        response(
          display: const StepsDisplay(tools: ToolsVisibility.active),
          runs: [_run(), runningRun()],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('flutter analyze'), findsNothing);
    expect(find.text('npm test'), findsOneWidget);
  });

  testWidgets('"hide" keeps reasoning and command output collapsed', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _TestApp(
        response(
          display: const StepsDisplay(
            thoughts: ThoughtsVisibility.all,
            tools: ToolsVisibility.all,
          ),
          reasoning: 'Старая мысль\nДетали рассуждения',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 steps'), findsOneWidget);
    expect(find.textContaining('Детали рассуждения'), findsNothing);
    expect(find.byType(CommandOutput), findsNothing);
  });

  testWidgets('thoughts "expanded" open the journal and the full reasoning', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _TestApp(
        response(
          display: const StepsDisplay(thoughts: ThoughtsVisibility.expanded),
          reasoning: 'Старая мысль\nДетали рассуждения',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Детали рассуждения'), findsOneWidget);
    // Вызовы инструментов остаются в своём режиме: вывод команды свёрнут.
    expect(find.byType(CommandOutput), findsNothing);
  });

  testWidgets('tools "expanded" open the journal and the command output', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _TestApp(
        response(
          display: const StepsDisplay(tools: ToolsVisibility.expanded),
          reasoning: 'Старая мысль\nДетали рассуждения',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CommandOutput), findsOneWidget);
    expect(find.textContaining('Детали рассуждения'), findsNothing);
  });

  testWidgets('ungrouped steps are separate rows without a group title', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _TestApp(response(display: const StepsDisplay(group: false))),
    );
    await tester.pumpAndSettle();

    expect(find.text('2 steps'), findsNothing);
    expect(find.text('Старая мысль'), findsOneWidget);
    expect(find.text('flutter analyze'), findsOneWidget);
  });

  testWidgets('steps of one response are grouped by default', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_TestApp(response(display: StepsDisplay.defaults)));
    await tester.pumpAndSettle();

    expect(find.text('2 steps'), findsOneWidget);
  });
}
