import 'package:app_ui/app_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_composer.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_density.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_message_tile.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_timeline.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';

ChatMessage _user(String text) => ChatMessage(
  id: 'u',
  chatId: 'c',
  seq: 1,
  role: MessageRole.user,
  createdAt: DateTime(2026),
  text: text,
);

ChatState _state({bool running = false}) => ChatState(
  chatId: 'c',
  chat: Chat(
    id: 'c',
    hostId: 'local',
    title: 'Chat',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  ),
  messages: [_user('Fix the login')],
  isRunning: running,
);

class _TestApp extends StatelessWidget {
  const _TestApp(this.child);

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

void main() {
  testWidgets('user message opens edit on tap without hover actions', (
    tester,
  ) async {
    var edits = 0;
    await tester.pumpWidget(
      _TestApp(
        ChatMessageTile(
          message: _user('Fix the login'),
          editable: true,
          onEdit: () => edits++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ChatMessageTile)),
    );

    expect(find.byIcon(Icons.delete_outline), findsNothing);
    expect(find.byTooltip(l10n.messageDeleteAfter), findsNothing);
    expect(find.byTooltip(l10n.messageEdit), findsNothing);
    expect(find.byTooltip(l10n.commonCopy), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: const Offset(-10, -10));
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Fix the login')));
    await tester.pumpAndSettle();
    expect(find.byType(IconButton), findsNothing);

    await tester.tap(find.text('Fix the login'));
    await tester.pump();
    expect(edits, 1);
  });

  testWidgets('an unsent edit replaces the bubble text and tints it', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestApp(
        ChatMessageTile(
          message: _user('Fix the login'),
          editable: true,
          editText: 'Use the new token',
          onEdit: _noop,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(ChatMessageTile));
    final l10n = AppLocalizations.of(context);
    final decoration =
        tester
                .widget<DecoratedBox>(
                  find
                      .ancestor(
                        of: find.text('Use the new token'),
                        matching: find.byType(DecoratedBox),
                      )
                      .first,
                )
                .decoration
            as BoxDecoration;

    expect(find.text('Use the new token'), findsOneWidget);
    expect(find.text('Fix the login'), findsNothing);
    expect(find.text(l10n.messageEditDraft), findsNothing);
    expect(decoration.color, Theme.of(context).colorScheme.primaryContainer);
  });

  testWidgets('editing replaces the user bubble with the composer', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _TestApp(
        SizedBox(
          height: 500,
          child: ChatDensityScope(
            density: ChatDensity.regular,
            child: ChatTimeline(
              state: _state(),
              editingMessageId: 'u',
              messageEditor: const Text('editing-marker'),
              onEditMessage: _ignoreMessage,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('editing-marker'), findsOneWidget);
    expect(find.text('Fix the login'), findsNothing);
  });

  testWidgets('edit composer sends and hides stop and cancel', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var sent = 0;
    await tester.pumpWidget(
      _TestApp(
        ChatDensityScope(
          density: ChatDensity.regular,
          child: ChatComposer(
            state: _state(running: true),
            controller: controller,
            attachments: const [],
            dragging: false,
            embedded: true,
            editing: true,
            hint: 'Editing restarts the turn',
            settings: const SizedBox.shrink(),
            workspace: null,
            policy: PolicyMode.ask,
            onAttach: _noop,
            onPickWorkspace: _noop,
            onPolicySelected: _noopPolicy,
            onRemoveAttachment: _noopIndex,
            onSubmit: (_) => sent++,
            onStop: _noop,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(ChatComposer)));

    expect(find.byTooltip(l10n.commonCancel), findsNothing);
    expect(find.byTooltip(l10n.composerStop), findsNothing);
    expect(find.byTooltip(l10n.composerSend), findsNothing);
    expect(find.text('Editing restarts the turn'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip(l10n.composerSend));
    await tester.pump();
    expect(sent, 1);
  });
}

void _ignoreMessage(ChatMessage _) {
  return;
}

void _noop() {
  return;
}

void _noopPolicy(PolicyMode _) {
  return;
}

void _noopIndex(int _) {
  return;
}
