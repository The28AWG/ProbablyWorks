import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/profiles/profile_service.dart';
import 'package:probably_works/app/router/app_router.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/platform/app_platform.dart';
import 'package:probably_works/features/onboarding/presentation/bloc/onboarding_cubit.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/util/text_clip.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

/// Мастер первого запуска: ключ OpenRouter с проверкой, модель по умолчанию, папка локального Host,
/// необязательный SSH-хост и первый чат. Если локальный провайдер уже настроен, шаг ключа можно пропустить.
@RoutePage()
class OnboardingPage extends StatelessWidget {
  const OnboardingPage({super.key});

  @override
  Widget build(BuildContext context) {
    if (AppPlatform.current.isWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        context.router.replace(const WebConnectRoute());
      });
      return const SizedBox.shrink();
    }
    return BlocProvider(
      create: (_) => OnboardingCubit(
        getIt<AgentSettingsApi>(),
        getIt<ModelCatalogService>(),
        getIt<SettingsRepository>(),
        getIt<HostRepository>(),
        getIt<AgentApi>(),
      ),
      child: const _OnboardingView(),
    );
  }
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
    final theme = Theme.of(context);
    return BlocConsumer<OnboardingCubit, OnboardingState>(
      listenWhen: (previous, current) =>
          current.created != null && previous.created != current.created,
      listener: _onChatCreated,
      builder: (context, state) {
        final cubit = context.read<OnboardingCubit>();
        final steps = cubit.steps;
        final index = steps.indexOf(state.step);
        return AppScaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppLayout.formMaxWidth,
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      l10n.onboardingTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    OnboardingStepper(
                      index: index,
                      total: steps.length,
                      counterLabel: l10n.onboardingStepCounter(
                        index + 1,
                        steps.length,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.xl),
                    Expanded(
                      child: AppCard(
                        padding: const EdgeInsets.all(AppSpacing.xl),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: theme.colorScheme.primaryContainer,
                                    borderRadius: AppRadius.mdAll,
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(
                                      AppSpacing.md,
                                    ),
                                    child: Icon(
                                      _stepIcon(state.step),
                                      color:
                                          theme.colorScheme.onPrimaryContainer,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.md),
                                Expanded(
                                  child: Text(
                                    _stepTitle(state.step, l10n),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleLarge,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.lg),
                            Expanded(
                              child: SingleChildScrollView(
                                child: _content(state, cubit, l10n),
                              ),
                            ),
                            const SizedBox(height: AppSpacing.lg),
                            _controls(state, cubit, l10n),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Онбординг заканчивается открытым первым чатом. Стек сразу строится вложенным, как при выборе чата в оболочке.
  void _onChatCreated(BuildContext context, OnboardingState state) {
    unawaited(
      context.router.replaceAll([
        WorkspaceRoute(
          profileId: getIt<ProfileService>().localProfileId,
          children: [
            ChatsTabRoute(children: [ChatRoute(chatId: state.created!)]),
          ],
        ),
      ]),
    );
  }

  static IconData _stepIcon(OnboardingStep step) => switch (step) {
    OnboardingStep.welcome => Icons.auto_awesome_outlined,
    OnboardingStep.key => Icons.key_outlined,
    OnboardingStep.model => Icons.memory,
    OnboardingStep.workspace => Icons.folder_open,
    OnboardingStep.ssh => Icons.dns_outlined,
    OnboardingStep.finish => Icons.chat_bubble_outline,
  };

  String _stepTitle(OnboardingStep step, AppLocalizations l10n) =>
      switch (step) {
        OnboardingStep.welcome => l10n.onboardingStepWelcome,
        OnboardingStep.key => l10n.onboardingStepKey,
        OnboardingStep.model => l10n.onboardingStepModel,
        OnboardingStep.workspace => l10n.onboardingStepWorkspace,
        OnboardingStep.ssh => l10n.onboardingStepSsh,
        OnboardingStep.finish => l10n.onboardingStepFinish,
      };

  void _onDefaultModelSelected(OnboardingCubit cubit, String? value) {
    if (value != null) cubit.selectModel(value);
  }

  Widget _content(
    OnboardingState state,
    OnboardingCubit cubit,
    AppLocalizations l10n,
  ) => switch (state.step) {
    OnboardingStep.welcome => Text(
      _welcomeText(cubit.platform, l10n),
      style: Theme.of(context).textTheme.bodyLarge,
    ),
    OnboardingStep.key => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.onboardingBody),
        const SizedBox(height: AppSpacing.lg),
        AppTextField(
          controller: _key,
          obscure: true,
          enabled: !state.checking,
          label: l10n.apiKeyLabel,
          hint: l10n.apiKeyHint,
          prefixIcon: Icons.key_outlined,
          onSubmitted: (_) => cubit.verifyKey(_key.text),
        ),
        if (state.checking) ...[
          const SizedBox(height: AppSpacing.md),
          const LinearProgressIndicator(),
        ],
        if (state.keyError != null)
          AppBanner(
            margin: EdgeInsets.zero,
            tone: AppTone.danger,
            icon: Icons.error_outline,
            message: l10n.commonError(
              TextClip.headTail(state.keyError!, maxChars: 300),
            ),
          ),
        if (state.keyVerified)
          AppBanner(
            margin: EdgeInsets.zero,
            tone: AppTone.success,
            icon: Icons.check_circle_outline,
            message: l10n.onboardingKeyVerified(state.models.length),
          )
        else if (state.canSkipKey)
          AppBanner(
            margin: EdgeInsets.zero,
            tone: AppTone.info,
            icon: Icons.info_outline,
            message: l10n.onboardingKeySkipHint,
          ),
      ],
    ),
    OnboardingStep.model => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.onboardingModelHint),
        const SizedBox(height: AppSpacing.lg),
        DropdownMenu<String>(
          expandedInsets: EdgeInsets.zero,
          enableFilter: true,
          initialSelection: state.defaultModel,
          label: Text(
            l10n.settingsDefaultModel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          dropdownMenuEntries: [
            for (final model in state.models)
              if (model.supportsTools)
                DropdownMenuEntry(value: model.id, label: model.name),
          ],
          onSelected: (value) => _onDefaultModelSelected(cubit, value),
        ),
      ],
    ),
    OnboardingStep.workspace => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          cubit.platform.isMobile
              ? l10n.onboardingWorkspaceBodyMobile
              : l10n.onboardingWorkspaceBody,
        ),
        const SizedBox(height: AppSpacing.lg),
        AppTextField(
          controller: _workspace,
          label: l10n.hostDefaultWorkspaceLabel,
          mono: true,
          suffix: cubit.platform.supportsDirectoryPicker
              ? IconButton(
                  tooltip: l10n.hostPickFolder,
                  icon: const Icon(Icons.folder_open),
                  onPressed: _pickWorkspaceFolder,
                )
              : null,
        ),
      ],
    ),
    OnboardingStep.ssh => Text(l10n.onboardingSshBody),
    OnboardingStep.finish => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.chatEmptyState),
        if (!state.canCreate) ...[
          const SizedBox(height: AppSpacing.md),
          AppBanner(
            margin: EdgeInsets.zero,
            tone: AppTone.warning,
            icon: Icons.info_outline,
            message: l10n.onboardingIosSshRequired,
          ),
        ],
      ],
    ),
  };

  static String _welcomeText(AppPlatform platform, AppLocalizations l10n) =>
      switch (platform.target) {
        TargetPlatform.android => l10n.onboardingWelcomeAndroid,
        TargetPlatform.iOS => l10n.onboardingWelcomeIos,
        _ => l10n.onboardingWelcome,
      };

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
        child: Text(
          l10n.onboardingContinue,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      OnboardingStep.key when state.keyVerified || state.canSkipKey =>
        FilledButton(
          onPressed: cubit.next,
          child: Text(
            l10n.onboardingContinue,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      OnboardingStep.key => FilledButton(
        onPressed: state.checking ? null : () => cubit.verifyKey(_key.text),
        child: Text(
          l10n.onboardingVerifyKey,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      OnboardingStep.model => FilledButton(
        onPressed: state.defaultModel == null ? null : cubit.next,
        child: Text(
          l10n.onboardingContinue,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      OnboardingStep.workspace => FilledButton(
        onPressed: () => _continueFromWorkspace(cubit),
        child: Text(
          l10n.onboardingContinue,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      OnboardingStep.ssh => FilledButton(
        onPressed: cubit.next,
        child: Text(
          l10n.onboardingContinue,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      OnboardingStep.finish => FilledButton(
        onPressed: state.created == null && state.canCreate
            ? cubit.createFirstChat
            : null,
        child: Text(
          l10n.onboardingFinish,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    };
    final skippable =
        step == OnboardingStep.model ||
        step == OnboardingStep.workspace ||
        step == OnboardingStep.ssh;
    return Wrap(
      alignment: WrapAlignment.end,
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        if (cubit.steps.indexOf(step) > 0)
          TextButton(
            onPressed: cubit.back,
            child: Text(
              l10n.onboardingBack,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (step == OnboardingStep.ssh)
          OutlinedButton.icon(
            icon: const Icon(Icons.add),
            label: Text(
              l10n.onboardingAddSsh,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: () => context.router.push(
              WorkspaceRoute(
                profileId: getIt<ProfileService>().localProfileId,
                children: [const HostsRoute()],
              ),
            ),
          ),
        if (skippable && step != OnboardingStep.ssh)
          TextButton(
            onPressed: cubit.next,
            child: Text(
              l10n.onboardingSkip,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        primary,
      ],
    );
  }
}
