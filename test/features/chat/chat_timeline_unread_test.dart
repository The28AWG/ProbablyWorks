import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_timeline.dart';
import 'package:probably_works/features/workspace/presentation/widgets/presence_lifecycle.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';

void main() {
  testWidgets('opens at the first unread and marks the end as read', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 11, 26);
    final messages = [
      for (var i = 0; i < 20; i++)
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
        lastReadSeq: 10,
        lastMessageSeq: 20,
        unreadCount: 2,
        createdAt: now,
        updatedAt: now,
      ),
      messages: messages,
      unreadFromSeq: 10,
    );
    final read = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: ChatTimeline(
              state: state,
              unreadMessageId: state.firstUnreadMessageId,
              onReadUpTo: read.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // Открытие на непрочитанном не должно отмечать чат прочитанным.
    expect(read, isEmpty);
    expect(find.text('New messages'), findsOneWidget);
    expect(find.text('message 10'), findsOneWidget);
    expect(find.text('To latest'), findsOneWidget);

    await tester.tap(find.text('To latest'));
    await tester.pumpAndSettle();

    expect(read.last, 20);
  });

  testWidgets('keeps the divider when unread content is already at the end', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 11, 26);
    final state = ChatState(
      chatId: 'c1',
      chat: Chat(
        id: 'c1',
        hostId: 'local',
        title: 'Chat',
        lastReadSeq: 1,
        lastMessageSeq: 2,
        unreadCount: 1,
        createdAt: now,
        updatedAt: now,
      ),
      messages: [
        ChatMessage(
          id: 'u1',
          chatId: 'c1',
          seq: 1,
          role: MessageRole.user,
          text: 'request',
          createdAt: now,
        ),
        ChatMessage(
          id: 'a1',
          chatId: 'c1',
          seq: 2,
          role: MessageRole.assistant,
          text: 'answer',
          createdAt: now,
        ),
      ],
      unreadFromSeq: 1,
    );
    final read = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            height: 320,
            child: ChatTimeline(
              state: state,
              unreadMessageId: state.firstUnreadMessageId,
              onReadUpTo: read.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(read, isEmpty);
    expect(find.text('New messages'), findsOneWidget);
  });

  testWidgets('does not mark read while another tab is visible', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 11, 26);
    final state = ChatState(
      chatId: 'c1',
      chat: Chat(
        id: 'c1',
        hostId: 'local',
        title: 'Chat',
        lastMessageSeq: 1,
        createdAt: now,
        updatedAt: now,
      ),
      messages: [
        ChatMessage(
          id: 'm1',
          chatId: 'c1',
          seq: 1,
          role: MessageRole.assistant,
          text: 'message',
          createdAt: now,
        ),
      ],
    );
    final read = <int>[];

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: VisibleChatScope(
          chatId: 'other',
          child: Scaffold(
            body: SizedBox(
              height: 320,
              child: ChatTimeline(state: state, onReadUpTo: read.add),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(read, isEmpty);
  });
}
