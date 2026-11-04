import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_bloc.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_composer.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_density.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_meta_bar.dart';
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
    this.settings,
    this.density = ChatDensity.regular,
  });

  final bool running;
  final VoidCallback? onPickWorkspace;
  final ValueChanged<PolicyMode>? onPolicySelected;
  final VoidCallback? onAttach;

  /// Строка настроек под полем; по умолчанию пустая, как в тестах без строки.
  final Widget? settings;
  final ChatDensity density;

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
        child: ChatDensityScope(
          density: widget.density,
          child: ChatComposer(
            state: _state(running: widget.running),
            controller: _controller,
            attachments: const [],
            dragging: false,
            settings: widget.settings ?? const SizedBox.shrink(),
            workspace: '/home/me/projects/app',
            policy: PolicyMode.ask,
            onAttach: widget.onAttach ?? _noop,
            onPickWorkspace: widget.onPickWorkspace ?? _noop,
            onPolicySelected: widget.onPolicySelected ?? _noopPolicy,
            onRemoveAttachment: _noopIndex,
            onSubmit: _noopSend,
            onStop: _noop,
          ),
        ),
      ),
    ),
  );

  static void _noop() {
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

  testWidgets('idle empty composer shows no action button', (tester) async {
    await tester.pumpWidget(const _Harness());
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(ChatComposer)));

    expect(find.byTooltip(l10n.composerSend), findsNothing);
    expect(find.byTooltip(l10n.composerStop), findsNothing);
  });

  testWidgets('running agent with an empty field shows only stop', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness(running: true));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(ChatComposer)));

    expect(find.byTooltip(l10n.composerStop), findsOneWidget);
    expect(find.byTooltip(l10n.composerSend), findsNothing);
  });

  testWidgets('typing while the agent runs swaps stop for send (queue)', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness(running: true));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(ChatComposer)));
    await tester.enterText(find.byType(TextField).first, 'hello');
    await tester.pumpAndSettle();

    expect(find.byTooltip(l10n.composerStop), findsNothing);
    final send = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip(l10n.composerSend),
        matching: find.byType(IconButton),
      ),
    );
    expect(send.onPressed, isNotNull);
  });

  testWidgets('idle composer with text shows send and no stop', (tester) async {
    await tester.pumpWidget(const _Harness());
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(ChatComposer)));
    await tester.enterText(find.byType(TextField).first, 'hello');
    await tester.pumpAndSettle();

    expect(find.byTooltip(l10n.composerSend), findsOneWidget);
    expect(find.byTooltip(l10n.composerStop), findsNothing);
  });

  testWidgets('clearing the field while running brings stop back', (
    tester,
  ) async {
    await tester.pumpWidget(const _Harness(running: true));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(ChatComposer)));
    await tester.enterText(find.byType(TextField).first, 'hello');
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();

    expect(find.byTooltip(l10n.composerSend), findsNothing);
    expect(find.byTooltip(l10n.composerStop), findsOneWidget);
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

  testWidgets('settings chips stay inside the card on a 375px screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _Harness(
        running: true,
        density: ChatDensity.narrow,
        settings: ChatMetaBar(
          hosts: const [],
          hostId: 'local',
          onHostSelected: _noopHostSelected,
          workspace: '/home/me/projects/app',
          onPickWorkspace: _noopVoid,
          modelLabel: 'OpenAI: GPT-5 mini',
          onPickModel: _noopVoid,
          contextFraction: 0.206,
          onOpenContext: _noopVoid,
          running: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(ChatComposer)));
    _expectSettingsInsideCard(tester);

    // Кнопка отправки появляется при вводе и забирает ширину строки: проверяем и это состояние.
    await tester.enterText(find.byType(TextField).first, 'hello');
    await tester.pumpAndSettle();
    expect(find.byTooltip(l10n.composerSend), findsOneWidget);
    _expectSettingsInsideCard(tester);
  });
}

/// Карточка композера: внешний `DecoratedBox` со скруглением `lg`. Вложенные декорации скругления не используют.
bool _isCard(Widget widget) {
  if (widget is! DecoratedBox) return false;
  final decoration = widget.decoration;
  return decoration is BoxDecoration &&
      decoration.borderRadius == AppRadius.lgAll;
}

/// Проверяет, что каждый чип строки настроек (его `InkWell`) лежит внутри карточки композера по горизонтали.
/// Чип, вылезший за карточку, обрезается её краем, поэтому такой выход считается ошибкой вёрстки.
void _expectSettingsInsideCard(WidgetTester tester) {
  final card = tester.getRect(find.byWidgetPredicate(_isCard).first);
  final chips = find.descendant(
    of: find.byType(ChatMetaBar),
    matching: find.byType(InkWell),
  );
  final count = chips.evaluate().length;
  expect(count, greaterThan(0));
  for (var i = 0; i < count; i++) {
    final rect = tester.getRect(chips.at(i));
    expect(rect.left, greaterThanOrEqualTo(card.left - 0.5));
    expect(rect.right, lessThanOrEqualTo(card.right + 0.5));
  }
}

void _noopVoid() {
  return;
}

void _noopHostSelected(String _) {
  return;
}
