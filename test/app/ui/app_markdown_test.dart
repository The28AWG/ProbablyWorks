import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

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
    home: Scaffold(body: child),
  );
}

/// Коэффициент контраста WCAG между двумя цветами (от 1 до 21).
double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Ищет первый TextSpan с нужным фрагментом текста.
TextSpan _spanContaining(InlineSpan root, String fragment) {
  TextSpan? found;
  void visit(InlineSpan span) {
    if (found != null) return;
    if (span is TextSpan) {
      if ((span.text ?? '').contains(fragment)) {
        found = span;
        return;
      }
      span.children?.forEach(visit);
    }
  }

  visit(root);
  return found!;
}

const _sample = '''
# Title

Plain paragraph with `inline` code and [a link](https://example.com).

> quoted line

| a | b |
| - | - |
| 1 | 2 |

```dart
final x = 'value';
```
''';

void main() {
  for (final brightness in Brightness.values) {
    final theme = brightness == Brightness.light
        ? AppTheme.light
        : AppTheme.dark;
    final name = brightness.name;

    testWidgets('AppMarkdown text uses theme colors ($name)', (tester) async {
      await tester.pumpWidget(
        _TestHost(const AppMarkdown(data: 'Plain paragraph text'), theme),
      );
      final rich = tester.widget<RichText>(
        find.byWidgetPredicate(
          (w) =>
              w is RichText &&
              w.text.toPlainText().contains('Plain paragraph text'),
        ),
      );
      expect(rich.text.style?.color, theme.colorScheme.onSurface);
      expect(rich.text.style?.fontFamily, 'Inter');
    });

    testWidgets('AppMarkdown link uses theme primary ($name)', (tester) async {
      await tester.pumpWidget(
        _TestHost(
          const AppMarkdown(data: 'see [docs](https://example.com)'),
          theme,
        ),
      );
      final rich = tester.widget<RichText>(
        find.byWidgetPredicate(
          (w) => w is RichText && w.text.toPlainText().contains('docs'),
        ),
      );
      final span = _spanContaining(rich.text, 'docs');
      expect(span.style?.color, theme.colorScheme.primary);
    });

    testWidgets(
      'AppMarkdown link around a widget does not need Scaffold Material ($name)',
      (tester) async {
        // Inline-код — WidgetSpan. Пакет оборачивает его в InkWell из
        // package:flutter/material.dart, которому нужен Material того же пакета.
        await tester.pumpWidget(
          _TestHost(
            const AppMarkdown(data: 'see [`docs`](https://example.com)'),
            theme,
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('docs'), findsOneWidget);
      },
    );

    testWidgets('AppMarkdown image does not need Scaffold Material ($name)', (
      tester,
    ) async {
      // Картинка вне ссылки тоже InkWell из package:flutter/material.dart.
      await tester.pumpWidget(
        _TestHost(const AppMarkdown(data: '![alt](missing.png)'), theme),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('AppMarkdown inline code is a rounded chip ($name)', (
      tester,
    ) async {
      await tester.pumpWidget(
        _TestHost(const AppMarkdown(data: 'call `foo()` now'), theme),
      );
      final text = tester.widget<Text>(find.text('foo()'));
      expect(text.style?.fontFamily, AppTheme.monoFamily);
      expect(text.style?.color, theme.colorScheme.onSurface);

      final chip = tester.widget<DecoratedBox>(
        find.ancestor(
          of: find.text('foo()'),
          matching: find.byType(DecoratedBox),
        ),
      );
      final decoration = chip.decoration as BoxDecoration;
      expect(decoration.color, theme.colorScheme.surfaceContainerHighest);
      expect(decoration.borderRadius, AppRadius.smAll);
      // Фон inline-кода должен заметно отличаться от фона страницы.
      expect(
        _contrast(decoration.color!, theme.colorScheme.surface),
        greaterThanOrEqualTo(1.2),
      );
    });

    testWidgets('AppMarkdown renders every block kind ($name)', (tester) async {
      await tester.pumpWidget(
        _TestHost(const AppMarkdown(data: _sample), theme),
      );
      expect(tester.takeException(), isNull);
      expect(find.textContaining('Plain paragraph'), findsWidgets);
    });
  }
}
