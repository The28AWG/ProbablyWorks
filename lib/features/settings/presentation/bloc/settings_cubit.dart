import 'dart:async';
import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/domain/steps_display.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/providers/ai/model_catalog.dart';

class SettingsState extends Equatable {
  const SettingsState({
    this.apiKeySet = false,
    this.catalog = const ModelCatalogState(),
    this.defaultModel = '',
    this.titleModel = '',
    this.language = 'system',
    this.defaultPolicy = PolicyMode.ask,
    this.denylist = '',
    this.limitsJson = '',
    this.limitsError = false,
    this.pinnedModels = const [],
    this.stepsDisplay = StepsDisplay.defaults,
    this.saved = 0,
  });

  final bool apiKeySet;

  /// Каталог моделей: список, статус загрузки и сохранённые детали выбранных моделей.
  final ModelCatalogState catalog;
  final String defaultModel;
  final String titleModel;
  final String language;
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
    bool? apiKeySet,
    ModelCatalogState? catalog,
    String? defaultModel,
    String? titleModel,
    String? language,
    PolicyMode? defaultPolicy,
    String? denylist,
    String? limitsJson,
    bool? limitsError,
    List<String>? pinnedModels,
    StepsDisplay? stepsDisplay,
    int? saved,
  }) => SettingsState(
    apiKeySet: apiKeySet ?? this.apiKeySet,
    catalog: catalog ?? this.catalog,
    defaultModel: defaultModel ?? this.defaultModel,
    titleModel: titleModel ?? this.titleModel,
    language: language ?? this.language,
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
    apiKeySet,
    catalog,
    defaultModel,
    titleModel,
    language,
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
  SettingsCubit(this._settings, this._secrets, this._catalog, this._locale)
    : super(const SettingsState());

  final SettingsRepository _settings;
  final SecretStore _secrets;
  final ModelCatalogService _catalog;
  final LocaleController _locale;
  StreamSubscription<ModelCatalogState>? _catalogSub;

  @override
  Future<void> close() async {
    await _catalogSub?.cancel();
    return super.close();
  }

  Future<void> load() async {
    final limits = await _settings.limits();
    emit(
      state.copyWith(
        apiKeySet:
            (await _secrets.read(openRouterKeyName))?.isNotEmpty ?? false,
        defaultModel:
            await _settings.read(SettingsRepository.keyDefaultModel) ?? '',
        titleModel:
            await _settings.read(SettingsRepository.keyTitleModel) ?? '',
        language:
            await _settings.read(SettingsRepository.keyLanguage) ?? 'system',
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
    if (!_catalog.state.loaded && state.apiKeySet) await refreshModels();
  }

  Future<void> saveApiKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return;
    await _secrets.write(openRouterKeyName, trimmed);
    emit(state.copyWith(apiKeySet: true, saved: state.saved + 1));
    await refreshModels();
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

  AppLimits? _parseLimits(String text) {
    try {
      return AppLimits.parse(text);
    } on FormatException {
      return null;
    }
  }
}
