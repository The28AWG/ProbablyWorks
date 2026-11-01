import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
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

/// Пустое место между низом последнего сообщения и низом ленты.
double _gapBelowLast(WidgetTester tester, int count) {
  final timeline = tester.renderObject<RenderBox>(
    find.byType(ChatTimeline).first,
  );
  final timelineBottom = timeline.localToGlobal(
    Offset(0, timeline.size.height),
  ).dy;
  final last = tester.renderObject<RenderBox>(
    find.text('Message $count').first,
  );
  final lastBottom = last.localToGlobal(Offset(0, last.size.height)).dy;
  return timelineBottom - lastBottom;
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

  testWidgets('short chat sits at the bottom without an empty inset', (
    tester,
  ) async {
    await pump(tester, 1);

    expect(_position(tester).maxScrollExtent, 0);
    expect(_gapBelowLast(tester, 1), lessThan(80));
  });

  testWidgets('long chat follows the end with the inset hidden below', (
    tester,
  ) async {
    await pump(tester, 40);

    final viewport = _position(tester).viewportDimension;
    expect(_position(tester).pixels, closeTo(viewport / 3, 1));
    expect(_gapBelowLast(tester, 40), lessThan(80));
  });

  testWidgets('user can scroll down into the inset of a long chat', (
    tester,
  ) async {
    await pump(tester, 40);
    final followGap = _gapBelowLast(tester, 40);

    _position(tester).jumpTo(0);
    await tester.pumpAndSettle();

    final viewport = _position(tester).viewportDimension;
    expect(
      _gapBelowLast(tester, 40) - followGap,
      closeTo(viewport / 3, 1),
    );
  });
}
