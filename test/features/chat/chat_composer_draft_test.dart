import 'package:app_ui/app_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/core/data/chat_draft_store.dart';
import 'package:probably_works/core/data/chat_repository.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_composer.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_meta_bar.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_view.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/test_support/golden_fonts.dart';
import 'package:probably_works/test_support/seeded_chat_bloc.dart';

/// Запоминает, какие черновики ушли бы в БД.
class _RecordingChats implements ChatRepository {
  final saved = <String, ChatDraft>{};

  @override
  Future<void> saveDraft(String chatId, ChatDraft draft) {
    saved[chatId] = draft;
    return Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('ChatRepository is not available in widget tests');
}

/// Блок, которому тест может передать новое состояние, как это делает загрузка чата.
class _SwitchableBloc extends SeededChatBloc {
  _SwitchableBloc(super.seed, {super.drafts});

  void push(ChatState state) => emit(state);
}

final _hosts = [
  Host(
    id: 'local',
    name: 'Local',
    kind: HostKind.local,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  ),
];

Chat _chat(String id) => Chat(
  id: id,
  hostId: 'local',
  title: 'Chat $id',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

ChatState _loaded(String id, {String draft = '', int draftId = 0}) => ChatState(
  chatId: id,
  chat: _chat(id),
  hosts: _hosts,
  draft: draft,
  draftId: draftId,
);

ChatState _loading(String id) =>
    ChatState(chatId: id, chat: _chat('c1'), hosts: _hosts, loading: true);

class _App extends StatelessWidget {
  const _App(this.bloc);

  final ChatBloc bloc;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: BlocProvider<ChatBloc>.value(value: bloc, child: const ChatBody()),
    ),
  );
}

Finder _input() => find.descendant(
  of: find.byType(ChatComposer),
  matching: find.byType(TextField),
);

bool _composerIgnoring(WidgetTester tester) => tester
    .widget<IgnorePointer>(
      find
          .ancestor(
            of: find.byType(ChatComposer),
            matching: find.byType(IgnorePointer),
          )
          .first,
    )
    .ignoring;

void main() {
  setUpAll(GoldenFonts.load);

  testWidgets(
    'text typed in the composer is saved as the draft of the open chat',
    (tester) async {
      final chats = _RecordingChats();
      final drafts = ChatDraftStore(chats);
      final bloc = _SwitchableBloc(_loaded('c1'), drafts: drafts);
      addTearDown(bloc.close);
      await tester.pumpWidget(_App(bloc));
      await tester.pump();

      await tester.enterText(_input(), 'черновик');
      await tester.pump();
      await drafts.flush();

      expect(chats.saved['c1']?.text, 'черновик');
    },
  );

  testWidgets('the composer shows the draft of the chat that is opened', (
    tester,
  ) async {
    final drafts = ChatDraftStore(_RecordingChats());
    final bloc = _SwitchableBloc(_loaded('c1'), drafts: drafts);
    addTearDown(bloc.close);
    await tester.pumpWidget(_App(bloc));
    await tester.pump();

    bloc.push(_loaded('c2', draft: 'черновик второго', draftId: 1));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(_input()).controller?.text,
      'черновик второго',
    );
    await drafts.flush();
  });

  testWidgets('attachments of the draft are shown in the composer', (
    tester,
  ) async {
    final drafts = ChatDraftStore(_RecordingChats());
    final bloc = _SwitchableBloc(_loaded('c1'), drafts: drafts);
    addTearDown(bloc.close);
    await tester.pumpWidget(_App(bloc));
    await tester.pump();

    bloc.push(
      ChatState(
        chatId: 'c1',
        chat: _chat('c1'),
        hosts: _hosts,
        attachments: const [
          AttachmentRef(
            name: 'notes.txt',
            mode: AttachmentMode.attach,
            content: 'x',
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('notes.txt'), findsOneWidget);
    await drafts.flush();
  });

  testWidgets('composer is locked and shows the spinner while the chat loads', (
    tester,
  ) async {
    final drafts = ChatDraftStore(_RecordingChats());
    final bloc = _SwitchableBloc(_loaded('c1'), drafts: drafts);
    addTearDown(bloc.close);
    await tester.pumpWidget(_App(bloc));
    await tester.pump();

    // Спиннер анимируется бесконечно, поэтому кадры считаем, а не ждём полной тишины.
    bloc.push(_loading('c2'));
    await tester.pump();
    await tester.pump();
    // Спиннер ленты и спиннер ожидания модели в чипе: модель по умолчанию ещё не прочитана.
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byType(ChatMetaBar),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(_composerIgnoring(tester), isTrue);

    bloc.push(_loaded('c2'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(_composerIgnoring(tester), isFalse);
    await drafts.flush();
  });
}
