import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/locale/app_localization_delegates.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/app/theme/theme_controller.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:probably_works/features/settings/presentation/bloc/settings_cubit.dart';
import 'package:probably_works/features/settings/presentation/widgets/api_key_section.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/local_agent_settings_api.dart';
import 'package:pw_agent/core/data/saved_model_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

/// Провайдер без сети: блок ключа не вызывает модели, а кубит нужен только как держатель обработчиков.
class _NoNetLlm implements LlmProvider {
  @override
  Future<LlmKeyInfo> checkKey() => throw UnimplementedError('not used here');

  @override
  Future<List<LlmModelInfo>> listModels() async => const [];

  @override
  Stream<LlmEvent> stream(LlmRequest request) =>
      throw UnimplementedError('not used here');
}

/// Блок ключа в минимальном приложении шириной [width]; кубит нужен только для обработчиков.
class _KeyHost extends StatelessWidget {
  const _KeyHost({required this.state, required this.cubit});

  final SettingsState state;
  final SettingsCubit cubit;

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
          child: ApiKeySection(state: state, cubit: cubit),
        ),
      ),
    ),
  );
}

void main() {
  late AppDatabase db;
  late SettingsCubit cubit;

  setUp(() {
    db = openInMemoryDatabase();
    final settings = SettingsRepository(db);
    cubit = SettingsCubit(
      MemoryClientSettings(),
      LocalAgentSettingsApi(
        settings,
        MemorySecretStore(),
        ModelCatalogService(SavedModelRepository(db), _NoNetLlm()),
      ),
      LocaleController(),
      ThemeController(),
    );
  });
  tearDown(() async {
    await cubit.close();
    await db.close();
  });

  testWidgets('saved and empty key share the same row height', (tester) async {
    await tester.pumpWidget(
      _KeyHost(
        state: const SettingsState(apiKeyTail: '726'),
        cubit: cubit,
      ),
    );
    final savedHeight = tester.getSize(find.byType(AppCard).first).height;

    await tester.pumpWidget(
      _KeyHost(state: const SettingsState(), cubit: cubit),
    );
    final emptyHeight = tester.getSize(find.byType(AppCard).first).height;

    expect(emptyHeight, savedHeight);
  });

  testWidgets('saved key shows check, edit and delete icons with tooltips', (
    tester,
  ) async {
    await tester.pumpWidget(
      _KeyHost(
        state: const SettingsState(apiKeyTail: '726'),
        cubit: cubit,
      ),
    );
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ApiKeySection)),
    );

    expect(find.byTooltip(l10n.settingsApiKeyCheck), findsOneWidget);
    expect(find.byTooltip(l10n.settingsApiKeyReplace), findsOneWidget);
    expect(find.byTooltip(l10n.settingsApiKeyDelete), findsOneWidget);
    expect(find.byTooltip(l10n.commonSave), findsNothing);
    // Маска показана подсказкой тем же полем, в режиме только чтение.
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
  });

  testWidgets('replacing a key switches to input with cancel and save icons', (
    tester,
  ) async {
    await tester.pumpWidget(
      _KeyHost(
        state: const SettingsState(apiKeyTail: '726'),
        cubit: cubit,
      ),
    );
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ApiKeySection)),
    );

    await tester.tap(find.byTooltip(l10n.settingsApiKeyReplace));
    await tester.pump();

    expect(find.byTooltip(l10n.commonCancel), findsOneWidget);
    expect(find.byTooltip(l10n.commonSave), findsOneWidget);
    expect(find.byTooltip(l10n.settingsApiKeyCheck), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isFalse);
  });
}
