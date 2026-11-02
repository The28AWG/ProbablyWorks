import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_composer.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

ChatState _state({bool running = false}) => ChatState(
  chatId: 'c',
  chat: Chat(
    id: 'c',
    hostId: 'local',
    title: 'Chat',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  ),
  hosts: const [],
  messages: const [],
  isRunning: running,
);

class _Harness extends StatefulWidget {
  const _Harness({
    this.running = false,
    this.onPickWorkspace,
    this.onPolicySelected,
    this.onAttach,
  });

  final bool running;
  final VoidCallback? onPickWorkspace;
  final ValueChanged<PolicyMode>? onPolicySelected;
  final VoidCallback? onAttach;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: ChatComposer(
          state: _state(running: widget.running),
          controller: _controller,
          attachments: const [],
          dragging: false,
          settings: const SizedBox.shrink(),
          workspace: '/home/me/projects/app',
          policy: PolicyMode.ask,
          onAttach: widget.onAttach ?? () {},
          onPickWorkspace: widget.onPickWorkspace ?? () {},
          onPolicySelected: widget.onPolicySelected ?? (_) {},
          onRemoveAttachment: (_) {},
          onSubmit: (_) {},
          onStop: () {},
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('composer has one add button and no hint line', (tester) async {
    await tester.pumpWidget(const _Harness());
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(ChatComposer)));

    expect(find.byTooltip(l10n.composerAddTooltip), findsOneWidget);
    // Прикрепление живёт в меню «+», отдельной кнопки и строки подсказок под полем больше нет.
    expect(find.byTooltip(l10n.composerAttach), findsNothing);
    expect(find.textContaining('Shift+Enter'), findsNothing);
    expect(find.textContaining('Shift'), findsNothing);
  });

  testWidgets('add menu offers attach, working folder and execution mode', (
    tester,
  ) async {
    var attached = 0;
    await tester.pumpWidget(_Harness(onAttach: () => attached++));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(ChatComposer)));

    await tester.tap(find.byTooltip(l10n.composerAddTooltip));
    await tester.pumpAndSettle();
    expect(find.text(l10n.composerAttach), findsOneWidget);
    expect(find.text(l10n.chatWorkspaceLabel), findsOneWidget);
    expect(find.text('app'), findsOneWidget);
    expect(find.text(l10n.composerModeLabel), findsOneWidget);

    await tester.tap(find.text(l10n.composerAttach));
    await tester.pumpAndSettle();
    expect(attached, 1);
  });

  testWidgets('execution mode submenu switches the policy', (tester) async {
    PolicyMode? picked;
    await tester.pumpWidget(
      _Harness(onPolicySelected: (mode) => picked = mode),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(ChatComposer)));

    await tester.tap(find.byTooltip(l10n.composerAddTooltip));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.composerModeLabel));
    await tester.pumpAndSettle();
    expect(find.text(l10n.policyAsk), findsOneWidget);
    expect(find.text(l10n.policyYolo), findsOneWidget);

    await tester.tap(find.text(l10n.policyYolo));
    await tester.pumpAndSettle();
    expect(picked, PolicyMode.yolo);
  });

  testWidgets('working folder cannot change while the agent runs', (
    tester,
  ) async {
    var picked = 0;
    await tester.pumpWidget(
      _Harness(running: true, onPickWorkspace: () => picked++),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(ChatComposer)));

    await tester.tap(find.byTooltip(l10n.composerAddTooltip));
    await tester.pumpAndSettle();
    final item = tester.widget<MenuItemButton>(
      find.ancestor(
        of: find.text(l10n.chatWorkspaceLabel),
        matching: find.byType(MenuItemButton),
      ),
    );
    expect(item.onPressed, isNull);
    expect(picked, 0);
  });
}
