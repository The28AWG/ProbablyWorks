import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/app/profiles/profile_scope.dart';
import 'package:probably_works/app/theme/theme_controller.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/models/presentation/model_format.dart';
import 'package:probably_works/features/models/presentation/widgets/model_picker_dialog.dart';
import 'package:probably_works/features/settings/presentation/bloc/settings_cubit.dart';
import 'package:probably_works/features/settings/presentation/widgets/agent_profiles_section.dart';
import 'package:probably_works/features/settings/presentation/widgets/api_key_section.dart';
import 'package:probably_works/features/settings/presentation/widgets/mcp_settings_section.dart';
import 'package:probably_works/features/settings/presentation/widgets/model_setting_field.dart';
import 'package:probably_works/features/settings/presentation/widgets/plugin_settings_section.dart';
import 'package:probably_works/features/settings/presentation/widgets/security_audit_section.dart';
import 'package:probably_works/features/settings/presentation/widgets/security_profile_editor.dart';
import 'package:probably_works/features/settings/presentation/widgets/settings_form_row.dart';
import 'package:probably_works/features/workspace/presentation/widgets/workspace_shell.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/chat_api.dart';
import 'package:pw_agent/agent/api/mcp_api.dart';
import 'package:pw_agent/agent/api/plugin_api.dart';
import 'package:pw_agent/agent/api/security_audit_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/steps_display.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';
import 'package:pw_agent/core/config/app_limits.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

@RoutePage()
class SettingsPage extends StatelessWidget {
  const SettingsPage({@PathParam('group') this.initialGroup, super.key});

  /// Начальная группа настроек (например, `safety` при переходе из проекта).
  final String? initialGroup;

  /// Уведомление о запросе переключения группы (для уже открытой страницы настроек).
  static final ValueNotifier<String?> requestedGroup = ValueNotifier<String?>(
    null,
  );

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => SettingsCubit(
      getIt<SettingsRepository>(),
      ProfileScope.maybeOf(context)?.settingsApi ?? getIt<AgentSettingsApi>(),
      getIt<LocaleController>(),
      getIt<ThemeController>(),
    )..load(),
    child: _SettingsView(initialGroup: initialGroup),
  );
}

/// Группы настроек. На широком экране выбирается одна группа слева, на узком — все группы списком.
enum _Group { account, agents, interface, safety, plugins, mcp, advanced }

class _SettingsView extends StatefulWidget {
  const _SettingsView({this.initialGroup});

  final String? initialGroup;

  @override
  State<_SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<_SettingsView> {
  final _denylist = TextEditingController();
  final _limits = TextEditingController();
  final _attachPerMessage = TextEditingController();
  final _attachMaxBytes = TextEditingController();
  String? _attachError;
  bool _initialized = false;
  var _group = _Group.account;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialGroup ?? SettingsPage.requestedGroup.value;
    SettingsPage.requestedGroup.value = null;
    _group = _groupFromName(initial) ?? _Group.account;
    SettingsPage.requestedGroup.addListener(_onRequestedGroup);
    final requested = SettingsPage.requestedGroup.value;
    if (requested != null) {
      final next = _groupFromName(requested);
      if (next != null) _group = next;
      SettingsPage.requestedGroup.value = null;
    }
  }

  void _onRequestedGroup() {
    final requested = SettingsPage.requestedGroup.value;
    if (requested == null) return;
    final next = _groupFromName(requested);
    if (next != null && next != _group) {
      setState(() => _group = next);
    }
    SettingsPage.requestedGroup.value = null;
  }

  @override
  void didUpdateWidget(covariant _SettingsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final initial = widget.initialGroup;
    if (initial != null) {
      final next = _groupFromName(initial);
      if (next != null && next != _group) {
        _group = next;
      }
    }
  }

  @override
  void dispose() {
    SettingsPage.requestedGroup.removeListener(_onRequestedGroup);
    _denylist.dispose();
    _limits.dispose();
    _attachPerMessage.dispose();
    _attachMaxBytes.dispose();
    super.dispose();
  }

  static _Group? _groupFromName(String? name) => switch (name) {
    'account' => _Group.account,
    'agents' => _Group.agents,
    'interface' => _Group.interface,
    'safety' => _Group.safety,
    'plugins' => _Group.plugins,
    'mcp' => _Group.mcp,
    'advanced' => _Group.advanced,
    _ => null,
  };

  void _saveAttachLimits(SettingsCubit cubit, AppLocalizations l10n) {
    final perMessage = int.tryParse(_attachPerMessage.text.trim());
    final maxBytes = int.tryParse(_attachMaxBytes.text.trim());
    if (perMessage == null ||
        perMessage <= 0 ||
        maxBytes == null ||
        maxBytes <= 0) {
      setState(() => _attachError = l10n.settingsAttachInvalid);
      return;
    }
    setState(() => _attachError = null);
    cubit.saveAttachLimits(perMessage: perMessage, maxBytes: maxBytes);
  }

  /// Закрепления в настройках: тот же диалог, что в композере, с кнопками закрепления.
  void _managePins(
    SettingsState state,
    SettingsCubit cubit,
    ModelCatalogSource source,
  ) {
    unawaited(
      showModelPickerDialog(
        context,
        catalog: source,
        pinned: state.pinnedModels,
        currentId: null,
        onTogglePin: (id) => unawaited(cubit.togglePin(id)),
        // Все модели можно закрепить, в том числе без tool calling: закрепление не выбирает модель.
        requireTools: false,
        managePins: true,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scope = ProfileScope.maybeOf(context);
    final source = scope?.chatApi.models ?? getIt<ChatApi>().models;
    final mcpApi = scope?.mcpApi ?? getIt<McpApi>();
    final pluginApi = scope?.pluginApi ?? getIt<PluginApi>();
    final agentApi = scope?.agentApi ?? getIt<AgentApi>();
    final securityAuditApi =
        scope?.securityAuditApi ?? getIt<SecurityAuditApi>();
    return BlocConsumer<SettingsCubit, SettingsState>(
      listenWhen: (previous, current) => current.saved != previous.saved,
      listener: (context, state) =>
          AppSnackBar.show(context, l10n.settingsSaved),
      builder: (context, state) {
        if (!_initialized && state.limitsJson.isNotEmpty) {
          _denylist.text = state.denylist;
          _limits.text = state.limitsJson;
          final limits = AppLimits.parse(state.limitsJson);
          _attachPerMessage.text = '${limits.attachmentsPerMessage}';
          _attachMaxBytes.text = '${limits.attachmentMaxBytes}';
          _initialized = true;
        }
        final cubit = context.read<SettingsCubit>();
        final groups = <_Group, List<Widget>>{
          _Group.account: _accountSections(state, cubit, l10n, source),
          _Group.agents: const [AgentProfilesSection()],
          _Group.interface: _interfaceSections(state, cubit, l10n),
          _Group.safety: _safetySections(state, cubit, l10n, securityAuditApi),
          _Group.plugins: _pluginSections(pluginApi, agentApi),
          _Group.mcp: _mcpSections(mcpApi),
          _Group.advanced: _advancedSections(state, cubit, l10n),
        };
        final titles = <_Group, (String, String)>{
          _Group.account: (
            l10n.settingsGroupAccount,
            l10n.settingsGroupAccountHint,
          ),
          _Group.agents: (
            l10n.settingsGroupAgents,
            l10n.settingsGroupAgentsHint,
          ),
          _Group.interface: (
            l10n.settingsGroupInterface,
            l10n.settingsGroupInterfaceHint,
          ),
          _Group.safety: (
            l10n.settingsGroupSafety,
            l10n.settingsGroupSafetyHint,
          ),
          _Group.plugins: (
            l10n.settingsGroupPlugins,
            l10n.settingsGroupPluginsHint,
          ),
          _Group.mcp: (l10n.settingsGroupMcp, l10n.settingsGroupMcpHint),
          _Group.advanced: (
            l10n.settingsGroupAdvanced,
            l10n.settingsGroupAdvancedHint,
          ),
        };
        return AppScaffold(
          appBar: AppBar(
            leading: context.workspaceLayout == .compact
                ? const WorkspaceLeadingButton()
                : null,
            title: Text(
              l10n.settingsTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          body: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= AppBreakpoints.medium;
              if (wide) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 240,
                      child: ListView(
                        padding: const EdgeInsets.all(AppSpacing.md),
                        children: [
                          for (final group in _Group.values)
                            _GroupTile(
                              icon: _groupIcon(group),
                              title: titles[group]!.$1,
                              selected: group == _group,
                              onTap: () => setState(() => _group = group),
                            ),
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.all(AppSpacing.xl),
                        children: [
                          Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth: AppLayout.pageMaxWidth,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _GroupHeader(
                                    title: titles[_group]!.$1,
                                    hint: titles[_group]!.$2,
                                  ),
                                  const SizedBox(height: AppSpacing.xl),
                                  for (final section in groups[_group]!) ...[
                                    section,
                                    const SizedBox(height: AppSpacing.xl),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              }
              return ListView(
                padding: const EdgeInsets.all(AppSpacing.lg),
                children: [
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: AppLayout.pageMaxWidth,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final group in _Group.values) ...[
                            _GroupHeader(
                              title: titles[group]!.$1,
                              hint: titles[group]!.$2,
                            ),
                            const SizedBox(height: AppSpacing.lg),
                            for (final section in groups[group]!) ...[
                              section,
                              const SizedBox(height: AppSpacing.xl),
                            ],
                            const SizedBox(height: AppSpacing.lg),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  List<Widget> _accountSections(
    SettingsState state,
    SettingsCubit cubit,
    AppLocalizations l10n,
    ModelCatalogSource source,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final catalog = state.catalog;
    return [
      ApiKeySection(state: state, cubit: cubit),
      AppSection(
        title: l10n.settingsDefaultModel,
        children: [
          ModelSettingField(
            modelId: state.defaultModel,
            catalog: catalog,
            source: source,
            pinned: state.pinnedModels,
            onSelected: (id) => cubit.saveModels(
              defaultModel: id,
              titleModel: state.titleModel,
            ),
          ),
        ],
      ),
      AppSection(
        title: l10n.settingsTitleModel,
        children: [
          // Заголовки чатов работают с любой моделью, поэтому tool calling здесь не требуем.
          ModelSettingField(
            modelId: state.titleModel,
            catalog: catalog,
            source: source,
            pinned: state.pinnedModels,
            requireTools: false,
            onSelected: (id) => cubit.saveModels(
              defaultModel: state.defaultModel,
              titleModel: id,
            ),
          ),
        ],
      ),
      AppSection(
        title: l10n.settingsSubagentModel,
        description: l10n.settingsSubagentModelHint,
        children: [
          ModelSettingField(
            modelId: state.subagentModel,
            catalog: catalog,
            source: source,
            pinned: state.pinnedModels,
            onSelected: cubit.saveSubagentModel,
          ),
        ],
      ),
      AppSection(
        title: l10n.settingsFallbackModel,
        description: l10n.settingsFallbackModelHint,
        children: [
          ModelSettingField(
            modelId: state.fallbackModel,
            catalog: catalog,
            source: source,
            pinned: state.pinnedModels,
            onSelected: cubit.saveFallbackModel,
          ),
        ],
      ),
      Row(
        children: [
          OutlinedButton.icon(
            icon: catalog.loading
                ? const SizedBox.square(
                    dimension: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: Text(
              l10n.settingsModelsRefresh,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: catalog.loading ? null : cubit.refreshModels,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: catalog.error != null
                ? Text(
                    l10n.commonError(catalog.error!),
                    style: TextStyle(color: scheme.error),
                  )
                : Text(
                    catalog.syncedAt == null
                        ? l10n.modelsNeverSynced
                        : l10n.modelsSyncedAt(
                            formatModelSyncTime(catalog.syncedAt!),
                          ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
          ),
        ],
      ),
      AppSection(
        title: l10n.settingsPinnedModels,
        description: l10n.settingsPinnedHint,
        trailing: IconButton(
          icon: const Icon(Icons.edit_outlined),
          tooltip: l10n.settingsPinnedManage,
          onPressed: () => _managePins(state, cubit, source),
        ),
        children: [
          if (state.pinnedModels.isEmpty)
            Text(
              l10n.settingsPinnedEmpty,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            )
          else
            Wrap(
              spacing: AppSpacing.xs,
              runSpacing: AppSpacing.xs,
              children: [
                for (final id in state.pinnedModels)
                  InputChip(
                    label: Text(
                      _modelName(id, catalog),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onDeleted: () => cubit.togglePin(id),
                  ),
              ],
            ),
        ],
      ),
    ];
  }

  List<Widget> _interfaceSections(
    SettingsState state,
    SettingsCubit cubit,
    AppLocalizations l10n,
  ) => [
    AppSection(
      title: l10n.settingsLanguage,
      children: [
        AppChoiceGroup<String>(
          options: [
            AppChoiceOption(
              value: 'system',
              title: l10n.settingsLanguageSystem,
              subtitle: l10n.settingsLanguageSystemHint,
              icon: Icon(Icons.phone_android_outlined),
            ),
            AppChoiceOption(
              value: 'en',
              title: 'English',
              subtitle: l10n.settingsLanguageEnglishHint,
              icon: Icon(Icons.translate),
            ),
            AppChoiceOption(
              value: 'ru',
              title: 'Русский',
              subtitle: l10n.settingsLanguageRussianHint,
              icon: Icon(Icons.translate),
            ),
          ],
          selected: state.language,
          onChanged: cubit.saveLanguage,
        ),
      ],
    ),
    AppSection(
      title: l10n.settingsTheme,
      description: l10n.settingsThemeHint,
      children: [
        AppChoiceGroup<ThemeMode>(
          options: [
            AppChoiceOption(
              value: ThemeMode.system,
              title: l10n.settingsThemeSystem,
              subtitle: l10n.settingsThemeSystemHint,
              icon: Icon(Icons.brightness_auto_outlined),
            ),
            AppChoiceOption(
              value: ThemeMode.light,
              title: l10n.settingsThemeLight,
              subtitle: l10n.settingsThemeLightHint,
              icon: Icon(Icons.light_mode_outlined),
            ),
            AppChoiceOption(
              value: ThemeMode.dark,
              title: l10n.settingsThemeDark,
              subtitle: l10n.settingsThemeDarkHint,
              icon: Icon(Icons.dark_mode_outlined),
            ),
          ],
          selected: state.themeMode,
          onChanged: cubit.saveThemeMode,
        ),
      ],
    ),
    AppSection(
      title: l10n.settingsStepsGroup,
      description: l10n.settingsStepsGroupHint,
      children: [
        AppChoiceGroup<bool>(
          options: [
            AppChoiceOption(
              value: true,
              title: l10n.settingsStepsGroupOn,
              subtitle: l10n.settingsStepsGroupOnHint,
            ),
            AppChoiceOption(
              value: false,
              title: l10n.settingsStepsGroupOff,
              subtitle: l10n.settingsStepsGroupOffHint,
            ),
          ],
          selected: state.stepsDisplay.group,
          onChanged: (value) =>
              cubit.saveStepsDisplay(state.stepsDisplay.copyWith(group: value)),
        ),
      ],
    ),
    AppSection(
      title: l10n.settingsStepsExpandWhileActive,
      description: l10n.settingsStepsExpandWhileActiveHint,
      children: [
        AppChoiceGroup<bool>(
          options: [
            AppChoiceOption(
              value: true,
              title: l10n.settingsStepsExpandOn,
              subtitle: l10n.settingsStepsExpandOnHint,
            ),
            AppChoiceOption(
              value: false,
              title: l10n.settingsStepsExpandOff,
              subtitle: l10n.settingsStepsExpandOffHint,
            ),
          ],
          selected: state.stepsDisplay.expandWhileActive,
          onChanged: (value) => cubit.saveStepsDisplay(
            state.stepsDisplay.copyWith(expandWhileActive: value),
          ),
        ),
      ],
    ),
    AppSection(
      title: l10n.settingsStepsThoughts,
      description: l10n.settingsStepsThoughtsHint,
      children: [
        AppChoiceGroup<ThoughtsVisibility>(
          options: [
            AppChoiceOption(
              value: ThoughtsVisibility.current,
              title: l10n.settingsStepsThoughtsCurrent,
              subtitle: l10n.settingsStepsThoughtsCurrentHint,
            ),
            AppChoiceOption(
              value: ThoughtsVisibility.all,
              title: l10n.settingsStepsHide,
              subtitle: l10n.settingsStepsThoughtsHideHint,
            ),
            AppChoiceOption(
              value: ThoughtsVisibility.expanded,
              title: l10n.settingsStepsThoughtsAll,
              subtitle: l10n.settingsStepsThoughtsAllHint,
            ),
          ],
          selected: state.stepsDisplay.thoughts,
          onChanged: (value) => cubit.saveStepsDisplay(
            state.stepsDisplay.copyWith(thoughts: value),
          ),
        ),
      ],
    ),
    AppSection(
      title: l10n.settingsStepsTools,
      description: l10n.settingsStepsToolsHint,
      children: [
        AppChoiceGroup<ToolsVisibility>(
          options: [
            AppChoiceOption(
              value: ToolsVisibility.active,
              title: l10n.settingsStepsToolsActive,
              subtitle: l10n.settingsStepsToolsActiveHint,
            ),
            AppChoiceOption(
              value: ToolsVisibility.all,
              title: l10n.settingsStepsHide,
              subtitle: l10n.settingsStepsToolsHideHint,
            ),
            AppChoiceOption(
              value: ToolsVisibility.expanded,
              title: l10n.settingsStepsToolsAll,
              subtitle: l10n.settingsStepsToolsAllHint,
            ),
          ],
          selected: state.stepsDisplay.tools,
          onChanged: (value) =>
              cubit.saveStepsDisplay(state.stepsDisplay.copyWith(tools: value)),
        ),
      ],
    ),
  ];

  Future<void> _resetSecurityProfile(
    SettingsCubit cubit,
    AppLocalizations l10n,
  ) async {
    final confirmed = await ConfirmDialog.confirm(
      context,
      title: l10n.securityResetAllTitle,
      message: l10n.securityResetAllMessage,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.securityResetAll,
      destructive: true,
    );
    if (!confirmed || !mounted) return;
    await cubit.saveSecurityProfile(const SecurityProfile());
  }

  List<Widget> _safetySections(
    SettingsState state,
    SettingsCubit cubit,
    AppLocalizations l10n,
    SecurityAuditApi securityAuditApi,
  ) => [
    AppSection(
      title: l10n.settingsDefaultPolicy,
      children: [
        AppChoiceGroup<PolicyMode>(
          options: [
            AppChoiceOption(
              value: PolicyMode.ask,
              title: l10n.policyAsk,
              subtitle: l10n.policyAskHint,
              icon: Icon(Icons.front_hand_outlined),
            ),
            AppChoiceOption(
              value: PolicyMode.yolo,
              title: l10n.policyYolo,
              subtitle: l10n.policyYoloHint,
              icon: Icon(Icons.bolt_outlined),
            ),
          ],
          selected: state.defaultPolicy,
          onChanged: cubit.saveDefaultPolicy,
        ),
      ],
    ),
    AppSection(
      title: l10n.securityProfileTitle,
      description: l10n.securityProfileHint,
      trailing: TextButton(
        onPressed: () => _resetSecurityProfile(cubit, l10n),
        child: Text(
          l10n.securityResetAll,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      children: [
        SecurityProfileEditor(
          profile: state.securityProfile,
          denylist: state.denylist,
          onChanged: cubit.saveSecurityProfile,
        ),
      ],
    ),
    SecurityAuditSection(api: securityAuditApi),
    AppCard(
      child: SettingsFormRow(
        title: l10n.settingsDenylist,
        description: l10n.settingsDenylistHint,
        action: FilledButton(
          onPressed: () => cubit.saveDenylist(_denylist.text),
          child: Text(
            l10n.commonSave,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        child: AppTextField(
          controller: _denylist,
          minLines: 3,
          maxLines: 8,
          mono: true,
        ),
      ),
    ),
  ];

  List<Widget> _pluginSections(PluginApi pluginApi, AgentApi agentApi) => [
    PluginSettingsSection(api: pluginApi, agentApi: agentApi),
  ];

  List<Widget> _mcpSections(McpApi api) => [McpSettingsSection(api: api)];

  List<Widget> _advancedSections(
    SettingsState state,
    SettingsCubit cubit,
    AppLocalizations l10n,
  ) => [
    AppCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SettingsFormRow(
            title: l10n.settingsAttachLimits,
            description: l10n.settingsAttachLimitsHint,
            action: FilledButton(
              onPressed: () => _saveAttachLimits(cubit, l10n),
              child: Text(
                l10n.commonSave,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: AppTextField(
                    controller: _attachPerMessage,
                    suffixText: l10n.settingsAttachUnitFiles,
                    error: _attachError,
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: AppTextField(
                    controller: _attachMaxBytes,
                    suffixText: l10n.settingsAttachUnitBytes,
                    error: _attachError,
                    keyboardType: TextInputType.number,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: AppSpacing.xl),
          SettingsFormRow(
            title: l10n.settingsLimits,
            description: l10n.settingsLimitsHelper,
            action: FilledButton(
              onPressed: () => cubit.saveLimits(_limits.text),
              child: Text(
                l10n.commonSave,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            child: AppTextField(
              controller: _limits,
              minLines: 6,
              maxLines: 16,
              mono: true,
              error: state.limitsError ? l10n.settingsLimitsInvalid : null,
            ),
          ),
        ],
      ),
    ),
  ];

  static IconData _groupIcon(_Group group) => switch (group) {
    _Group.account => Icons.key_outlined,
    _Group.agents => Icons.devices_other_outlined,
    _Group.interface => Icons.translate,
    _Group.safety => Icons.shield_outlined,
    _Group.plugins => Icons.extension_outlined,
    _Group.mcp => Icons.cable_outlined,
    _Group.advanced => Icons.tune,
  };
}

class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleLarge,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          hint,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _GroupTile extends StatelessWidget {
  const _GroupTile({
    required this.icon,
    required this.title,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: AppRadius.mdAll,
        child: InkWell(
          borderRadius: AppRadius.mdAll,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              children: [
                Icon(icon, size: 20),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Подпись закреплённой модели: недоступная помечается `!`.
String _modelName(String id, ModelCatalogState catalog) =>
    catalog.statusOf(id) == ModelStatus.unavailable
    ? '! ${catalog.nameOf(id)}'
    : catalog.nameOf(id);
