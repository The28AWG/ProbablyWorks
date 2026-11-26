import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_timeline.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';

void main() {
  testWidgets('scrolls to a message far down the timeline', (tester) async {
    final now = DateTime.utc(2026, 11, 13);
    final messages = [
      for (var i = 0; i < 40; i++)
        ChatMessage(
          id: 'm$i',
          chatId: 'c1',
          seq: i + 1,
          role: i.isEven ? MessageRole.user : MessageRole.assistant,
          text: 'message $i',
          createdAt: now,
        ),
    ];
    final state = ChatState(
      chatId: 'c1',
      chat: Chat(
        id: 'c1',
        hostId: 'local',
        title: 'Chat',
        createdAt: now,
        updatedAt: now,
      ),
      messages: messages,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: ChatTimeline(state: state, jumpToMessageId: 'm30'),
          ),
        ),
      ),
    );
    // Переход к сообщению анимированный: даём кадрам доиграть, иначе цель
    // остаётся за пределами окна до следующего pump.
    await tester.pumpAndSettle();

    expect(find.text('message 30'), findsOneWidget);
  });
}
