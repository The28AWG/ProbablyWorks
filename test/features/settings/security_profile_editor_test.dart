import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/policy/command_risk.dart';
import 'package:probably_works/agent/policy/security_profile.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/settings/presentation/widgets/security_profile_editor.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

void main() {
  Future<SecurityProfile?> pumpEditor(
    WidgetTester tester, {
    required double width,
  }) async {
    SecurityProfile? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: width,
              child: SecurityProfileEditor(
                profile: const SecurityProfile(),
                denylist: '',
                onChanged: (profile) => saved = profile,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return saved;
  }

  testWidgets('preview follows the same classifier as the agent', (
    tester,
  ) async {
    await pumpEditor(tester, width: 720);
    await tester.enterText(find.byType(AppTextField).first, 'ls');
    await tester.pump();
    expect(find.text('read-only command'), findsOneWidget);

    await tester.enterText(find.byType(AppTextField).first, 'sudo ls');
    await tester.pump();
    expect(find.text('privilege escalation is not allowed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a narrow editor does not overflow', (tester) async {
    await pumpEditor(tester, width: 360);
    expect(tester.takeException(), isNull);
  });

  testWidgets('adding a command outside the catalog stores it at ask', (
    tester,
  ) async {
    SecurityProfile? saved;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 720,
              child: SecurityProfileEditor(
                profile: const SecurityProfile(),
                denylist: '',
                onChanged: (profile) => saved = profile,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final add = find.widgetWithText(TextButton, 'Add command');
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(AppTextField).last, 'Bad Name');
    await tester.tap(find.widgetWithText(FilledButton, 'Add command'));
    await tester.pump();
    expect(
      find.text('Use a command name: letters, digits, and . _ + -'),
      findsOneWidget,
    );

    await tester.enterText(find.byType(AppTextField).last, 'mytool');
    await tester.tap(find.widgetWithText(FilledButton, 'Add command'));
    await tester.pumpAndSettle();
    expect(saved?.commands['mytool'], CommandRisk.ask);
  });
}
