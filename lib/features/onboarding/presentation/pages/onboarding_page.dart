import 'package:auto_route/auto_route.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/loop/agent_hub.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/core/data/host_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/core/util/text_clip.dart';
import 'package:probably_works/features/onboarding/presentation/bloc/onboarding_cubit.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Мастер первого запуска: ключ OpenRouter с проверкой, модель по умолчанию, папка локального Host,
/// необязательный SSH-хост и первый чат. Без рабочего ключа приложение не пускает дальше настроек.
@RoutePage()
class OnboardingPage extends StatelessWidget {
  const OnboardingPage({super.key});

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => OnboardingCubit(
      getIt<SecretStore>(),
      getIt<LlmProvider>(),
      getIt<SettingsRepository>(),
      getIt<HostRepository>(),
      getIt<AgentHub>(),
    ),
    child: const _OnboardingView(),
  );
}

class _OnboardingView extends StatefulWidget {
  const _OnboardingView();

  @override
  State<_OnboardingView> createState() => _OnboardingViewState();
}

class _OnboardingViewState extends State<_OnboardingView> {
  final _key = TextEditingController();
  final _workspace = TextEditingController();

  @override
  void dispose() {
    _key.dispose();
    _workspace.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlocConsumer<OnboardingCubit, OnboardingState>(
      listenWhen: (previous, current) =>
          current.created != null && previous.created != current.created,
      listener: _onChatCreated,
      builder: (context, state) {
        final cubit = context.read<OnboardingCubit>();
        return Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640),
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  Text(
                    l10n.onboardingTitle,
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 12),
                  Stepper(
                    currentStep: state.step.index,
                    controlsBuilder: (_, _) => const SizedBox.shrink(),
                    steps: [
                      for (final step in OnboardingStep.values)
                        Step(
                          title: Text(_stepTitle(step, l10n)),
                          isActive: step == state.step,
                          state: step.index < state.step.index
                              ? StepState.complete
                              : StepState.indexed,
                          content: step == state.step
                              ? _content(step, state, cubit, l10n)
                              : const SizedBox.shrink(),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _controls(state, cubit, l10n),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _onChatCreated(BuildContext context, OnboardingState state) {
    context.router.replace(const WorkspaceRoute());
    context.router.push(ChatRoute(chatId: state.created!));
  }

  String _stepTitle(OnboardingStep step, AppLocalizations l10n) =>
      switch (step) {
        OnboardingStep.welcome => l10n.onboardingStepWelcome,
        OnboardingStep.key => l10n.onboardingStepKey,
        OnboardingStep.model => l10n.onboardingStepModel,
        OnboardingStep.workspace => l10n.onboardingStepWorkspace,
        OnboardingStep.ssh => l10n.onboardingStepSsh,
        OnboardingStep.finish => l10n.onboardingStepFinish,
      };

  Widget _content(
    OnboardingStep step,
    OnboardingState state,
    OnboardingCubit cubit,
    AppLocalizations l10n,
  ) => switch (step) {
    OnboardingStep.welcome => Text(l10n.onboardingWelcome),
    OnboardingStep.key => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.onboardingBody),
        const SizedBox(height: 12),
        TextField(
          controller: _key,
          obscureText: true,
          enabled: !state.checking,
          onSubmitted: (_) => cubit.verifyKey(_key.text),
          decoration: InputDecoration(
            labelText: l10n.apiKeyLabel,
            hintText: l10n.apiKeyHint,
          ),
        ),
        const SizedBox(height: 8),
        if (state.checking) const LinearProgressIndicator(),
        if (state.keyError != null)
          Text(
            l10n.commonError(TextClip.headTail(state.keyError!, maxChars: 300)),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (state.keyVerified)
          Text(l10n.onboardingKeyVerified(state.models.length)),
      ],
    ),
    OnboardingStep.model => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.onboardingModelHint),
        const SizedBox(height: 12),
        DropdownMenu<String>(
          width: 480,
          enableFilter: true,
          initialSelection: state.defaultModel,
          label: Text(l10n.settingsDefaultModel),
          dropdownMenuEntries: [
            for (final model in state.models)
              if (model.supportsTools)
                DropdownMenuEntry(value: model.id, label: model.name),
          ],
          onSelected: (value) => _onModelSelected(cubit, value),
        ),
      ],
    ),
    OnboardingStep.workspace => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.onboardingWorkspaceBody),
        const SizedBox(height: 12),
        TextField(
          controller: _workspace,
          decoration: InputDecoration(
            labelText: l10n.hostDefaultWorkspaceLabel,
            suffixIcon: IconButton(
              tooltip: l10n.hostPickFolder,
              icon: const Icon(Icons.folder_open),
              onPressed: _pickWorkspaceFolder,
            ),
          ),
        ),
      ],
    ),
    OnboardingStep.ssh => Text(l10n.onboardingSshBody),
    OnboardingStep.finish => Text(l10n.chatEmptyState),
  };

  void _onModelSelected(OnboardingCubit cubit, String? value) {
    if (value != null) cubit.selectModel(value);
  }

  Future<void> _pickWorkspaceFolder() async {
    final path = await getDirectoryPath();
    if (!mounted) return;
    if (path != null) setState(() => _workspace.text = path);
  }

  Future<void> _continueFromWorkspace(OnboardingCubit cubit) async {
    await cubit.saveWorkspace(_workspace.text);
    cubit.next();
  }

  Widget _controls(
    OnboardingState state,
    OnboardingCubit cubit,
    AppLocalizations l10n,
  ) {
    final step = state.step;
    final primary = switch (step) {
      OnboardingStep.welcome => FilledButton(
        onPressed: cubit.next,
        child: Text(l10n.onboardingContinue),
      ),
      OnboardingStep.key when state.keyVerified => FilledButton(
        onPressed: cubit.next,
        child: Text(l10n.onboardingContinue),
      ),
      OnboardingStep.key => FilledButton(
        onPressed: state.checking ? null : () => cubit.verifyKey(_key.text),
        child: Text(l10n.onboardingVerifyKey),
      ),
      OnboardingStep.model => FilledButton(
        onPressed: state.defaultModel == null ? null : cubit.next,
        child: Text(l10n.onboardingContinue),
      ),
      OnboardingStep.workspace => FilledButton(
        onPressed: () => _continueFromWorkspace(cubit),
        child: Text(l10n.onboardingContinue),
      ),
      OnboardingStep.ssh => FilledButton(
        onPressed: cubit.next,
        child: Text(l10n.onboardingContinue),
      ),
      OnboardingStep.finish => FilledButton(
        onPressed: state.created == null ? cubit.createFirstChat : null,
        child: Text(l10n.onboardingFinish),
      ),
    };
    final skippable =
        step == OnboardingStep.model ||
        step == OnboardingStep.workspace ||
        step == OnboardingStep.ssh;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: 8,
      runSpacing: 8,
      children: [
        if (step.index > 0)
          TextButton(onPressed: cubit.back, child: Text(l10n.onboardingBack)),
        if (step == OnboardingStep.ssh)
          OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: Text(l10n.onboardingAddSsh),
            onPressed: () => context.router.push(const HostsRoute()),
          ),
        if (skippable && step != OnboardingStep.ssh)
          TextButton(onPressed: cubit.next, child: Text(l10n.onboardingSkip)),
        primary,
      ],
    );
  }
}
