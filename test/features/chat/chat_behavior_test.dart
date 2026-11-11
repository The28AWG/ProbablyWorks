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
import 'package:probably_works/features/chat/presentation/widgets/chat_composer.dart';
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

/// При слежении расстояние от конца ленты ноль: внизу виден нижний отступ, а ход прижат к верху окна.
const _followOffset = 0.0;

/// Расстояние от конца ленты: 0, когда видно последнее сообщение.
double _fromEnd(ScrollPosition p) => p.maxScrollExtent - p.pixels;

/// Верхние края сообщений, которые сейчас видны в окне ленты.
Map<String, double> _visibleTops(WidgetTester tester) {
  final window = tester.getRect(find.byType(CustomScrollView));
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
    expect(_fromEnd(position), closeTo(_followOffset, 1));
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

      await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(find.text(l10n.chatScrollToLatest), findsOneWidget);
      final away = _fromEnd(position);
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
      expect(_fromEnd(position), closeTo(_followOffset, 1));
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
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
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
    expect(_fromEnd(position), closeTo(_followOffset, 1));
  });

  testWidgets('compaction marker shows and expands the summary', (
    tester,
  ) async {
    // Лента открывается внизу; маркер стоит в начале (сверху), поэтому прокручиваем к нему.
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
    _position(tester).jumpTo(0);
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
    // Статус выведен иконкой, а её подпись живёт в richMessage подсказки: find.byTooltip ищет только message.
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Tooltip &&
            w.richMessage?.toPlainText() == l10n.runStatusFailed,
      ),
      findsOneWidget,
    );
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
    expect(find.text(l10n.approvalAllowTurn), findsOneWidget);
    expect(find.text(l10n.approvalAllowChat), findsOneWidget);
    expect(find.text(l10n.approvalApprove), findsOneWidget);
    expect(find.text(l10n.approvalDeny), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ChatTimeline),
        matching: find.text(l10n.approvalTitle),
      ),
      findsNothing,
    );

    await tester.tap(find.text(l10n.approvalDeny));
    await tester.pumpAndSettle();
    expect(find.text(l10n.approvalDenyReasonTitle), findsOneWidget);
    await tester.tap(find.text(l10n.commonCancel));
    await tester.pumpAndSettle();
    expect(find.text(l10n.approvalDenyReasonTitle), findsNothing);
  });

  testWidgets('several approvals show a bulk once action', (tester) async {
    final state = _state(
      running: true,
      approvals: const [
        ApprovalRequest(
          id: 'ap1',
          chatId: 'c',
          toolName: 'run_command',
          summary: 'ls',
          reason: 'Needs confirmation.',
        ),
        ApprovalRequest(
          id: 'ap2',
          chatId: 'c',
          toolName: 'run_command',
          summary: 'pwd',
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

    expect(find.text(l10n.approvalBulkCount(2)), findsOneWidget);
    expect(find.text(l10n.approvalAllowAllOnce), findsOneWidget);
    expect(find.text(l10n.approvalTitle), findsNWidgets(2));
  });

  testWidgets('approval actions wrap on a narrow dock', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final state = _state(
      running: true,
      approvals: const [
        ApprovalRequest(
          id: 'ap1',
          chatId: 'c',
          toolName: 'run_command',
          summary: 'mkdir build',
          reason: 'Needs confirmation.',
        ),
        ApprovalRequest(
          id: 'ap2',
          chatId: 'c',
          toolName: 'run_command',
          summary: 'touch build/out',
          reason: 'Needs confirmation.',
        ),
      ],
    );
    final bloc = SeededChatBloc(state);
    addTearDown(bloc.close);
    await tester.pumpWidget(
      _TestApp(
        SizedBox(width: 340, child: ChatAttentionDock(state: state)),
        bloc: bloc,
      ),
    );
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byType(ChatAttentionDock)),
    );
    expect(find.text(l10n.approvalAllowTurn), findsNWidgets(2));
    expect(find.text(l10n.approvalAllowChat), findsNWidgets(2));
    expect(find.text(l10n.approvalApprove), findsNWidgets(2));
    expect(find.text(l10n.approvalAllowAllOnce), findsOneWidget);
  });

  testWidgets(
    'empty chat centers the composer under the welcome, without suggestions',
    (tester) async {
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
      expect(find.byType(ActionChip), findsNothing);
      expect(find.text(l10n.chatWelcomeTitle), findsOneWidget);
      // Композер в средней части экрана, а не у нижнего края.
      expect(
        tester.getCenter(find.byType(ChatComposer)).dy,
        inInclusiveRange(300, 570),
      );

      // Пустое поле: кнопки отправки нет совсем, а не только неактивна.
      expect(_sendButtonFinder(l10n), findsNothing);
      await tester.enterText(find.byType(TextField), 'Проверь проект');
      await tester.pump();
      expect(
        tester.widget<IconButton>(_sendButtonFinder(l10n)).onPressed,
        isNotNull,
      );
      // Черновик сохраняется с задержкой: дождаться её, иначе таймер останется после теста.
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('chat with messages keeps the composer at the bottom', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _TestApp(const ChatBody(), bloc: SeededChatBloc(_state(count: 2))),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        AppLocalizations.of(tester.element(find.byType(ChatBody)))
            .chatWelcomeTitle,
      ),
      findsNothing,
    );
    expect(tester.getCenter(find.byType(ChatComposer)).dy, greaterThan(600));
  });

  testWidgets('each finished turn keeps a copy button on its closing answer', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final start = DateTime(2026);
    final messages = [
      for (var i = 0; i < 2; i++) ...[
        ChatMessage(
          id: 'u$i',
          chatId: 'c',
          seq: i * 2 + 1,
          role: MessageRole.user,
          createdAt: start.add(Duration(minutes: i)),
          text: 'Question $i',
        ),
        ChatMessage(
          id: 'a$i',
          chatId: 'c',
          seq: i * 2 + 2,
          role: MessageRole.assistant,
          createdAt: start.add(Duration(minutes: i, seconds: 5)),
          text: 'Answer $i',
        ),
      ],
    ];
    var regenerated = false;
    await tester.pumpWidget(
      _TestApp(
        SizedBox(
          height: 500,
          child: ChatTimeline(
            state: ChatState(chatId: 'c', messages: messages),
            onRegenerate: () => regenerated = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Finder copyIn(String id) => find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is ChatMessageTile && w.message.id == id,
      ),
      matching: find.byIcon(Icons.copy_outlined),
    );
    Finder regenerateIn(String id) => find.descendant(
      of: find.byWidgetPredicate(
        (w) => w is ChatMessageTile && w.message.id == id,
      ),
      matching: find.byIcon(Icons.refresh),
    );
    expect(copyIn('u0'), findsNothing);
    expect(copyIn('a0'), findsOneWidget);
    expect(copyIn('a1'), findsOneWidget);
    expect(regenerateIn('a0'), findsNothing);
    expect(regenerateIn('a1'), findsOneWidget);
    expect(regenerated, isFalse);
  });

  testWidgets('copy follows the closing answer of the last finished turn', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final start = DateTime(2026);
    ChatMessage at(
      String id,
      int seq,
      MessageRole role,
      int seconds, {
      String text = '',
      List<ToolCallRef> calls = const [],
    }) => ChatMessage(
      id: id,
      chatId: 'c',
      seq: seq,
      role: role,
      createdAt: start.add(Duration(seconds: seconds)),
      text: text,
      toolCalls: calls,
    );
    // Первый ход закрыт текстом. Второй: промежуточный текст с командой и закрытие через finish.
    final messages = [
      at('u1', 1, MessageRole.user, 0, text: 'First'),
      at(
        'a1',
        2,
        MessageRole.assistant,
        1,
        text: 'Reading',
        calls: const [
          ToolCallRef(id: 'c1', name: 'run_command', arguments: '{}'),
        ],
      ),
      at('t1', 3, MessageRole.tool, 2, text: 'ok'),
      at('a2', 4, MessageRole.assistant, 5, text: 'First answer'),
      at('u2', 5, MessageRole.user, 60, text: 'Second'),
      at(
        'a3',
        6,
        MessageRole.assistant,
        61,
        text: 'Still working',
        calls: const [
          ToolCallRef(id: 'c2', name: 'run_command', arguments: '{}'),
        ],
      ),
      at('t2', 7, MessageRole.tool, 62, text: 'ok'),
      at(
        'a4',
        8,
        MessageRole.assistant,
        63,
        text: 'Second answer',
        calls: const [ToolCallRef(id: 'c3', name: 'finish', arguments: '{}')],
      ),
      at('t3', 9, MessageRole.tool, 64, text: 'summary'),
    ];

    Future<void> pump({required bool running}) => tester.pumpWidget(
      _TestApp(
        SizedBox(
          height: 500,
          child: ChatTimeline(
            state: ChatState(
              chatId: 'c',
              messages: messages,
              isRunning: running,
            ),
          ),
        ),
      ),
    );

    List<String> copiedIds() {
      final ids = <String>[];
      for (final element in find.byType(ChatMessageTile).evaluate()) {
        final tile = element.widget as ChatMessageTile;
        final copy = find.descendant(
          of: find.byWidget(tile),
          matching: find.byIcon(Icons.copy_outlined),
        );
        if (copy.evaluate().isNotEmpty) ids.add(tile.message.id);
      }
      return ids;
    }

    await pump(running: false);
    await tester.pumpAndSettle();
    expect(copiedIds(), ['a2', 'a4']);

    // Второй ход ещё идёт: его сообщения не ответ, кнопка первого хода остаётся.
    await pump(running: true);
    await tester.pumpAndSettle();
    expect(copiedIds(), ['a2']);
  });

  testWidgets('each finished task shows its own time under its final answer', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final start = DateTime(2026);
    ChatMessage at(
      String id,
      int seq,
      MessageRole role,
      int seconds, {
      String text = '',
      List<ToolCallRef> calls = const [],
    }) => ChatMessage(
      id: id,
      chatId: 'c',
      seq: seq,
      role: role,
      createdAt: start.add(Duration(seconds: seconds)),
      text: text,
      toolCalls: calls,
    );
    // Первое задание: шаг с командой, результат, финальный ответ (на 5-й секунде).
    // Второе: финальный ответ через finish (на 63-й секунде, результат finish — на 64-й).
    final messages = [
      at('u1', 1, MessageRole.user, 0, text: 'First'),
      at(
        'a1',
        2,
        MessageRole.assistant,
        1,
        text: 'Reading',
        calls: const [
          ToolCallRef(id: 'c1', name: 'run_command', arguments: '{}'),
        ],
      ),
      at('t1', 3, MessageRole.tool, 2, text: 'ok'),
      at('a2', 4, MessageRole.assistant, 5, text: 'First answer'),
      at('u2', 5, MessageRole.user, 60, text: 'Second'),
      at(
        'a3',
        6,
        MessageRole.assistant,
        63,
        text: 'Second answer',
        calls: const [ToolCallRef(id: 'c2', name: 'finish', arguments: '{}')],
      ),
      at('t2', 7, MessageRole.tool, 64, text: 'summary'),
    ];

    Future<void> pump({required bool running}) => tester.pumpWidget(
      _TestApp(
        SizedBox(
          height: 500,
          child: ChatTimeline(
            state: ChatState(
              chatId: 'c',
              messages: messages,
              isRunning: running,
            ),
          ),
        ),
      ),
    );

    await pump(running: false);
    await tester.pumpAndSettle();
    expect(find.text('5s'), findsOneWidget);
    expect(find.text('4s'), findsOneWidget);

    // Пока ход идёт, последнее задание без времени; законченное первое задание своё время сохраняет.
    await pump(running: true);
    await tester.pumpAndSettle();
    expect(find.text('4s'), findsNothing);
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

      final gap = tester.getSize(find.byKey(const ValueKey('timeline-gap')));
      expect(gap.height, closeTo(600 / 3, 0.5));
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
    expect(_fromEnd(_position(tester)), closeTo(_followOffset, 1));
    final window = tester.getRect(find.byType(CustomScrollView));
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
      expect(_fromEnd(_position(tester)), closeTo(_followOffset, 1));
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

    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.text(l10n.chatScrollToLatest), findsOneWidget);

    await tester.drag(find.byType(CustomScrollView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(_fromEnd(_position(tester)), closeTo(_followOffset, 1));
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
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 40));
      await tester.pump();
      final scrolled = _position(tester).pixels - pixelsBefore;
      final after = _visibleTops(tester);
      for (final id in before.keys.where(after.containsKey)) {
        expect(
          after[id]! - before[id]!,
          closeTo(-scrolled, 0.5),
          reason: 'step $step, $id',
        );
      }
    }
  });
}
