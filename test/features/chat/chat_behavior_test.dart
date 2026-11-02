import 'package:flutter/gestures.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/interaction/interaction_broker.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_attention_dock.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_message_tile.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_step_ledger.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_timeline.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_view.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/test_support/golden_fonts.dart';
import 'package:probably_works/test_support/seeded_chat_bloc.dart';

class _TestApp extends StatelessWidget {
  const _TestApp(this.child, {this.bloc});

  final Widget child;
  final ChatBloc? bloc;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: bloc == null
          ? child
          : BlocProvider<ChatBloc>.value(value: bloc!, child: child),
    ),
  );
}

Finder _sendButtonFinder(AppLocalizations l10n) => find.ancestor(
  of: find.byTooltip(l10n.composerSend),
  matching: find.byType(IconButton),
);

ChatMessage _msg(int i) => ChatMessage(
  id: 'm$i',
  chatId: 'c',
  seq: i,
  role: i.isEven ? MessageRole.user : MessageRole.assistant,
  createdAt: DateTime(2026),
  text: i.isEven
      ? 'Question $i'
      : 'Answer $i\n\nSome text that fills the line.',
);

ChatState _state({
  int count = 20,
  bool running = false,
  int compactedUntilSeq = 0,
  String? summary,
  List<ToolRun> runs = const [],
  List<ApprovalRequest> approvals = const [],
}) => ChatState(
  chatId: 'c',
  chat: Chat(
    id: 'c',
    hostId: 'local',
    title: 'Chat',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    compactedUntilSeq: compactedUntilSeq,
    compactionSummary: summary,
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
  messages: [for (var i = 1; i <= count; i++) _msg(i)],
  runs: runs,
  approvals: approvals,
  isRunning: running,
);

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

/// Лента перевёрнута: при слежении смещение ноль, внизу виден нижний отступ, а ход прижат к верху окна.
const _followOffset = 0.0;

/// Верхние края сообщений, которые сейчас видны в окне ленты.
Map<String, double> _visibleTops(WidgetTester tester) {
  final window = tester.getRect(find.byType(ListView));
  final tops = <String, double>{};
  for (final element in find.byType(ChatMessageTile).evaluate()) {
    final tile = element.widget as ChatMessageTile;
    final rect = tester.getRect(find.byWidget(tile));
    if (rect.top >= window.top && rect.bottom <= window.bottom) {
      tops[tile.message.id] = rect.top;
    }
  }
  return tops;
}

/// Ленту с сообщениями разной высоты: так лента не может заранее знать, сколько места займёт каждое.
ChatState _variedState(int count) => ChatState(
  chatId: 'c',
  chat: Chat(
    id: 'c',
    hostId: 'local',
    title: 'Chat',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  ),
  messages: [
    for (var i = 1; i <= count; i++)
      ChatMessage(
        id: 'm$i',
        chatId: 'c',
        seq: i,
        role: i.isEven ? MessageRole.user : MessageRole.assistant,
        createdAt: DateTime(2026),
        text:
            'Message $i: ${List.filled((i * 7) % 23 + 3, 'lorem ipsum dolor').join(' ')}',
      ),
  ],
);

void main() {
  setUpAll(GoldenFonts.load);

  testWidgets('timeline starts at the newest message', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _TestApp(SizedBox(height: 500, child: ChatTimeline(state: _state()))),
    );
    await tester.pumpAndSettle();
    final position = _position(tester);
    expect(position.maxScrollExtent, greaterThan(0));
    expect(position.pixels, closeTo(_followOffset, 1));
  });

  testWidgets(
    'scrolling up pauses following and the jump button returns to the end',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 500));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _TestApp(SizedBox(height: 500, child: ChatTimeline(state: _state()))),
      );
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
        tester.element(find.byType(ChatTimeline)),
      );
      final position = _position(tester);

      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(find.text(l10n.chatScrollToLatest), findsOneWidget);
      final away = position.pixels;
      expect(away, greaterThan(_followOffset + 100));

      // Новый ответ ассистента не должен увести читателя от места, на котором он остановился.
      final before = _visibleTops(tester);
      await tester.pumpWidget(
        _TestApp(
          SizedBox(
            height: 500,
            child: ChatTimeline(state: _state(count: 21, running: true)),
          ),
        ),
      );
      // Кнопка копирования уходит с прошлого ответа анимацией. Изменение лежит ниже сообщений, которые
      // читает пользователь: они стоят на месте (якорь), ход с новым вопросом ниже сдвигается.
      // Якорь догоняет изменение после кадра, поэтому в кадре отставание до одного шага анимации (16 px).
      final reading = before.keys.where((id) => id == 'm18');
      expect(reading, isNotEmpty);
      for (var frame = 0; frame < 15; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
        final now = _visibleTops(tester);
        for (final id in reading.where(now.containsKey)) {
          expect(now[id], closeTo(before[id]!, 16), reason: '$id, кадр $frame');
        }
      }
      await tester.pumpAndSettle();
      final after = _visibleTops(tester);
      for (final id in reading.where(after.containsKey)) {
        expect(after[id], closeTo(before[id]!, 0.5), reason: id);
      }

      await tester.tap(find.text(l10n.chatScrollToLatest));
      await tester.pumpAndSettle();
      expect(find.text(l10n.chatScrollToLatest), findsNothing);
      expect(position.pixels, closeTo(_followOffset, 1));
    },
  );

  testWidgets('sending a message always brings the reader to the end', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _TestApp(SizedBox(height: 500, child: ChatTimeline(state: _state()))),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(ChatTimeline)));
    final position = _position(tester);
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text(l10n.chatScrollToLatest), findsOneWidget);

    final base = _state();
    await tester.pumpWidget(
      _TestApp(
        SizedBox(
          height: 500,
          child: ChatTimeline(
            state: ChatState(
              chatId: base.chatId,
              chat: base.chat,
              hosts: base.hosts,
              messages: [
                ...base.messages,
                ChatMessage(
                  id: 'mine',
                  chatId: 'c',
                  seq: 99,
                  role: MessageRole.user,
                  createdAt: DateTime(2026),
                  text: 'My new question',
                ),
              ],
              isRunning: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(l10n.chatScrollToLatest), findsNothing);
    expect(position.pixels, closeTo(_followOffset, 1));
  });

  testWidgets('compaction marker shows and expands the summary', (
    tester,
  ) async {
    // Лента открывается внизу; маркер стоит в начале, поэтому прокручиваем к нему.
    await tester.pumpWidget(
      _TestApp(
        SizedBox(
          height: 500,
          child: ChatTimeline(
            state: _state(
              count: 6,
              compactedUntilSeq: 3,
              summary: 'Earlier: the user asked for a review.',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    _position(tester).jumpTo(_position(tester).maxScrollExtent);
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(ChatTimeline)));
    expect(find.text(l10n.compactionMarker), findsOneWidget);
    expect(find.text('Earlier: the user asked for a review.'), findsNothing);
    await tester.tap(find.text(l10n.compactionShowSummary));
    await tester.pumpAndSettle();
    expect(find.text('Earlier: the user asked for a review.'), findsOneWidget);
  });

  testWidgets('single successful step shows its command without a group', (
    tester,
  ) async {
    final start = DateTime(2026);
    final runs = [
      ToolRun(
        id: 'r1',
        chatId: 'c',
        messageId: 'a',
        toolName: 'run_command',
        argsJson: '{}',
        command: 'flutter analyze',
        outputText: 'No issues found!',
        status: ToolRunStatus.done,
        startedAt: start,
        finishedAt: start.add(const Duration(seconds: 3)),
      ),
    ];
    await tester.pumpWidget(
      _TestApp(
        SingleChildScrollView(
          child: ChatStepLedger(
            steps: [for (final run in runs) RunStep(run)],
            live: const {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ChatStepLedger)),
    );
    expect(find.text(l10n.stepsGroupDone(1)), findsNothing);
    expect(find.text('flutter analyze'), findsOneWidget);
    expect(find.byType(CommandOutput), findsNothing);

    await tester.tap(find.text('flutter analyze'));
    await tester.pumpAndSettle();
    expect(find.byType(CommandOutput), findsOneWidget);
  });

  testWidgets('several steps collapse into a group that stays collapsed', (
    tester,
  ) async {
    final start = DateTime(2026);
    final runs = [
      for (final id in ['r1', 'r2'])
        ToolRun(
          id: id,
          chatId: 'c',
          messageId: 'a',
          toolName: 'run_command',
          argsJson: '{}',
          command: 'command $id',
          status: ToolRunStatus.done,
          startedAt: start,
          finishedAt: start.add(const Duration(seconds: 3)),
        ),
    ];
    await tester.pumpWidget(
      _TestApp(
        SingleChildScrollView(
          child: ChatStepLedger(
            steps: [for (final run in runs) RunStep(run)],
            live: const {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ChatStepLedger)),
    );
    expect(find.text(l10n.stepsGroupDone(2)), findsOneWidget);
    expect(find.text('command r1'), findsNothing);

    await tester.tap(find.text(l10n.stepsGroupDone(2)));
    await tester.pumpAndSettle();
    expect(find.text('command r1'), findsOneWidget);
    expect(find.text('command r2'), findsOneWidget);
  });

  testWidgets('step ledger keeps failed steps visible without expanding', (
    tester,
  ) async {
    final start = DateTime(2026);
    final runs = [
      ToolRun(
        id: 'r1',
        chatId: 'c',
        messageId: 'a',
        toolName: 'run_command',
        argsJson: '{}',
        command: 'flutter test test/core',
        status: ToolRunStatus.failed,
        startedAt: start,
        finishedAt: start.add(const Duration(seconds: 2)),
      ),
    ];
    await tester.pumpWidget(
      _TestApp(
        SingleChildScrollView(
          child: ChatStepLedger(
            steps: [for (final run in runs) RunStep(run)],
            live: const {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ChatStepLedger)),
    );
    expect(find.text('flutter test test/core'), findsOneWidget);
    expect(find.text(l10n.runStatusFailed), findsOneWidget);
  });

  testWidgets('approval waits in the dock, not in the timeline', (
    tester,
  ) async {
    final state = _state(
      running: true,
      approvals: const [
        ApprovalRequest(
          id: 'ap1',
          chatId: 'c',
          toolName: 'run_command',
          summary: 'rm -rf build',
          reason: 'Needs confirmation.',
        ),
      ],
    );
    final bloc = SeededChatBloc(state);
    addTearDown(bloc.close);
    await tester.pumpWidget(
      _TestApp(
        Column(
          children: [
            Expanded(child: ChatTimeline(state: state)),
            ChatAttentionDock(state: state),
          ],
        ),
        bloc: bloc,
      ),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ChatAttentionDock)),
    );
    expect(find.text(l10n.approvalTitle), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ChatTimeline),
        matching: find.text(l10n.approvalTitle),
      ),
      findsNothing,
    );
  });

  testWidgets('empty chat suggests a prompt that fills the composer', (
    tester,
  ) async {
    final bloc = SeededChatBloc(
      ChatState(
        chatId: 'c',
        chat: Chat(
          id: 'c',
          hostId: 'local',
          title: '',
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
      ),
    );
    addTearDown(bloc.close);
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_TestApp(const ChatBody(), bloc: bloc));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(tester.element(find.byType(ChatBody)));
    expect(
      tester.widget<IconButton>(_sendButtonFinder(l10n)).onPressed,
      isNull,
    );

    await tester.tap(find.text(l10n.chatSuggestion1));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, l10n.chatSuggestion1);
    expect(
      tester.widget<IconButton>(_sendButtonFinder(l10n)).onPressed,
      isNotNull,
    );
  });

  testWidgets('copy under an answer exists only for the last answer', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _TestApp(
        SizedBox(height: 500, child: ChatTimeline(state: _state(count: 3))),
      ),
    );
    await tester.pumpAndSettle();

    Finder copyIn(String id) => find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is ChatMessageTile && w.message.id == id,
      ),
      matching: find.byIcon(Icons.copy_outlined),
    );
    // Ответ агента: кнопка только у последнего ответа, без резерва места у остальных.
    expect(copyIn('m1'), findsNothing);
    expect(copyIn('m3'), findsOneWidget);
  });

  testWidgets('user message actions appear on hover', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _TestApp(
        SizedBox(height: 500, child: ChatTimeline(state: _state(count: 2))),
      ),
    );
    await tester.pumpAndSettle();
    // Панель действий сообщения пользователя живёт внутри его плитки.
    double actionsOf(String id) => tester
        .widget<AnimatedOpacity>(
          find.descendant(
            of: find.byWidgetPredicate(
              (w) => w is ChatMessageTile && w.message.id == id,
            ),
            matching: find.byType(AnimatedOpacity),
          ),
        )
        .opacity;

    // Курсор стартует за пределами окна: иначе он попадает на ответ ассистента в углу ленты.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(-10, -10));
    addTearDown(mouse.removePointer);
    expect(actionsOf('m2'), 0);
    await mouse.moveTo(tester.getCenter(find.text('Question 2')));
    await tester.pumpAndSettle();
    expect(actionsOf('m2'), 1);
  });

  testWidgets(
    'the list keeps a third of its height free below the last message',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_TestApp(ChatTimeline(state: _state())));
      await tester.pumpAndSettle();

      final list = tester.widget<ListView>(find.byType(ListView));
      final padding = list.padding! as EdgeInsets;
      expect(padding.bottom, closeTo(600 / 3, 0.5));
    },
  );

  testWidgets('a short chat still pins its last question to the top', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_TestApp(ChatTimeline(state: _state(count: 2))));
    await tester.pumpAndSettle();

    // Короткий чат тоже занимает окно до отступа: вопрос стоит у верха, отступ внизу не пропадает.
    expect(_position(tester).pixels, closeTo(_followOffset, 1));
    final window = tester.getRect(find.byType(ListView));
    final question = _visibleTops(tester)['m2'];
    expect(question, isNotNull);
    expect(question! - window.top, closeTo(AppSpacing.md, 0.5));
  });

  testWidgets('streamed answer keeps its end at the bottom of the window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    // Длинный чат: короткий не может прокрутиться до конца отступа, и его ответ стоит сверху.
    final base = _state(count: 20);
    await tester.pumpWidget(_TestApp(ChatTimeline(state: base)));
    await tester.pumpAndSettle();
    for (var i = 1; i <= 5; i++) {
      await tester.pumpWidget(
        _TestApp(
          ChatTimeline(
            state: base.copyWith(streamText: 'Line $i\n\n' * (i * 3)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_position(tester).pixels, closeTo(_followOffset, 1));
    }
  });

  testWidgets('scrolling back down to the newest message resumes following', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _TestApp(SizedBox(height: 600, child: ChatTimeline(state: _state()))),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(ChatTimeline)));

    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text(l10n.chatScrollToLatest), findsOneWidget);

    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, closeTo(_followOffset, 1));
    expect(find.text(l10n.chatScrollToLatest), findsNothing);
  });

  testWidgets('an opened step output stays open when a newer message arrives', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final start = DateTime(2026);
    final runs = [
      ToolRun(
        id: 'r1',
        chatId: 'c',
        messageId: 'm2',
        toolName: 'run_command',
        argsJson: '{}',
        command: 'flutter analyze',
        outputText: 'No issues found!',
        status: ToolRunStatus.done,
        startedAt: start,
        finishedAt: start.add(const Duration(seconds: 3)),
      ),
    ];
    final base = _state(count: 2, runs: runs);
    await tester.pumpWidget(_TestApp(ChatTimeline(state: base)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('flutter analyze'));
    await tester.pumpAndSettle();
    expect(find.byType(CommandOutput), findsOneWidget);

    // Новое сообщение встаёт в начало списка, и элементы сдвигаются по индексу. Раскрытая группа
    // должна остаться на своём сообщении, а не перейти к соседнему.
    await tester.pumpWidget(
      _TestApp(
        ChatTimeline(
          state: base.copyWith(
            messages: [
              ...base.messages,
              ChatMessage(
                id: 'm3',
                chatId: 'c',
                seq: 3,
                role: MessageRole.assistant,
                createdAt: DateTime(2026),
                text: 'Answer 3',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('flutter analyze'), findsOneWidget);
  });

  testWidgets('reading history keeps the text under the reader still', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_TestApp(ChatTimeline(state: _variedState(40))));
    await tester.pumpAndSettle();

    // Прокрутка вверх: элементы выше окна дорисовываются и получают свою высоту. Текст на экране
    // не должен сдвигаться ни на пиксель относительно того, как он ушёл при прокрутке.
    for (var step = 0; step < 30; step++) {
      final before = _visibleTops(tester);
      final pixelsBefore = _position(tester).pixels;
      await tester.drag(find.byType(ListView), const Offset(0, 40));
      await tester.pump();
      final scrolled = _position(tester).pixels - pixelsBefore;
      final after = _visibleTops(tester);
      for (final id in before.keys.where(after.containsKey)) {
        expect(
          after[id]! - before[id]!,
          closeTo(scrolled, 0.5),
          reason: 'step $step, $id',
        );
      }
    }
  });
}
