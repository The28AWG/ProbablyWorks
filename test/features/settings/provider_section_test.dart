import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/settings/presentation/widgets/provider_section.dart';
import 'package:probably_works/features/settings/presentation/widgets/settings_form_row.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

const _descriptor = LlmProviderDescriptor(
  id: 'test',
  label: 'Test provider',
  requiresApiKey: true,
  supportsApiKey: true,
  supportsKeyInfo: true,
);

/// Счётчик нажатий: обработчики не должны быть пустыми блоками.
int _callbacks = 0;

void _onCheck() => _callbacks++;

void _onEnabled(bool _) => _callbacks++;

void _onBaseUrl(String _) => _callbacks++;

Future<bool> _onApiKey(String _) async {
  _callbacks++;
  return true;
}

void _onDelete() => _callbacks++;

/// Карточка провайдера в минимальном приложении: обработчики не нужны,
/// проверяется только отрисовка и режим замены ключа.
class _Host extends StatelessWidget {
  const _Host({required this.status});

  final LlmProviderStatus status;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: AppTheme.light,
    locale: const Locale('en'),
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 720,
          child: ProviderSection(
            descriptor: _descriptor,
            status: status,
            loading: false,
            error: null,
            onCheck: _onCheck,
            onEnabledChanged: _onEnabled,
            onBaseUrlSaved: _onBaseUrl,
            onApiKeySaved: _onApiKey,
            onApiKeyDeleted: _onDelete,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('saved and empty key share the same row height', (tester) async {
    await tester.pumpWidget(
      const _Host(
        status: LlmProviderStatus(
          id: 'test',
          apiKeySet: true,
          apiKeyTail: '726',
        ),
      ),
    );
    final savedHeight = tester
        .getSize(find.byType(SettingsFormRow).first)
        .height;

    await tester.pumpWidget(const _Host(status: LlmProviderStatus(id: 'test')));
    final emptyHeight = tester
        .getSize(find.byType(SettingsFormRow).first)
        .height;

    expect(emptyHeight, savedHeight);
  });

  testWidgets('saved key shows check, edit and delete icons with tooltips', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _Host(
        status: LlmProviderStatus(
          id: 'test',
          apiKeySet: true,
          apiKeyTail: '726',
        ),
      ),
    );
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ProviderSection)),
    );

    expect(find.byTooltip(l10n.providerCheck), findsOneWidget);
    expect(find.byTooltip(l10n.settingsApiKeyReplace), findsOneWidget);
    expect(find.byTooltip(l10n.providerApiKeyDelete), findsOneWidget);
    expect(find.byTooltip(l10n.commonSave), findsNothing);
    // Маска показана подсказкой тем же полем, в режиме только чтение.
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
  });

  testWidgets('replacing a key switches to input with cancel and save icons', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _Host(
        status: LlmProviderStatus(
          id: 'test',
          apiKeySet: true,
          apiKeyTail: '726',
        ),
      ),
    );
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ProviderSection)),
    );

    await tester.tap(find.byTooltip(l10n.settingsApiKeyReplace));
    await tester.pump();

    expect(find.byTooltip(l10n.commonCancel), findsOneWidget);
    expect(find.byTooltip(l10n.commonSave), findsOneWidget);
    expect(find.byTooltip(l10n.providerCheck), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
  });
}
