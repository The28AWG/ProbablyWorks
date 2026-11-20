import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/ui/deferred_route_placeholder.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';

void main() {
  testWidgets('shows a localized loader without its own page chrome', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const DeferredRoutePlaceholder(),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(Scaffold), findsNothing);

    final indicator = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(indicator.semanticsLabel, 'Loading…');
  });
}
