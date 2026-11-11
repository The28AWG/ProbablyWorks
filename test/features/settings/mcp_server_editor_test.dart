import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/settings/presentation/widgets/mcp_settings_section.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/core/domain/mcp_server.dart';

Future<void> _open(
  WidgetTester tester,
  void Function(McpServerConfig? value) onResult,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('en'),
      localizationsDelegates: appLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                final result = await showDialog<McpServerConfig>(
                  context: context,
                  builder: (_) => const McpServerEditorDialog(),
                );
                onResult(result);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('creates a stdio server', (tester) async {
    McpServerConfig? result;
    await _open(tester, (value) => result = value);

    await tester.enterText(find.byType(AppTextField).at(0), 'Local');
    await tester.enterText(find.byType(AppTextField).at(1), 'node');
    await tester.enterText(find.byType(AppTextField).at(2), 'server.js');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(result?.name, 'Local');
    expect(result?.transport, McpTransport.stdio);
    expect(result?.command, 'node');
    expect(result?.args, ['server.js']);
    expect(result?.source, McpServerSource.user);
  });

  testWidgets('requires a name', (tester) async {
    await _open(tester, (_) => fail('dialog must stay open'));

    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a name.'), findsOneWidget);
  });

  testWidgets('switches to HTTP and validates the URL', (tester) async {
    McpServerConfig? result;
    await _open(tester, (value) => result = value);

    await tester.enterText(find.byType(AppTextField).at(0), 'Remote');
    await tester.tap(find.text('HTTP'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(AppTextField).at(1), 'not a url');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid http(s) URL.'), findsOneWidget);
    expect(result, isNull);
  });
}
