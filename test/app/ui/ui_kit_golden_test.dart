import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

import 'package:probably_works/test_support/golden_fonts.dart';

/// Визуальная регрессия ключевых компонентов kit в light и dark.
/// Обновить эталоны: `flutter test --update-goldens test/app/ui/ui_kit_golden_test.dart`.
class _KitGallery extends StatelessWidget {
  const _KitGallery();

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.all(AppSpacing.lg),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppBanner(
          title: 'Heads up',
          message: 'Context is almost full',
          tone: AppTone.warning,
        ),
        const SizedBox(height: AppSpacing.md),
        const Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            StatusChip(label: 'Online', tone: AppTone.success),
            StatusChip(label: 'Running', tone: AppTone.progress, pulse: false),
            StatusChip(label: 'Failed', tone: AppTone.danger),
            StatusChip(label: 'Waiting', tone: AppTone.waiting),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        const ActionCard(
          title: 'Approve command?',
          icon: Icons.lock_clock_outlined,
          tone: AppTone.waiting,
          actions: [TextButton(onPressed: null, child: Text('Deny'))],
          children: [
            CodeBlock(text: 'flutter test', maxHeight: 120),
            CommandOutput(
              text:
                  '\x1b[1;32m✓\x1b[0m flutter analyze\n'
                  '\x1b[33mwarning\x1b[0m: unused import\n'
                  '\x1b[31merror\x1b[0m: 1 issue found',
              exitCode: 1,
              maxHeight: 120,
            ),
            DiffView(diff: '- old line\n+ new line'),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        const ContextUsageBar(label: 'Context 72%', fraction: 0.72),
        const SizedBox(height: AppSpacing.md),
        AppChoiceGroup<String>(
          options: _choiceOptions,
          selected: 'ask',
          onChanged: _ignoreChoice,
        ),
        const SizedBox(height: AppSpacing.md),
        const AppMarkdown(data: _markdownSample),
      ],
    ),
  );
}

const _choiceOptions = [
  AppChoiceOption(
    value: 'ask',
    title: 'Ask',
    subtitle: 'Confirm each command',
    icon: Icons.front_hand_outlined,
  ),
  AppChoiceOption(
    value: 'yolo',
    title: 'Auto',
    subtitle: 'Run without asking',
    icon: Icons.bolt_outlined,
  ),
];

void _ignoreChoice(String _) {
  return;
}

const _markdownSample = '''
## Heading two

Paragraph with `inline code`, a [link](https://example.com) and **bold** text.

> Quoted note from the agent.

- first item
- second item

| Name | Value |
| ---- | ----- |
| mode | ask   |

```dart
final greeting = 'hello';
```
''';

void main() {
  setUpAll(GoldenFonts.load);

  for (final brightness in Brightness.values) {
    testWidgets('kit gallery golden ${brightness.name}', (tester) async {
      await tester.binding.setSurfaceSize(const Size(560, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: brightness == Brightness.light
              ? AppTheme.light
              : AppTheme.dark,
          locale: const Locale('en'),
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: const _KitGallery(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/ui_kit_${brightness.name}.png'),
      );
    });
  }
}
