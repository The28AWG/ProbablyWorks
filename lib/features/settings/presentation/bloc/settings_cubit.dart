import 'dart:convert';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

class SettingsState extends Equatable {
  const SettingsState({
    this.apiKeySet = false,
    this.models = const [],
    this.modelsLoading = false,
    this.modelsError,
    this.defaultModel = '',
    this.titleModel = '',
    this.language = 'system',
    this.defaultPolicy = PolicyMode.ask,
    this.denylist = '',
    this.limitsJson = '',
    this.limitsError = false,
    this.pinnedModels = const [],
    this.saved = 0,
  });

  final bool apiKeySet;
  final List<LlmModelInfo> models;
  final bool modelsLoading;
  final String? modelsError;
  final String defaultModel;
  final String titleModel;
  final String language;
  final PolicyMode defaultPolicy;
  final String denylist;
  final String limitsJson;
  final bool limitsError;

  /// Закреплённые id моделей (порядок — порядок добавления).
  final List<String> pinnedModels;

  /// Увеличивается при каждом сохранении: страница показывает снекбар по изменению.
  final int saved;

  SettingsState copyWith({
    bool? apiKeySet,
    List<LlmModelInfo>? models,
    bool? modelsLoading,
    String? modelsError,
    bool clearModelsError = false,
    String? defaultModel,
    String? titleModel,
    String? language,
    PolicyMode? defaultPolicy,
    String? denylist,
    String? limitsJson,
    bool? limitsError,
    List<String>? pinnedModels,
    int? saved,
  }) => SettingsState(
    apiKeySet: apiKeySet ?? this.apiKeySet,
    models: models ?? this.models,
    modelsLoading: modelsLoading ?? this.modelsLoading,
    modelsError: clearModelsError ? null : (modelsError ?? this.modelsError),
    defaultModel: defaultModel ?? this.defaultModel,
    titleModel: titleModel ?? this.titleModel,
    language: language ?? this.language,
    defaultPolicy: defaultPolicy ?? this.defaultPolicy,
    denylist: denylist ?? this.denylist,
    limitsJson: limitsJson ?? this.limitsJson,
    limitsError: limitsError ?? this.limitsError,
    pinnedModels: pinnedModels ?? this.pinnedModels,
    saved: saved ?? this.saved,
  );

  @override
  List<Object?> get props => [
    apiKeySet,
    models,
    modelsLoading,
    modelsError,
    defaultModel,
    titleModel,
    language,
    defaultPolicy,
    denylist,
    limitsJson,
    limitsError,
    pinnedModels,
    saved,
  ];
}

class SettingsCubit extends Cubit<SettingsState> {
  SettingsCubit(this._settings, this._secrets, this._llm, this._locale)
    : super(const SettingsState());

  final SettingsRepository _settings;
  final SecretStore _secrets;
  final LlmProvider _llm;
  final LocaleController _locale;

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
      ),
    );
    await refreshModels();
  }

  Future<void> saveApiKey(String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) return;
    await _secrets.write(openRouterKeyName, trimmed);
    emit(state.copyWith(apiKeySet: true, saved: state.saved + 1));
    await refreshModels();
  }

  Future<void> refreshModels() async {
    emit(state.copyWith(modelsLoading: true, clearModelsError: true));
    try {
      final models = await _llm.listModels();
      emit(state.copyWith(models: models, modelsLoading: false));
    } on Object catch (error) {
      emit(state.copyWith(modelsLoading: false, modelsError: '$error'));
    }
  }

  Future<void> saveModels({
    required String defaultModel,
    required String titleModel,
  }) async {
    await _settings.write(SettingsRepository.keyDefaultModel, defaultModel);
    await _settings.write(SettingsRepository.keyTitleModel, titleModel);
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

  Future<void> togglePin(String modelId) async {
    final pins = [...state.pinnedModels];
    if (!pins.remove(modelId)) pins.add(modelId);
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
