import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Шаги мастера первого запуска. Порядок важен: индекс шага — текущая позиция в Stepper.
enum OnboardingStep { welcome, key, model, workspace, ssh, finish }

class OnboardingState extends Equatable {
  const OnboardingState({
    this.step = OnboardingStep.welcome,
    this.checking = false,
    this.keyVerified = false,
    this.keyError,
    this.models = const [],
    this.defaultModel,
    this.workspace,
    this.created,
  });

  final OnboardingStep step;

  /// Идёт проверка ключа запросом списка моделей.
  final bool checking;
  final bool keyVerified;
  final String? keyError;
  final List<LlmModelInfo> models;
  final String? defaultModel;

  /// Сохранённая рабочая папка локального Host.
  final String? workspace;

  /// Id созданного первого чата: мастер завершён.
  final String? created;

  OnboardingState copyWith({
    OnboardingStep? step,
    bool? checking,
    bool? keyVerified,
    String? keyError,
    bool clearKeyError = false,
    List<LlmModelInfo>? models,
    String? defaultModel,
    String? workspace,
    String? created,
  }) => OnboardingState(
    step: step ?? this.step,
    checking: checking ?? this.checking,
    keyVerified: keyVerified ?? this.keyVerified,
    keyError: clearKeyError ? null : (keyError ?? this.keyError),
    models: models ?? this.models,
    defaultModel: defaultModel ?? this.defaultModel,
    workspace: workspace ?? this.workspace,
    created: created ?? this.created,
  );

  @override
  List<Object?> get props => [
    step,
    checking,
    keyVerified,
    keyError,
    models,
    defaultModel,
    workspace,
    created,
  ];
}

class OnboardingCubit extends Cubit<OnboardingState> {
  OnboardingCubit(
    this._secrets,
    this._llm,
    this._settings,
    this._hosts,
    this._hub,
  ) : super(const OnboardingState());

  final SecretStore _secrets;
  final LlmProvider _llm;
  final SettingsRepository _settings;
  final HostRepository _hosts;
  final AgentHub _hub;

  void next() {
    final index = state.step.index;
    if (index < OnboardingStep.values.length - 1) {
      emit(state.copyWith(step: OnboardingStep.values[index + 1]));
    }
  }

  void back() {
    final index = state.step.index;
    if (index > 0) emit(state.copyWith(step: OnboardingStep.values[index - 1]));
  }

  /// Ключ сохраняется, только если им действительно можно загрузить список моделей.
  /// Иначе прежнее значение возвращается, чтобы guard не пустил в приложение с неработающим ключом.
  Future<void> verifyKey(String key) async {
    final value = key.trim();
    if (value.isEmpty) return;
    emit(state.copyWith(checking: true, clearKeyError: true));
    final previous = await _secrets.read(openRouterKeyName);
    await _secrets.write(openRouterKeyName, value);
    try {
      final models = await _llm.listModels();
      emit(state.copyWith(checking: false, keyVerified: true, models: models));
    } on Object catch (error) {
      if (previous == null) {
        await _secrets.delete(openRouterKeyName);
      } else {
        await _secrets.write(openRouterKeyName, previous);
      }
      emit(
        state.copyWith(checking: false, keyVerified: false, keyError: '$error'),
      );
    }
  }

  Future<void> selectModel(String id) async {
    await _settings.write(SettingsRepository.keyDefaultModel, id);
    emit(state.copyWith(defaultModel: id));
  }

  /// Рабочая папка локального Host: новые чаты на нём стартуют в ней.
  Future<void> saveWorkspace(String path) async {
    final value = path.trim();
    if (value.isEmpty) return;
    await _hosts.ensureLocalHost(DateTime.now());
    final local = await _hosts.byId(HostRepository.localHostId);
    if (local == null) return;
    await _hosts.save(local.copyWith(defaultWorkspace: value));
    emit(state.copyWith(workspace: value));
  }

  Future<void> createFirstChat() async {
    await _hosts.ensureLocalHost(DateTime.now());
    final chat = await _hub.newChat(hostId: HostRepository.localHostId);
    emit(state.copyWith(created: chat.id));
  }
}
