import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/settings/presentation/widgets/push_notifications_section.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/push_api.dart';

final class _FakePush implements PushApi {
  PushSettings settings = const PushSettings();

  @override
  Future<PushSettings> pushSettings() async => settings;

  @override
  Future<void> savePush(
    PushSettings value, {
    String? token,
    bool clearToken = false,
  }) async {
    settings = value.copyWith(
      hasToken: !clearToken && (token != null || settings.hasToken),
    );
  }

  @override
  Future<void> testPush() => Future<void>.value();
}

void main() {
  testWidgets('saves relay settings for the profile', (tester) async {
    final api = _FakePush();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        locale: const Locale('en'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: PushNotificationsSection(api: api)),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.enterText(find.byType(TextField).at(0), 'https://relay.test');
    await tester.enterText(find.byType(TextField).at(1), 'secret');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(api.settings.enabled, isTrue);
    expect(api.settings.relayUrl, 'https://relay.test');
    expect(api.settings.hasToken, isTrue);
  });
}
