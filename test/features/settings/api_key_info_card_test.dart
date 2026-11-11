import 'package:app_ui/app_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/features/settings/presentation/widgets/api_key_info_card.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

void _noop() {
  return;
}

/// Карточка внутри минимального приложения с локализацией; [onRetry] получает нажатия повтора.
class _CardHost extends StatelessWidget {
  const _CardHost({
    this.info,
    this.loading = false,
    this.error,
    this.onRetry = _noop,
  });

  final LlmKeyInfo? info;
  final bool loading;
  final String? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: ApiKeyInfoCard(
        info: info,
        loading: loading,
        error: error,
        onRetry: onRetry,
      ),
    ),
  );
}

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(ApiKeyInfoCard)));

void main() {
  const limited = LlmKeyInfo(
    label: 'sk-or-v1-...abc',
    usage: 12.5,
    limit: 50,
    limitRemaining: 37.5,
    limitReset: 'monthly',
    expiresAt: null,
  );

  testWidgets('shows usage, limit and remaining amounts', (tester) async {
    await tester.pumpWidget(_CardHost(info: limited));
    final l10n = _l10n(tester);

    expect(find.text('sk-or-v1-...abc'), findsOneWidget);
    expect(find.text('\$12.50'), findsOneWidget);
    expect(find.text('\$50.00'), findsOneWidget);
    expect(find.text(l10n.settingsKeyRemaining), findsOneWidget);
    expect(find.text('\$37.50'), findsOneWidget);
    expect(find.text('monthly'), findsOneWidget);
    expect(find.text(l10n.settingsKeyNeverExpires), findsOneWidget);
  });

  testWidgets('without a limit shows no-limit and hides remaining', (
    tester,
  ) async {
    await tester.pumpWidget(
      _CardHost(
        info: LlmKeyInfo(
          label: 'key',
          usage: 1,
          isFreeTier: true,
          expiresAt: DateTime(2027, 12, 31),
        ),
      ),
    );
    final l10n = _l10n(tester);

    expect(find.text(l10n.settingsKeyNoLimit), findsOneWidget);
    expect(find.text(l10n.settingsKeyRemaining), findsNothing);
    expect(find.text('31.12.2027'), findsOneWidget);
    expect(find.text(l10n.settingsKeyPlanFree), findsOneWidget);
  });

  testWidgets('an error shows a banner whose retry calls onRetry', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      _CardHost(error: 'network down', onRetry: () => retries++),
    );
    final l10n = _l10n(tester);

    expect(find.text(l10n.commonError('network down')), findsOneWidget);
    await tester.tap(find.text(l10n.commonRetry));
    expect(retries, 1);
  });

  testWidgets('loading shows a spinner and no empty hint', (tester) async {
    await tester.pumpWidget(_CardHost(loading: true));
    final l10n = _l10n(tester);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text(l10n.settingsKeyInfoEmpty), findsNothing);
  });

  testWidgets('no data and no error shows the empty hint', (tester) async {
    await tester.pumpWidget(_CardHost());
    final l10n = _l10n(tester);

    expect(find.text(l10n.settingsKeyInfoEmpty), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
