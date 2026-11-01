import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/core/domain/host.dart';
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
    this.policy = PolicyMode.ask,
    this.running = false,
    this.onPolicySelected,
    this.onHostSelected,
    this.workspace,
    this.onPickWorkspace,
    this.contextFraction,
    this.onOpenContext,
    this.noModel = false,
  });

  final PolicyMode policy;
  final bool running;
  final ValueChanged<PolicyMode>? onPolicySelected;
  final ValueChanged<String>? onHostSelected;
  final String? workspace;
  final VoidCallback? onPickWorkspace;
  final double? contextFraction;
  final VoidCallback? onOpenContext;
  final bool noModel;

  static void _noopPolicy(PolicyMode _) {
    return;
  }

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
    onPickModel: _noop,
    policy: policy,
    onPolicySelected: onPolicySelected ?? _noopPolicy,
    contextFraction: contextFraction,
    onOpenContext: onOpenContext ?? _noop,
    running: running,
  );
}

void main() {
  setUpAll(GoldenFonts.load);

  for (final brightness in Brightness.values) {
    testWidgets('chat meta bar states (${brightness.name})', (tester) async {
      await tester.binding.setSurfaceSize(const Size(960, 140));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _TestHost(
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _TestChatMetaBar(workspace: '/home/me/projects/app', contextFraction: 0.42),
              const SizedBox(height: 16),
              _TestChatMetaBar(policy: PolicyMode.yolo, contextFraction: 0.93),
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

  testWidgets('policy menu explains both modes and reports the choice', (
    tester,
  ) async {
    PolicyMode? picked;
    await tester.pumpWidget(
      _TestHost(_TestChatMetaBar(onPolicySelected: (m) => picked = m), AppTheme.light),
    );
    await tester.tap(find.text('Ask'));
    await tester.pumpAndSettle();
    expect(
      find.text('Ask before risky commands and any file edits.'),
      findsOneWidget,
    );
    expect(
      find.text(
        'Run commands and edits without asking. Denied commands are still blocked.',
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Auto-approve').last);
    await tester.pumpAndSettle();
    expect(picked, PolicyMode.yolo);
  });

  testWidgets('host cannot be changed while the agent is running', (
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

  testWidgets('host menu lists hosts and reports the selection', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      _TestHost(_TestChatMetaBar(onHostSelected: (id) => picked = id), AppTheme.light),
    );
    await tester.tap(find.text('This computer'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('prod-server'));
    await tester.pumpAndSettle();
    expect(picked, 'prod');
  });

  testWidgets('folder and context chips open their editors', (tester) async {
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
    expect(find.text('app'), findsOneWidget);
    expect(find.text('42%'), findsOneWidget);
    await tester.tap(find.text('app'));
    await tester.tap(find.text('42%'));
    await tester.pump();
    expect(pickedFolder, 1);
    expect(openedContext, 1);
  });

  testWidgets('folder cannot be changed while the agent is running', (
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

  testWidgets('empty folder shows only its icon and missing usage a dash', (
    tester,
  ) async {
    await tester.pumpWidget(_TestHost(_TestChatMetaBar(), AppTheme.light));
    expect(find.byIcon(Icons.folder_outlined), findsOneWidget);
    expect(find.text('not set'), findsNothing);
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('icon-only folder chip is as tall as the chips with text', (
    tester,
  ) async {
    await tester.pumpWidget(_TestHost(_TestChatMetaBar(), AppTheme.light));
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
    expect(folder.width, folder.height);

    final chip = tester.getRect(
      find.ancestor(
        of: find.byIcon(Icons.folder_outlined),
        matching: find.byType(InkWell),
      ),
    );
    final icon = tester.getRect(find.byIcon(Icons.folder_outlined));
    expect(icon.center.dx, closeTo(chip.center.dx, 0.5));
    expect(icon.center.dy, closeTo(chip.center.dy, 0.5));
  });

  testWidgets('missing model asks to choose one', (tester) async {
    await tester.pumpWidget(_TestHost(_TestChatMetaBar(noModel: true), AppTheme.light));
    expect(find.text('Claude Sonnet'), findsNothing);
    expect(find.text('Choose model'), findsOneWidget);
  });
}
