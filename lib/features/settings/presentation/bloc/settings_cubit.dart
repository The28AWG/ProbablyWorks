import 'dart:async';
import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/app/theme/theme_controller.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

class SettingsState extends Equatable {
  const SettingsState({
    this.catalog = const ModelCatalogState(),
    this.defaultModel = '',
    this.titleModel = '',
    this.memoryModel = '',
    this.subagentModel = '',
    this.fallbackModel = '',
    this.language = 'system',
    this.themeMode = ThemeMode.system,
    this.defaultPolicy = PolicyMode.ask,
    this.denylist = '',
    this.securityProfile = const SecurityProfile(),
    this.limitsJson = '',
    this.limitsError = false,
    this.pinnedModels = const [],
    this.stepsDisplay = StepsDisplay.defaults,
    this.saved = 0,
    this.providerErrors = const {},
    this.providerLoading = const {},
  });

  /// Каталог моделей: список, статус загрузки, дескрипторы провайдеров
  /// и их статусы.
  final ModelCatalogState catalog;

  /// Ошибки сохранения и проверки по id провайдера.
  final Map<String, String> providerErrors;

  /// Провайдеры, для которых идёт сохранение или проверка.
  final Set<String> providerLoading;

  final String defaultModel;
  final String titleModel;
  final String memoryModel;
  final String subagentModel;
  final String fallbackModel;
  final String language;

  /// Тема: системная, светлая или тёмная.
  final ThemeMode themeMode;
  final PolicyMode defaultPolicy;
  final String denylist;

  /// Уровни категорий, команд и аргументов. Встроенный профиль, пока настройка не записана.
  final SecurityProfile securityProfile;
  final String limitsJson;
  final bool limitsError;

  /// Закреплённые id моделей (порядок — порядок добавления).
  final List<String> pinnedModels;

  /// Поведение журнала шагов в чате по умолчанию.
  final StepsDisplay stepsDisplay;

  /// Увеличивается при каждом сохранении: страница показывает снекбар по изменению.
  final int saved;

  SettingsState copyWith({
    ModelCatalogState? catalog,
    String? defaultModel,
    String? titleModel,
    String? memoryModel,
    String? subagentModel,
    String? fallbackModel,
    String? language,
    ThemeMode? themeMode,
    PolicyMode? defaultPolicy,
    String? denylist,
    SecurityProfile? securityProfile,
    String? limitsJson,
    bool? limitsError,
    List<String>? pinnedModels,
    StepsDisplay? stepsDisplay,
    int? saved,
    Map<String, String>? providerErrors,
    Set<String>? providerLoading,
  }) => SettingsState(
    catalog: catalog ?? this.catalog,
    defaultModel: defaultModel ?? this.defaultModel,
    titleModel: titleModel ?? this.titleModel,
    memoryModel: memoryModel ?? this.memoryModel,
    subagentModel: subagentModel ?? this.subagentModel,
    fallbackModel: fallbackModel ?? this.fallbackModel,
    language: language ?? this.language,
    themeMode: themeMode ?? this.themeMode,
    defaultPolicy: defaultPolicy ?? this.defaultPolicy,
    denylist: denylist ?? this.denylist,
    securityProfile: securityProfile ?? this.securityProfile,
    limitsJson: limitsJson ?? this.limitsJson,
    limitsError: limitsError ?? this.limitsError,
    pinnedModels: pinnedModels ?? this.pinnedModels,
    stepsDisplay: stepsDisplay ?? this.stepsDisplay,
    saved: saved ?? this.saved,
    providerErrors: providerErrors ?? this.providerErrors,
    providerLoading: providerLoading ?? this.providerLoading,
  );

  @override
  List<Object?> get props => [
    catalog,
    defaultModel,
    titleModel,
    memoryModel,
    subagentModel,
    fallbackModel,
    language,
    themeMode,
    defaultPolicy,
    denylist,
    securityProfile,
    limitsJson,
    limitsError,
    pinnedModels,
    stepsDisplay,
    saved,
    providerErrors,
    providerLoading,
  ];
}

class SettingsCubit extends Cubit<SettingsState> {
  SettingsCubit(this._settings, this._agentSettings, this._locale, this._theme)
    : super(const SettingsState());

  final ClientSettings _settings;
  final AgentSettingsApi _agentSettings;
  final LocaleController _locale;
  final ThemeController _theme;
  StreamSubscription<ModelCatalogState>? _catalogSub;
  StreamSubscription<List<String>>? _pinsSub;

  @override
  Future<void> close() async {
    await _catalogSub?.cancel();
    await _pinsSub?.cancel();
    return super.close();
  }

  Future<void> load() async {
    // Локальные настройки доступны и без сервера: язык и тема не зависят от API.
    final language =
        await _settings.read(ClientSettingsKeys.language) ?? 'system';
    final themeMode = ThemeController.modeFrom(
      await _settings.read(ClientSettingsKeys.themeMode),
    );
    emit(state.copyWith(language: language, themeMode: themeMode));

    final AgentSettingsSnapshot snapshot;
    try {
      snapshot = await _agentSettings.load();
    } on Object {
      // Сервер offline: страница настроек остаётся доступной для профилей
      // и локальных настроек. Удалённые разделы не загружаем.
      return;
    }
    emit(
      state.copyWith(
        defaultModel: snapshot.defaultModel,
        titleModel: snapshot.titleModel,
        memoryModel: snapshot.memoryModel,
        subagentModel: snapshot.subagentModel,
        fallbackModel: snapshot.fallbackModel,
        defaultPolicy: PolicyMode.values.byName(snapshot.defaultPolicy),
        denylist: snapshot.denylist.join('\n'),
        securityProfile: snapshot.securityProfile,
        limitsJson: const JsonEncoder.withIndent('  ')
            .convert(snapshot.limits.toMap()),
        pinnedModels: snapshot.pinnedModels,
        stepsDisplay: snapshot.stepsDisplay,
        catalog: snapshot.catalog,
        language: language,
        themeMode: themeMode,
      ),
    );
    try {
      await _agentSettings.rememberModels([
        snapshot.defaultModel,
        snapshot.titleModel,
        snapshot.memoryModel,
        snapshot.subagentModel,
        snapshot.fallbackModel,
        ...snapshot.pinnedModels,
      ]);
    } on Object {
      // Кэш моделей — не критичная часть страницы.
    }
    await _catalogSub?.cancel();
    _catalogSub = _agentSettings.watchCatalog().listen(
      (catalog) => emit(state.copyWith(catalog: catalog)),
    );
    await _pinsSub?.cancel();
    _pinsSub = _agentSettings.watchPinnedModels().listen(
      (pinned) => emit(state.copyWith(pinnedModels: pinned)),
    );
    if (!snapshot.catalog.loaded && snapshot.catalog.hasEnabledProvider) {
      await refreshModels();
    }
  }

  /// Обновляет список моделей из всех провайдеров. Загрузка и ошибка приходят
  /// в состоянии каталога.
  Future<void> refreshModels() async {
    try {
      await _agentSettings.refreshModels();
    } on Object {
      // Ошибка уже в state.catalog.error; повтор запланирован каталогом.
    }
  }

  /// Проверяет доступность провайдера и обновляет его статус в каталоге.
  /// После проверки обновляется и список моделей: сервер мог включиться.
  Future<void> checkProvider(String providerId) async {
    await _changeProvider(providerId, () => Future<void>.value(), save: false);
    await refreshModels();
  }

  /// Сохраняет адрес сервера и перезагружает каталог.
  Future<void> saveProviderBaseUrl(String providerId, String baseUrl) =>
      _changeProvider(
        providerId,
        () => _agentSettings.saveProviderBaseUrl(providerId, baseUrl),
      );

  /// Сохраняет ключ. Провайдер с обязательным ключом сам откатывает
  /// нерабочее значение. Возвращает true, если ключ принят.
  Future<bool> saveProviderApiKey(String providerId, String key) async {
    _setProviderLoading(providerId, true);
    _clearProviderError(providerId);
    try {
      final status = await _agentSettings.saveProviderApiKey(providerId, key);
      _putProviderStatus(status);
      await refreshModels();
      emit(state.copyWith(saved: state.saved + 1));
      return true;
    } on Object catch (error) {
      _setProviderError(providerId, _messageOf(error));
      // Ключ мог быть откатан адаптером: забираем актуальные настройки,
      // чтобы маска не показывала отклонённое значение.
      await _refreshProviderConfigs();
      return false;
    } finally {
      _setProviderLoading(providerId, false);
    }
  }

  /// Удаляет ключ провайдера. Адрес и модели остаются.
  Future<void> deleteProviderApiKey(String providerId) => _changeProvider(
    providerId,
    () => _agentSettings.deleteProviderApiKey(providerId),
  );

  /// Включает или выключает провайдера.
  Future<void> setProviderEnabled(String providerId, bool enabled) =>
      _changeProvider(
        providerId,
        () => _agentSettings.setProviderEnabled(providerId, enabled),
      );

  /// Общая обёртка изменения настроек провайдера: сохранение, проверка
  /// и обновление каталога. Ошибка остаётся в карточке провайдера.
  Future<void> _changeProvider(
    String providerId,
    Future<void> Function() action, {
    bool save = true,
  }) async {
    _setProviderLoading(providerId, true);
    _clearProviderError(providerId);
    try {
      await action();
      final status = await _agentSettings.checkProvider(providerId);
      _putProviderStatus(status);
      if (save) {
        await refreshModels();
        emit(state.copyWith(saved: state.saved + 1));
      }
    } on Object catch (error) {
      _setProviderError(providerId, _messageOf(error));
    } finally {
      _setProviderLoading(providerId, false);
    }
  }

  void _putProviderStatus(LlmProviderStatus status) {
    final merged = mergeProviderStatus(
      state.catalog.providerStatuses[status.id],
      status,
    );
    emit(
      state.copyWith(
        catalog: state.catalog.copyWith(
          providerStatuses: {
            ...state.catalog.providerStatuses,
            merged.id: merged,
          },
        ),
      ),
    );
  }

  void _setProviderLoading(String providerId, bool loading) {
    final next = {...state.providerLoading};
    if (loading) {
      next.add(providerId);
    } else {
      next.remove(providerId);
    }
    emit(state.copyWith(providerLoading: next));
  }

  void _setProviderError(String providerId, String message) {
    emit(
      state.copyWith(
        providerErrors: {...state.providerErrors, providerId: message},
      ),
    );
  }

  void _clearProviderError(String providerId) {
    if (!state.providerErrors.containsKey(providerId)) return;
    final next = {...state.providerErrors}..remove(providerId);
    emit(state.copyWith(providerErrors: next));
  }

  /// Перечитывает настройки провайдеров без сети и обновляет статусы,
  /// сохраняя уже полученные метаданные ключа.
  Future<void> _refreshProviderConfigs() async {
    try {
      final statuses = await _agentSettings.providerStatuses();
      final next = {...state.catalog.providerStatuses};
      for (final status in statuses) {
        next[status.id] = mergeProviderStatus(next[status.id], status);
      }
      emit(
        state.copyWith(catalog: state.catalog.copyWith(providerStatuses: next)),
      );
    } on Object {
      // Статус обновится при следующей загрузке настроек.
    }
  }

  Future<void> saveModels({
    required String defaultModel,
    required String titleModel,
  }) async {
    await _agentSettings.writeSetting(
      SettingsRepository.keyDefaultModel,
      defaultModel,
    );
    await _agentSettings.writeSetting(
      SettingsRepository.keyTitleModel,
      titleModel,
    );
    await _agentSettings.rememberModels([defaultModel, titleModel]);
    emit(
      state.copyWith(
        defaultModel: defaultModel,
        titleModel: titleModel,
        saved: state.saved + 1,
      ),
    );
  }

  Future<void> saveMemoryModel(String id) async {
    await _agentSettings.writeSetting(SettingsRepository.keyMemoryModel, id);
    await _agentSettings.rememberModels([id]);
    emit(state.copyWith(memoryModel: id, saved: state.saved + 1));
  }

  Future<void> saveSubagentModel(String id) async {
    await _agentSettings.writeSetting(SettingsRepository.keySubagentModel, id);
    await _agentSettings.rememberModels([id]);
    emit(state.copyWith(subagentModel: id, saved: state.saved + 1));
  }

  Future<void> saveFallbackModel(String id) async {
    await _agentSettings.writeSetting(SettingsRepository.keyFallbackModel, id);
    await _agentSettings.rememberModels([id]);
    emit(state.copyWith(fallbackModel: id, saved: state.saved + 1));
  }

  Future<void> saveLanguage(String code) async {
    await _settings.write(ClientSettingsKeys.language, code);
    _locale.apply(code);
    emit(state.copyWith(language: code, saved: state.saved + 1));
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    await _settings.write(ClientSettingsKeys.themeMode, mode.name);
    _theme.apply(mode);
    emit(state.copyWith(themeMode: mode, saved: state.saved + 1));
  }

  Future<void> saveDefaultPolicy(PolicyMode mode) async {
    await _agentSettings.writeSetting(
      SettingsRepository.keyDefaultPolicy,
      mode.name,
    );
    emit(state.copyWith(defaultPolicy: mode, saved: state.saved + 1));
  }

  Future<void> saveStepsDisplay(StepsDisplay value) async {
    await _agentSettings.saveStepsDisplay(value);
    emit(state.copyWith(stepsDisplay: value, saved: state.saved + 1));
  }

  Future<void> togglePin(String modelId) async {
    final pins = [...state.pinnedModels];
    if (!pins.remove(modelId)) pins.add(modelId);
    if (pins.contains(modelId)) await _agentSettings.rememberModels([modelId]);
    await _agentSettings.savePinnedModels(pins);
    emit(state.copyWith(pinnedModels: pins, saved: state.saved + 1));
  }

  /// Лимиты вложений меняют только свои поля; остальные лимиты сохраняются как есть.
  Future<void> saveAttachLimits({
    required int perMessage,
    required int maxBytes,
  }) async {
    final current = _parseLimits(state.limitsJson) ?? const AppLimits();
    final limits = current.copyWith(
      attachmentsPerMessage: perMessage,
      attachmentMaxBytes: maxBytes,
    );
    await _agentSettings.saveLimits(limits);
    emit(
      state.copyWith(
        limitsJson: const JsonEncoder.withIndent('  ').convert(limits.toMap()),
        saved: state.saved + 1,
      ),
    );
  }

  Future<void> saveDenylist(String text) async {
    final patterns = text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    await _agentSettings.saveDenylist(patterns);
    emit(state.copyWith(denylist: patterns.join('\n'), saved: state.saved + 1));
  }

  /// Записывает уровни команд и увеличивает счётчик сохранения.
  Future<void> saveSecurityProfile(SecurityProfile profile) async {
    await _agentSettings.saveSecurityProfile(profile);
    emit(state.copyWith(securityProfile: profile, saved: state.saved + 1));
  }

  /// Лимиты: JSON проверяется до сохранения. Жёсткие правила (Policy, host key) настройками не отключаются.
  Future<void> saveLimits(String text) async {
    final parsed = _parseLimits(text);
    if (parsed == null) {
      emit(state.copyWith(limitsError: true));
      return;
    }
    await _agentSettings.saveLimits(parsed);
    emit(
      state.copyWith(
        limitsError: false,
        limitsJson: const JsonEncoder.withIndent('  ').convert(parsed.toMap()),
        saved: state.saved + 1,
      ),
    );
  }

  AppLimits? _parseLimits(String text) {
    try {
      return AppLimits.parse(text);
    } on FormatException {
      return null;
    }
  }

  static String _messageOf(Object error) =>
      error is AppFailure ? error.message : '$error';
}
