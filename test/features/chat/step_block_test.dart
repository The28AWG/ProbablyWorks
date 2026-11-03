import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/domain/steps_display.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_step_ledger.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_timeline.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

ChatState _command({String output = 'No issues found!'}) => ChatState(
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
  runs: [
    ToolRun(
      id: 'r1',
      chatId: 'c',
      messageId: 'm2',
      toolName: 'run_command',
      argsJson: '{}',
      command: 'flutter analyze',
      outputText: output,
      status: ToolRunStatus.done,
      startedAt: DateTime(2026),
      finishedAt: DateTime(2026).add(const Duration(seconds: 3)),
    ),
  ],
);

ChatState _thought() => ChatState(
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
      reasoning: 'Первая строка\nВторая строка',
      text: 'Готово',
    ),
  ],
  stepsDisplay: const StepsDisplay(thoughts: ThoughtsVisibility.all),
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
      body: SizedBox(height: 700, child: ChatTimeline(state: state)),
    ),
  );
}

void main() {
  testWidgets('command expands and can grow to full height', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_TestApp(_command()));
    await tester.pumpAndSettle();

    // Закрытый блок кнопки раскрытия не показывает.
    expect(find.byIcon(Icons.fullscreen), findsNothing);

    await tester.tap(find.text('flutter analyze'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);

    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen_exit), findsNothing);
  });

  testWidgets('full height of a command is capped by the chat viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final long = [for (var i = 0; i < 300; i++) 'line $i'].join('\n');
    await tester.pumpWidget(_TestApp(_command(output: long)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('flutter analyze'));
    await tester.pumpAndSettle();

    final viewport = find.byKey(const ValueKey('command-output-viewport'));
    final collapsed = tester.getSize(viewport).height;
    expect(collapsed, lessThanOrEqualTo(220));

    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pumpAndSettle();
    // Видимая часть терминала занимает высоту ленты (700), без выхода за неё.
    final full = tester.getSize(viewport).height;
    expect(full, greaterThan(collapsed));
    expect(full, lessThanOrEqualTo(700));
    expect(full, closeTo(700, 40));
  });

  testWidgets('expanding a step keeps its header where it was', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_TestApp(_command()));
    await tester.pumpAndSettle();

    final before = tester.getTopLeft(find.text('flutter analyze')).dy;
    await tester.tap(find.text('flutter analyze'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('flutter analyze')).dy,
      closeTo(before, 1),
    );
    // Тело раскрылось: кнопка «на всю высоту» появилась.
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
  });

  testWidgets('expanding a step in a long chat keeps its header where it was', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Длинная история: лента прокручивается, поэтому блок растёт в прокручиваемом месте.
    final base = _command();
    final history = [
      for (var i = 0; i < 12; i++) ...[
        ChatMessage(
          id: 'h$i-u',
          chatId: 'c',
          seq: 0,
          role: MessageRole.user,
          createdAt: DateTime(2026),
          text: 'Вопрос $i',
        ),
        ChatMessage(
          id: 'h$i-a',
          chatId: 'c',
          seq: 0,
          role: MessageRole.assistant,
          createdAt: DateTime(2026),
          text: [for (var k = 0; k < 6; k++) 'Длинный ответ $i, абзац $k.']
              .join('\n\n'),
        ),
      ],
    ];
    // Команда в предыдущем ходе: последний ход заполняет окно, поэтому над ним блок прокручивается.
    final later = [
      ChatMessage(
        id: 'later-u',
        chatId: 'c',
        seq: 0,
        role: MessageRole.user,
        createdAt: DateTime(2026),
        text: 'Новый вопрос',
      ),
      ChatMessage(
        id: 'later-a',
        chatId: 'c',
        seq: 0,
        role: MessageRole.assistant,
        createdAt: DateTime(2026),
        text: 'Новый ответ',
      ),
    ];
    await tester.pumpWidget(
      _TestApp(
        base.copyWith(messages: [...history, ...base.messages, ...later]),
      ),
    );
    await tester.pumpAndSettle();
    // Прокручиваем к команде: тянем вниз, лента уходит к более старым сообщениям.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pumpAndSettle();

    final before = tester.getTopLeft(find.text('flutter analyze')).dy;
    await tester.tap(find.text('flutter analyze'));
    // Проверяем каждый кадр: рывок «вверх и обратно» виден именно в отдельных кадрах.
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        tester.getTopLeft(find.text('flutter analyze')).dy,
        closeTo(before, 0.5),
        reason: 'frame $frame',
      );
    }
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('flutter analyze')).dy,
      closeTo(before, 0.5),
    );
  });

  testWidgets('copy button sits in the header and copies the output', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.binding.setSurfaceSize(const Size(800, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_TestApp(_command()));
    await tester.pumpAndSettle();

    // Свёрнутая команда кнопку копирования не показывает.
    expect(find.byKey(const ValueKey('step-copy')), findsNothing);

    await tester.tap(find.text('flutter analyze'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('step-copy')));
    await tester.pump();
    expect(copied, contains('No issues found!'));
    // Нажатие на кнопку копирования не сворачивает блок.
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('without a chat viewport a full-height command has no limit', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final long = [for (var i = 0; i < 300; i++) 'line $i'].join('\n');
    final run = _command(output: long).runs.single;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 600,
              child: ChatStepLedger(
                steps: [RunStep(run)],
                live: const {},
                expandTools: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pumpAndSettle();
    expect(
      tester
          .getSize(find.byKey(const ValueKey('command-output-viewport')))
          .height,
      greaterThan(700),
    );
  });

  testWidgets('thought expands and drops its height limit', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_TestApp(_thought()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Первая строка'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Вторая строка'), findsOneWidget);
    expect(find.byType(SingleChildScrollView), findsOneWidget);

    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pumpAndSettle();
    expect(find.byType(SingleChildScrollView), findsNothing);
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
  });

  testWidgets('card block highlights as a whole on hover', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_TestApp(_command()));
    await tester.pumpAndSettle();

    final scheme = Theme.of(tester.element(find.text('flutter analyze')))
        .colorScheme;
    bool hasFill(Color color) => tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .any(
          (w) =>
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).color == color,
        );

    expect(hasFill(scheme.surfaceContainerLow), isTrue);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('flutter analyze')));
    await tester.pumpAndSettle();
    expect(hasFill(scheme.surfaceContainer), isTrue);

    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(hasFill(scheme.surfaceContainer), isFalse);
  });
}
