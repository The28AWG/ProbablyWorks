import 'package:app_ui/app_ui.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_composer.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_meta_bar.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_view.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/test_support/golden_fonts.dart';
import 'package:probably_works/test_support/seeded_chat_bloc.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

const _title = 'A long-ish chat title for the header';

class _App extends StatelessWidget {
  const _App(this.child);

  final Widget child;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: child),
  );
}

/// Чат с историей, рабочей папкой, моделью и заполненным контекстом: в композере появляются все чипы.
/// С сообщением композер внизу; пустой чат показывает приветствие с композером по центру.
ChatState _loaded() => ChatState(
  chatId: 'c',
  messages: [
    ChatMessage(
      id: 'm1',
      chatId: 'c',
      seq: 1,
      role: MessageRole.user,
      createdAt: DateTime(2026),
      text: 'Привет',
    ),
  ],
  chat: Chat(
    id: 'c',
    hostId: 'local',
    title: _title,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    model: 'openai/gpt-4o-mini',
    workspace: '/home/user/projects/some-workspace',
    policyMode: PolicyMode.yolo,
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
  promptTokens: 40000,
  contextLimit: 128000,
);

/// Карточка композера: первый DecoratedBox внутри композера (настоящего или скелета).
Rect _composerCard(WidgetTester tester, Type composer) => tester.getRect(
  find
      .descendant(
        of: find.byType(composer),
        matching: find.byType(DecoratedBox),
      )
      .first,
);

class _RealComposer extends StatelessWidget {
  const _RealComposer(this.controller);

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) => ChatComposer(
    state: const ChatState(),
    controller: controller,
    attachments: const [],
    dragging: false,
    workspace: null,
    policy: PolicyMode.ask,
    settings: ChatMetaBar(
      hosts: const [],
      hostId: 'local',
      onHostSelected: _noopString,
      workspace: null,
      onPickWorkspace: _noop,
      modelLabel: null,
      onPickModel: _noop,
      contextFraction: null,
      onOpenContext: _noop,
      running: false,
    ),
    onAttach: _noop,
    onPickWorkspace: _noop,
    onPolicySelected: _noopPolicy,
    onRemoveAttachment: _noopIndex,
    onSubmit: _noopSend,
    onStop: _noop,
  );

  static void _noop() {
    return;
  }

  static void _noopString(String _) {
    return;
  }

  static void _noopPolicy(PolicyMode _) {
    return;
  }

  static void _noopIndex(int _) {
    return;
  }

  static void _noopSend(bool _) {
    return;
  }
}

void main() {
  setUpAll(GoldenFonts.load);

  testWidgets(
    'the model chip shows no spinner while the list loads if the saved name is known',
    (tester) async {
      final bloc = SeededChatBloc(
        _loaded().copyWith(
          catalog: const ModelCatalogState(
            loading: true,
            saved: {
              'openai/gpt-4o-mini': SavedModel(
                id: 'openai/gpt-4o-mini',
                name: 'GPT-4o mini',
              ),
            },
          ),
        ),
      );
      addTearDown(bloc.close);
      await tester.pumpWidget(
        _App(
          BlocProvider<ChatBloc>.value(value: bloc, child: const ChatBody()),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );

  testWidgets(
    'the model chip shows a spinner while the list loads if the model name is unknown',
    (tester) async {
      final bloc = SeededChatBloc(
        _loaded().copyWith(catalog: const ModelCatalogState(loading: true)),
      );
      addTearDown(bloc.close);
      await tester.pumpWidget(
        _App(
          BlocProvider<ChatBloc>.value(value: bloc, child: const ChatBody()),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    },
  );

  testWidgets(
    'a new chat before its draft is ready shows no spinner and no skeleton',
    (tester) async {
      final bloc = SeededChatBloc(const ChatState());
      addTearDown(bloc.close);
      await tester.pumpWidget(
        _App(
          BlocProvider<ChatBloc>.value(value: bloc, child: const ChatBody()),
        ),
      );

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(ComposerSkeleton), findsNothing);
    },
  );

  testWidgets('composer skeleton has the same card size as the real composer', (
    tester,
  ) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      _App(SizedBox(width: 900, child: _RealComposer(controller))),
    );
    final real = _composerCard(tester, ChatComposer);

    await tester.pumpWidget(
      const _App(SizedBox(width: 900, child: ComposerSkeleton())),
    );
    final skeleton = _composerCard(tester, ComposerSkeleton);

    expect(skeleton.top, closeTo(real.top, 0.5));
    expect(skeleton.height, closeTo(real.height, 0.5));
    expect(skeleton.width, closeTo(real.width, 0.5));
  });

  testWidgets(
    'a seeded chat shows its real header and composer while the timeline loads',
    (tester) async {
      await tester.pumpWidget(
        _App(
          BlocProvider<ChatBloc>.value(
            value: SeededChatBloc(_loaded().copyWith(loading: true)),
            child: const ChatBody(),
          ),
        ),
      );
      // Скелета нет: шапка и композер настоящие, спиннер только в ленте.
      expect(find.byType(ComposerSkeleton), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text(_title), findsOneWidget);
      final seededComposer = _composerCard(tester, ChatComposer);
      final seededHeader = tester.getRect(find.text(_title));

      await tester.pumpWidget(
        _App(
          BlocProvider<ChatBloc>.value(
            value: SeededChatBloc(_loaded()),
            child: const ChatBody(),
          ),
        ),
      );
      await tester.pump();
      final loadedComposer = _composerCard(tester, ChatComposer);
      final loadedHeader = tester.getRect(find.text(_title));

      expect(seededComposer, loadedComposer);
      expect(seededHeader, loadedHeader);
    },
  );

  testWidgets(
    'while loading, header and composer stay where the loaded chat puts them',
    (tester) async {
      await tester.pumpWidget(
        _App(
          BlocProvider<ChatBloc>.value(
            value: SeededChatBloc(const ChatState(chatId: 'c', loading: true)),
            child: const ChatBody(),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      final loadingComposer = _composerCard(tester, ComposerSkeleton);
      final loadingHeader = tester.getRect(find.text('\u00A0'));

      await tester.pumpWidget(
        _App(
          BlocProvider<ChatBloc>.value(
            value: SeededChatBloc(_loaded()),
            child: const ChatBody(),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final loadedComposer = _composerCard(tester, ChatComposer);
      final loadedHeader = tester.getRect(find.text(_title));

      expect(loadingComposer.top, closeTo(loadedComposer.top, 0.5));
      expect(loadingComposer.height, closeTo(loadedComposer.height, 0.5));
      expect(loadingHeader.top, closeTo(loadedHeader.top, 0.5));
      expect(loadingHeader.height, closeTo(loadedHeader.height, 0.5));
      // Название в шапке центрировано, заглушка тоже должна быть по центру.
      expect(loadingHeader.center.dx, closeTo(loadedHeader.center.dx, 0.5));
    },
  );
}
