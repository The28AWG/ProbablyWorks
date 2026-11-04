import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/ui/app_tone.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_density.dart';
import 'package:probably_works/features/chat/presentation/widgets/chat_meta_bar.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/test_support/golden_fonts.dart';

final _hosts = [
  Host(
    id: 'local',
    name: 'Local',
    kind: HostKind.local,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  ),
  Host(
    id: 'prod',
    name: 'prod-server',
    kind: HostKind.ssh,
    address: 'prod.example.com',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  ),
];

class _TestHost extends StatelessWidget {
  const _TestHost(this.child, this.theme);

  final Widget child;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: theme,
    locale: const Locale('en'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  );
}

class _TestChatMetaBar extends StatelessWidget {
  const _TestChatMetaBar({
    this.running = false,
    this.onHostSelected,
    this.workspace,
    this.onPickWorkspace,
    this.contextFraction,
    this.onOpenContext,
    this.noModel = false,
    this.modelUnavailable = false,
    this.modelLoading = false,
    this.modelPending = false,
  });

  final bool running;
  final ValueChanged<String>? onHostSelected;
  final String? workspace;
  final VoidCallback? onPickWorkspace;
  final double? contextFraction;
  final VoidCallback? onOpenContext;
  final bool noModel;
  final bool modelUnavailable;
  final bool modelLoading;
  final bool modelPending;

  static void _noopHost(String _) {
    return;
  }

  static void _noop() {
    return;
  }

  @override
  Widget build(BuildContext context) => ChatMetaBar(
    hosts: _hosts,
    hostId: 'local',
    onHostSelected: onHostSelected ?? _noopHost,
    workspace: workspace,
    onPickWorkspace: onPickWorkspace ?? _noop,
    modelLabel: noModel ? null : 'Claude Sonnet',
    modelUnavailable: modelUnavailable,
    modelLoading: modelLoading,
    modelPending: modelPending,
    onPickModel: _noop,
    contextFraction: contextFraction,
    onOpenContext: onOpenContext ?? _noop,
    running: running,
  );
}

/// `testWidgets`, который эмулирует desktop (Linux): подписи Local Host и поведение зависят от платформы,
/// а по умолчанию тесты идут как Android. Override сбрасывается внутри тела, потому что flutter_test
/// проверяет его до `tearDown`.
void _desktopWidgetTest(String description, WidgetTesterCallback body) {
  // Проверки лежат в body, которое передаёт вызывающий тест; DCM не видит их через обёртку.
  // ignore: missing-test-assertion
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  setUpAll(GoldenFonts.load);

  for (final brightness in Brightness.values) {
    _desktopWidgetTest('chat meta bar states (${brightness.name})', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(960, 140));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _TestHost(
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _TestChatMetaBar(
                workspace: '/home/me/projects/app',
                contextFraction: 0.42,
              ),
              const SizedBox(height: 16),
              _TestChatMetaBar(contextFraction: 0.93),
            ],
          ),
          brightness == Brightness.light ? AppTheme.light : AppTheme.dark,
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/chat_meta_bar_${brightness.name}.png'),
      );
    });
  }

  _desktopWidgetTest(
    'there is no execution mode chip: it lives in the composer menu',
    (tester) async {
      await tester.pumpWidget(
        _TestHost(
          _TestChatMetaBar(workspace: '/home/me/projects/app'),
          AppTheme.light,
        ),
      );
      expect(find.text('Ask'), findsNothing);
      expect(find.text('Auto-approve'), findsNothing);
    },
  );

  _desktopWidgetTest('host cannot be changed while the agent is running', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      _TestHost(
        _TestChatMetaBar(running: true, onHostSelected: (id) => picked = id),
        AppTheme.light,
      ),
    );
    final menu = tester.widget<PopupMenuButton<String>>(
      find.byType(PopupMenuButton<String>),
    );
    expect(menu.enabled, isFalse);
    await tester.tap(find.text('This computer'));
    await tester.pumpAndSettle();
    expect(find.text('prod-server'), findsNothing);
    expect(picked, isNull);
  });

  _desktopWidgetTest('host menu lists hosts and reports the selection', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      _TestHost(
        _TestChatMetaBar(onHostSelected: (id) => picked = id),
        AppTheme.light,
      ),
    );
    await tester.tap(find.text('This computer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('prod-server'));
    await tester.pumpAndSettle();
    expect(picked, 'prod');
  });

  _desktopWidgetTest('folder and context chips open their editors', (
    tester,
  ) async {
    var pickedFolder = 0;
    var openedContext = 0;
    await tester.pumpWidget(
      _TestHost(
        _TestChatMetaBar(
          workspace: '/home/me/projects/app',
          contextFraction: 0.42,
          onPickWorkspace: () => pickedFolder++,
          onOpenContext: () => openedContext++,
        ),
        AppTheme.light,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('app'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    await tester.tap(find.text('app'));
    await tester.tap(find.text('42%'));
    await tester.pump();
    expect(pickedFolder, 1);
    expect(openedContext, 1);
  });

  _desktopWidgetTest('folder cannot be changed while the agent is running', (
    tester,
  ) async {
    var pickedFolder = 0;
    await tester.pumpWidget(
      _TestHost(
        _TestChatMetaBar(
          running: true,
          workspace: '/home/me/projects/app',
          onPickWorkspace: () => pickedFolder++,
        ),
        AppTheme.light,
      ),
    );
    await tester.tap(find.text('app'));
    await tester.pump();
    expect(pickedFolder, 0);
  });

  _desktopWidgetTest('folder chip is absent until a folder is assigned', (
    tester,
  ) async {
    await tester.pumpWidget(_TestHost(_TestChatMetaBar(), AppTheme.light));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.folder_outlined), findsNothing);

    await tester.pumpWidget(
      _TestHost(
        _TestChatMetaBar(workspace: '/home/me/projects/app'),
        AppTheme.light,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
  });

  _desktopWidgetTest('context chip is absent until the model reports usage', (
    tester,
  ) async {
    await tester.pumpWidget(_TestHost(_TestChatMetaBar(), AppTheme.light));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.data_usage), findsNothing);
    expect(find.text('—'), findsNothing);

    await tester.pumpWidget(
      _TestHost(_TestChatMetaBar(contextFraction: 0.1), AppTheme.light),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.data_usage), findsOneWidget);
  });

  _desktopWidgetTest('folder chip is as tall as the chips with text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestHost(
        _TestChatMetaBar(workspace: '/home/me/projects/app'),
        AppTheme.light,
      ),
    );
    await tester.pumpAndSettle();
    final folder = tester.getSize(
      find.ancestor(
        of: find.byIcon(Icons.folder_outlined),
        matching: find.byType(InkWell),
      ),
    );
    final model = tester.getSize(
      find.ancestor(
        of: find.text('Claude Sonnet'),
        matching: find.byType(InkWell),
      ),
    );
    expect(folder.height, model.height);
  });

  _desktopWidgetTest('missing model asks to choose one', (tester) async {
    await tester.pumpWidget(
      _TestHost(_TestChatMetaBar(noModel: true), AppTheme.light),
    );
    expect(find.text('Claude Sonnet'), findsNothing);
    expect(find.text('Choose model'), findsOneWidget);
  });

  _desktopWidgetTest('pending model is neutral with a spinner, not a warning', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestHost(
        _TestChatMetaBar(noModel: true, modelPending: true),
        AppTheme.light,
      ),
    );
    await tester.pump();
    final element = tester.element(find.byType(ChatMetaBar));
    expect(find.text('Choose model'), findsNothing);
    expect(
      tester.widget<Icon>(find.byIcon(Icons.memory)).color,
      isNot(toneColors(element, AppTone.warning).foreground),
    );
    expect(
      find.descendant(
        of: find.byType(ChatMetaBar),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
  });

  _desktopWidgetTest('unavailable model keeps its name with a ! marker', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestHost(_TestChatMetaBar(modelUnavailable: true), AppTheme.light),
    );
    expect(find.text('! Claude Sonnet'), findsOneWidget);
    expect(find.text('Claude Sonnet'), findsNothing);
  });

  for (final brightness in Brightness.values) {
    _desktopWidgetTest(
      'chat meta bar icons on a tiny area (${brightness.name})',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(260, 60));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          _TestHost(
            ChatDensityScope(
              density: ChatDensity.tiny,
              child: _TestChatMetaBar(
                workspace: '/home/me/projects/app',
                contextFraction: 0.93,
              ),
            ),
            brightness == Brightness.light ? AppTheme.light : AppTheme.dark,
          ),
        );
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile(
            'goldens/chat_meta_bar_tiny_${brightness.name}.png',
          ),
        );
      },
    );
  }

  _desktopWidgetTest(
    'tiny density shows icons and moves values into tooltips',
    (tester) async {
      await tester.pumpWidget(
        _TestHost(
          ChatDensityScope(
            density: ChatDensity.tiny,
            child: _TestChatMetaBar(
              workspace: '/home/me/projects/app',
              contextFraction: 0.42,
            ),
          ),
          AppTheme.light,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('This computer'), findsNothing);
      expect(find.text('Claude Sonnet'), findsNothing);
      expect(find.text('app'), findsNothing);
      expect(find.text('42%'), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsNothing);
      expect(find.byTooltip('Host: This computer'), findsOneWidget);
      expect(find.byTooltip('Model: Claude Sonnet'), findsOneWidget);
      expect(find.byTooltip('Chat context: 42%'), findsOneWidget);
    },
  );

  _desktopWidgetTest('model chip shows a spinner while the first list loads', (
    tester,
  ) async {
    await tester.pumpWidget(
      _TestHost(_TestChatMetaBar(modelLoading: true), AppTheme.light),
    );
    await tester.pump();
    expect(find.text('Claude Sonnet'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ChatMetaBar),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
  });

  _desktopWidgetTest(
    'narrow row collapses chips to icons and keeps every chip inside its width',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 120));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _TestHost(
          ChatDensityScope(
            density: ChatDensity.narrow,
            child: SizedBox(
              key: const ValueKey('bounds'),
              width: 240,
              child: _TestChatMetaBar(
                workspace: '/home/me/projects/app',
                contextFraction: 0.42,
              ),
            ),
          ),
          AppTheme.light,
        ),
      );
      await tester.pumpAndSettle();

      _expectChipsInside(
        tester,
        tester.getRect(find.byKey(const ValueKey('bounds'))),
      );
      // Хост, папка и модель сворачиваются первыми: их значения уходят в подсказки, контекст остаётся видимым.
      expect(find.text('This computer'), findsNothing);
      expect(find.text('app'), findsNothing);
      expect(find.text('Claude Sonnet'), findsNothing);
      expect(find.byTooltip('Model: Claude Sonnet'), findsOneWidget);
      expect(find.text('42%'), findsOneWidget);
    },
  );

  _desktopWidgetTest('wide row keeps every label', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 120));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _TestHost(
        ChatDensityScope(
          density: ChatDensity.narrow,
          child: SizedBox(
            key: const ValueKey('bounds'),
            width: 560,
            child: _TestChatMetaBar(
              workspace: '/home/me/projects/app',
              contextFraction: 0.42,
            ),
          ),
        ),
        AppTheme.light,
      ),
    );
    await tester.pumpAndSettle();

    _expectChipsInside(
      tester,
      tester.getRect(find.byKey(const ValueKey('bounds'))),
    );
    expect(find.text('This computer'), findsOneWidget);
    expect(find.text('app'), findsOneWidget);
    expect(find.text('Claude Sonnet'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
  });
}

/// Проверяет, что каждый чип строки настроек (его `InkWell`) лежит внутри [bounds] по горизонтали.
/// Чип, вылезший за область, не виден целиком, поэтому выход за границы считается ошибкой вёрстки.
void _expectChipsInside(WidgetTester tester, Rect bounds) {
  final chips = find.descendant(
    of: find.byType(ChatMetaBar),
    matching: find.byType(InkWell),
  );
  final count = chips.evaluate().length;
  expect(count, greaterThan(0));
  for (var i = 0; i < count; i++) {
    final rect = tester.getRect(chips.at(i));
    expect(rect.left, greaterThanOrEqualTo(bounds.left - 0.5));
    expect(rect.right, lessThanOrEqualTo(bounds.right + 0.5));
  }
}
