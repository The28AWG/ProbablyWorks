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
    this.apiKeyTail = '',
    this.keyInfo,
    this.keyInfoLoading = false,
    this.keyInfoError,
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
    this.keyError,
  });

  /// Последние три символа ключа для показа. Полный ключ в состояние не попадает. Пусто — ключа нет.
  final String apiKeyTail;

  /// Ключ задан (есть хвост). Ключ хранится только в `SecretStore`.
  bool get apiKeySet => apiKeyTail.isNotEmpty;

  /// Сведения о ключе из сервиса. Null — ещё не получены или ключа нет.
  final LlmKeyInfo? keyInfo;

  /// Запрос сведений о ключе в полёте.
  final bool keyInfoLoading;

  /// Ошибка последнего запроса сведений о ключе; null после успеха.
  final String? keyInfoError;

  /// Причина, по которой ключ не принят сервисом. Прежний ключ при этом сохраняется.
  final String? keyError;

  /// Каталог моделей: список, статус загрузки и сохранённые детали выбранных моделей.
  final ModelCatalogState catalog;
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
    String? apiKeyTail,
    LlmKeyInfo? keyInfo,
    bool clearKeyInfo = false,
    bool? keyInfoLoading,
    String? keyInfoError,
    bool clearKeyInfoError = false,
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
    String? keyError,
    bool clearKeyError = false,
  }) => SettingsState(
    apiKeyTail: apiKeyTail ?? this.apiKeyTail,
    keyInfo: clearKeyInfo ? null : (keyInfo ?? this.keyInfo),
    keyInfoLoading: keyInfoLoading ?? this.keyInfoLoading,
    keyInfoError: clearKeyInfoError
        ? null
        : (keyInfoError ?? this.keyInfoError),
    keyError: clearKeyError ? null : (keyError ?? this.keyError),
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
  );

  @override
  List<Object?> get props => [
    apiKeyTail,
    keyInfo,
    keyInfoLoading,
    keyInfoError,
    keyError,
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
        apiKeyTail: snapshot.apiKeyTail,
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
    if (!snapshot.catalog.loaded && state.apiKeySet) await refreshModels();
    await refreshKeyInfo();
  }

  /// Ключ сохраняется, только если сервис его принял. Иначе адаптер возвращает прежнее значение.
  Future<void> saveApiKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return;
    final LlmKeyInfo? info;
    try {
      await _agentSettings.saveApiKey(trimmed);
      info = await _agentSettings.checkKey();
    } on Object catch (error) {
      emit(state.copyWith(keyError: _messageOf(error)));
      return;
    }
    emit(
      state.copyWith(
        apiKeyTail: _tailOf(trimmed),
        keyInfo: info,
        clearKeyInfo: info == null,
        clearKeyInfoError: true,
        clearKeyError: true,
        saved: state.saved + 1,
      ),
    );
    await refreshModels();
  }

  /// Удаляет ключ из защищённого хранилища. Список моделей публичный и остаётся в памяти.
  /// Фоновые обновления без ключа не запускаются: ModelCatalogService проверяет ключ перед каждой попыткой.
  Future<void> deleteApiKey() async {
    await _agentSettings.deleteApiKey();
    emit(
      state.copyWith(
        apiKeyTail: '',
        clearKeyInfo: true,
        clearKeyInfoError: true,
        clearKeyError: true,
        saved: state.saved + 1,
      ),
    );
  }

  /// Запрашивает у сервиса сведения о ключе (лимит, остаток, срок). Ошибка показывается в карточке ключа.
  Future<void> refreshKeyInfo() async {
    if (!state.apiKeySet) return;
    emit(state.copyWith(keyInfoLoading: true, clearKeyInfoError: true));
    try {
      final info = await _agentSettings.checkKey();
      emit(state.copyWith(keyInfo: info, keyInfoLoading: false));
    } on Object catch (error) {
      emit(
        state.copyWith(keyInfoLoading: false, keyInfoError: _messageOf(error)),
      );
    }
  }

  /// Обновляет список из OpenRouter. Загрузка и ошибка приходят в состоянии каталога.
  Future<void> refreshModels() async {
    try {
      await _agentSettings.refreshModels();
    } on Object {
      // Ошибка уже в state.catalog.error; повтор запланирован каталогом.
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

  /// Последние три символа ключа; пустая строка, если ключа нет. Полный ключ наружу не выводится.
  static String _tailOf(String? key) {
    if (key == null || key.isEmpty) return '';
    // По code points, а не по UTF-16: символ из суррогатной пары не должен разрезаться.
    final runes = key.runes.toList();
    return String.fromCharCodes(
      runes.skip(runes.length > 3 ? runes.length - 3 : 0),
    );
  }

  static String _messageOf(Object error) =>
      error is AppFailure ? error.message : '$error';
}
