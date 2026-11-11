import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:pw_agent/agent/loop/agent_hub.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

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
    this.canCreate = true,
  });

  final OnboardingStep step;

  /// Можно создать первый чат: есть локальный Host или хотя бы один SSH-хост.
  final bool canCreate;

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
    bool? canCreate,
  }) => OnboardingState(
    canCreate: canCreate ?? this.canCreate,
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
    canCreate,
  ];
}

class OnboardingCubit extends Cubit<OnboardingState> {
  OnboardingCubit(
    this._secrets,
    this._catalog,
    this._settings,
    this._hosts,
    this._hub, {
    AppPlatform? platform,
  }) : platform = platform ?? AppPlatform.current,
       super(const OnboardingState());

  final SecretStore _secrets;
  final ModelCatalogService _catalog;
  final SettingsRepository _settings;
  final HostRepository _hosts;
  final AgentHub _hub;

  final AppPlatform platform;

  /// Шаги мастера на этой платформе: без локального Host шага папки нет.
  late final List<OnboardingStep> steps = [
    for (final step in OnboardingStep.values)
      if (platform.hasLocalHost || step != OnboardingStep.workspace) step,
  ];

  Future<void> next() async {
    final index = steps.indexOf(state.step);
    if (index < steps.length - 1) {
      emit(state.copyWith(step: steps[index + 1]));
    }
    if (state.step == OnboardingStep.finish) await _refreshCanCreate();
  }

  void back() {
    final index = steps.indexOf(state.step);
    if (index > 0) emit(state.copyWith(step: steps[index - 1]));
  }

  /// На iOS первый чат возможен только на удалённом хосте (SSH или виртуальный): без него кнопка завершения
  /// недоступна.
  Future<void> _refreshCanCreate() async {
    final ready = platform.hasLocalHost || await _firstRemoteHostId() != null;
    emit(state.copyWith(canCreate: ready));
  }

  Future<String?> _firstRemoteHostId() async {
    final hosts = await _hosts.all();
    return preferredRemoteHost(hosts)?.id;
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
      // Успешный ответ сразу попадает в каталог в памяти: чат и Settings увидят модели без повторной загрузки.
      await _catalog.checkKey();
      await _catalog.refresh();
      final models = _catalog.state.models;
      emit(state.copyWith(checking: false, keyVerified: true, models: models));
    } on Object catch (error) {
      if (previous == null) {
        await _secrets.delete(openRouterKeyName);
      } else {
        await _secrets.write(openRouterKeyName, previous);
      }
      emit(
        state.copyWith(
          checking: false,
          keyVerified: false,
          keyError: error is AppFailure ? error.message : '$error',
        ),
      );
    }
  }

  Future<void> selectModel(String id) async {
    await _settings.write(SettingsRepository.keyDefaultModel, id);
    await _catalog.remember([id]);
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
    final hostId = platform.hasLocalHost
        ? await _ensureLocal()
        : await _firstRemoteHostId();
    if (hostId == null) return;
    final chat = await _hub.newChat(hostId: hostId);
    emit(state.copyWith(created: chat.id));
  }

  Future<String> _ensureLocal() async {
    await _hosts.ensureLocalHost(DateTime.now());
    return HostRepository.localHostId;
  }
}
