import 'dart:async';
import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/domain/steps_display.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/app/theme/theme_controller.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/error/app_failure.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:probably_works/providers/ai/model_catalog.dart';

class SettingsState extends Equatable {
  const SettingsState({
    this.apiKeyTail = '',
    this.keyInfo,
    this.keyInfoLoading = false,
    this.keyInfoError,
    this.catalog = const ModelCatalogState(),
    this.defaultModel = '',
    this.titleModel = '',
    this.language = 'system',
    this.themeMode = ThemeMode.system,
    this.defaultPolicy = PolicyMode.ask,
    this.denylist = '',
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
  final String language;

  /// Тема: системная, светлая или тёмная.
  final ThemeMode themeMode;
  final PolicyMode defaultPolicy;
  final String denylist;
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
    String? language,
    ThemeMode? themeMode,
    PolicyMode? defaultPolicy,
    String? denylist,
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
    language: language ?? this.language,
    themeMode: themeMode ?? this.themeMode,
    defaultPolicy: defaultPolicy ?? this.defaultPolicy,
    denylist: denylist ?? this.denylist,
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
    language,
    themeMode,
    defaultPolicy,
    denylist,
    limitsJson,
    limitsError,
    pinnedModels,
    stepsDisplay,
    saved,
  ];
}

class SettingsCubit extends Cubit<SettingsState> {
  SettingsCubit(
    this._settings,
    this._secrets,
    this._catalog,
    this._locale,
    this._theme,
  ) : super(const SettingsState());

  final SettingsRepository _settings;
  final SecretStore _secrets;
  final ModelCatalogService _catalog;
  final LocaleController _locale;
  final ThemeController _theme;
  StreamSubscription<ModelCatalogState>? _catalogSub;
  StreamSubscription<String?>? _pinsSub;

  @override
  Future<void> close() async {
    await _catalogSub?.cancel();
    await _pinsSub?.cancel();
    return super.close();
  }

  Future<void> load() async {
    final limits = await _settings.limits();
    final key = await _secrets.read(openRouterKeyName);
    emit(
      state.copyWith(
        apiKeyTail: _tailOf(key),
        defaultModel:
            await _settings.read(SettingsRepository.keyDefaultModel) ?? '',
        titleModel:
            await _settings.read(SettingsRepository.keyTitleModel) ?? '',
        language:
            await _settings.read(SettingsRepository.keyLanguage) ?? 'system',
        themeMode: ThemeController.modeFrom(
          await _settings.read(SettingsRepository.keyThemeMode),
        ),
        defaultPolicy: PolicyMode.values.byName(
          await _settings.read(SettingsRepository.keyDefaultPolicy) ?? 'ask',
        ),
        denylist: (await _settings.readDenylist()).join('\n'),
        limitsJson: const JsonEncoder.withIndent('  ').convert(limits.toMap()),
        pinnedModels: await _settings.readPinnedModels(),
        stepsDisplay: await _settings.readStepsDisplay(),
      ),
    );
    // Выбранные модели показываем сразу; список грузится в фоне, а если его ещё не было — загружаем здесь.
    await _catalog.remember([
      state.defaultModel,
      state.titleModel,
      ...state.pinnedModels,
    ]);
    emit(state.copyWith(catalog: _catalog.state));
    await _catalogSub?.cancel();
    _catalogSub = _catalog.watch().listen(
      (catalog) => emit(state.copyWith(catalog: catalog)),
    );
    // Закрепления могут смениться в композере открытого чата или агентом: читаем их из БД при каждом изменении.
    await _pinsSub?.cancel();
    _pinsSub = _settings
        .watch(SettingsRepository.keyPinnedModels)
        .listen((_) => unawaited(_reloadPinned()));
    if (!_catalog.state.loaded && state.apiKeySet) await refreshModels();
    await refreshKeyInfo();
  }

  /// Ключ сохраняется, только если сервис его принял. Иначе возвращается прежнее значение.
  Future<void> saveApiKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return;
    final previous = await _secrets.read(openRouterKeyName);
    await _secrets.write(openRouterKeyName, trimmed);
    final LlmKeyInfo info;
    try {
      info = await _catalog.checkKey();
    } on Object catch (error) {
      if (previous == null) {
        await _secrets.delete(openRouterKeyName);
      } else {
        await _secrets.write(openRouterKeyName, previous);
      }
      emit(state.copyWith(keyError: _messageOf(error)));
      return;
    }
    emit(
      state.copyWith(
        apiKeyTail: _tailOf(trimmed),
        keyInfo: info,
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
    await _secrets.delete(openRouterKeyName);
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
      final info = await _catalog.checkKey();
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
      await _catalog.refresh();
    } on Object {
      // Ошибка уже в state.catalog.error; повтор запланирован каталогом.
    }
  }

  Future<void> saveModels({
    required String defaultModel,
    required String titleModel,
  }) async {
    await _settings.write(SettingsRepository.keyDefaultModel, defaultModel);
    await _settings.write(SettingsRepository.keyTitleModel, titleModel);
    await _catalog.remember([defaultModel, titleModel]);
    emit(
      state.copyWith(
        defaultModel: defaultModel,
        titleModel: titleModel,
        saved: state.saved + 1,
      ),
    );
  }

  Future<void> saveLanguage(String code) async {
    await _settings.write(SettingsRepository.keyLanguage, code);
    _locale.apply(code);
    emit(state.copyWith(language: code, saved: state.saved + 1));
  }

  Future<void> saveThemeMode(ThemeMode mode) async {
    await _settings.write(SettingsRepository.keyThemeMode, mode.name);
    _theme.apply(mode);
    emit(state.copyWith(themeMode: mode, saved: state.saved + 1));
  }

  Future<void> saveDefaultPolicy(PolicyMode mode) async {
    await _settings.write(SettingsRepository.keyDefaultPolicy, mode.name);
    emit(state.copyWith(defaultPolicy: mode, saved: state.saved + 1));
  }

  Future<void> saveStepsDisplay(StepsDisplay value) async {
    await _settings.saveStepsDisplay(value);
    emit(state.copyWith(stepsDisplay: value, saved: state.saved + 1));
  }

  Future<void> togglePin(String modelId) async {
    final pins = [...state.pinnedModels];
    if (!pins.remove(modelId)) pins.add(modelId);
    if (pins.contains(modelId)) await _catalog.remember([modelId]);
    await _settings.savePinnedModels(pins);
    emit(state.copyWith(pinnedModels: pins, saved: state.saved + 1));
  }

  /// Лимиты вложений меняют только свои поля; остальные лимиты сохраняются как есть.
  Future<void> saveAttachLimits({
    required int perMessage,
    required int maxBytes,
  }) async {
    final limits = (await _settings.limits()).copyWith(
      attachmentsPerMessage: perMessage,
      attachmentMaxBytes: maxBytes,
    );
    await _settings.saveLimits(limits);
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
    await _settings.saveDenylist(patterns);
    emit(state.copyWith(denylist: patterns.join('\n'), saved: state.saved + 1));
  }

  /// Лимиты: JSON проверяется до сохранения. Жёсткие правила (Policy, host key) настройками не отключаются.
  Future<void> saveLimits(String text) async {
    final parsed = _parseLimits(text);
    if (parsed == null) {
      emit(state.copyWith(limitsError: true));
      return;
    }
    await _settings.saveLimits(parsed);
    emit(
      state.copyWith(
        limitsError: false,
        limitsJson: const JsonEncoder.withIndent('  ').convert(parsed.toMap()),
        saved: state.saved + 1,
      ),
    );
  }

  Future<void> _reloadPinned() async {
    final pinned = await _settings.readPinnedModels();
    if (isClosed) return;
    emit(state.copyWith(pinnedModels: pinned));
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
