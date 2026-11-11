import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_message_tile.dart';
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

ChatState _state(int count) => ChatState(
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
  messages: [for (var i = 1; i <= count; i++) _msg(i)],
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
      body: Column(
        children: [
          const SizedBox(height: 60),
          Expanded(child: ChatTimeline(state: state)),
          const SizedBox(height: 150),
        ],
      ),
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
  Future<void> pump(WidgetTester tester, int count) async {
    tester.view.physicalSize = const Size(1000, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_TestApp(_state(count)));
    await tester.pumpAndSettle();
  }

  testWidgets('short chat keeps the window third free below the gap', (
    tester,
  ) async {
    await pump(tester, 1);

    final viewport = _position(tester).viewportDimension;
    final gap = tester.getSize(find.byKey(const ValueKey('timeline-gap')));
    expect(gap.height, closeTo(viewport / 3, 0.5));
    expect(_fromEnd(_position(tester)), 0);
  });

  testWidgets('the newest question sits under the top edge of the window', (
    tester,
  ) async {
    await pump(tester, 1);

    final window = tester.getRect(find.byType(ChatTimeline));
    final question = tester.getRect(find.byType(ChatMessageTile).first);
    expect(question.top - window.top, closeTo(AppSpacing.md, 0.5));
  });

  testWidgets('long chat rests at the end, pinned to the same gap', (
    tester,
  ) async {
    await pump(tester, 40);

    expect(_fromEnd(_position(tester)), 0);
    expect(_position(tester).maxScrollExtent, greaterThan(0));
  });

  testWidgets('scrolling up and back down returns to the end', (tester) async {
    await pump(tester, 40);

    _position(tester).jumpTo(_position(tester).maxScrollExtent - 200);
    await tester.pumpAndSettle();
    expect(_fromEnd(_position(tester)), 200);

    _position(tester).jumpTo(_position(tester).maxScrollExtent);
    await tester.pumpAndSettle();
    expect(_fromEnd(_position(tester)), 0);
  });
}

/// Расстояние от конца ленты: 0, когда видно последнее сообщение.
double _fromEnd(ScrollPosition p) => p.maxScrollExtent - p.pixels;
