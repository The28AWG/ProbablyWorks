import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/domain/steps_display.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/core/util/text_clip.dart';
import 'package:probably_works/features/models/presentation/model_format.dart';
import 'package:probably_works/features/settings/presentation/bloc/settings_cubit.dart';
import 'package:probably_works/features/workspace/presentation/widgets/workspace_shell.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/providers/ai/llm_port.dart';
import 'package:probably_works/providers/ai/model_catalog.dart';

@RoutePage()
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => SettingsCubit(
      getIt<SettingsRepository>(),
      getIt<SecretStore>(),
      getIt<ModelCatalogService>(),
      getIt<LocaleController>(),
    )..load(),
    child: const _SettingsView(),
  );
}

/// Группы настроек. На широком экране выбирается одна группа слева, на узком — все группы списком.
enum _Group { account, interface, safety, advanced }

class _SettingsView extends StatefulWidget {
  const _SettingsView();

  @override
  State<_SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<_SettingsView> {
  final _apiKey = TextEditingController();
  final _denylist = TextEditingController();
  final _limits = TextEditingController();
  final _attachPerMessage = TextEditingController();
  final _attachMaxBytes = TextEditingController();
  String? _attachError;
  bool _initialized = false;
  var _group = _Group.account;

  @override
  void dispose() {
    _apiKey.dispose();
    _denylist.dispose();
    _limits.dispose();
    _attachPerMessage.dispose();
    _attachMaxBytes.dispose();
    super.dispose();
  }

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

  Future<void> _saveApiKey(SettingsCubit cubit) async {
    await cubit.saveApiKey(_apiKey.text);
    _apiKey.clear();
  }

  void _onPinModelSelected(SettingsCubit cubit, String? value) {
    if (value != null) cubit.togglePin(value);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
          _Group.account: _accountSections(state, cubit, l10n),
          _Group.interface: _interfaceSections(state, cubit, l10n),
          _Group.safety: _safetySections(state, cubit, l10n),
          _Group.advanced: _advancedSections(state, cubit, l10n),
        };
        final titles = <_Group, (String, String)>{
          _Group.account: (
            l10n.settingsGroupAccount,
            l10n.settingsGroupAccountHint,
          ),
          _Group.interface: (
            l10n.settingsGroupInterface,
            l10n.settingsGroupInterfaceHint,
          ),
          _Group.safety: (
            l10n.settingsGroupSafety,
            l10n.settingsGroupSafetyHint,
          ),
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
            title: Text(l10n.settingsTitle),
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

  /// Записи выпадающего списка модели. Выбранная модель, которой нет в загруженном списке, добавляется
  /// неактивной записью с сохранённым названием: поле сразу показывает модель, а не пустое значение.
  static List<DropdownMenuEntry<String>> _modelEntries(
    String selected,
    ModelCatalogState catalog,
    AppLocalizations l10n, {
    required bool withTools,
  }) => [
    for (final m in catalog.models)
      DropdownMenuEntry(
        value: m.id,
        label: _entryLabel(m, l10n, withTools: withTools),
        enabled: !withTools || m.supportsTools,
      ),
    if (selected.isNotEmpty && catalog.modelOf(selected) == null)
      DropdownMenuEntry(
        value: selected,
        label: catalog.loaded
            ? '! ${catalog.nameOf(selected)}'
            : catalog.nameOf(selected),
        enabled: false,
      ),
  ];

  static String _entryLabel(
    LlmModelInfo model,
    AppLocalizations l10n, {
    required bool withTools,
  }) {
    if (withTools && !model.supportsTools) {
      return '${model.name} · ${l10n.modelNoTools}';
    }
    return model.name;
  }

  List<Widget> _accountSections(
    SettingsState state,
    SettingsCubit cubit,
    AppLocalizations l10n,
  ) {
    final scheme = Theme.of(context).colorScheme;
    // Модель по умолчанию ведёт агента, поэтому без tool calling она недоступна; для заголовков подходит любая.
    final catalog = state.catalog;
    final defaultEntries = _modelEntries(
      state.defaultModel,
      catalog,
      l10n,
      withTools: true,
    );
    final titleEntries = _modelEntries(
      state.titleModel,
      catalog,
      l10n,
      withTools: false,
    );
    final defaultLacksTools = catalog.models.any(
      (m) => m.id == state.defaultModel && !m.supportsTools,
    );
    final defaultUnavailable =
        catalog.statusOf(state.defaultModel) == ModelStatus.unavailable;
    final titleUnavailable =
        catalog.statusOf(state.titleModel) == ModelStatus.unavailable;
    final unpinned = [
      for (final m in catalog.models)
        if (!state.pinnedModels.contains(m.id))
          DropdownMenuEntry(value: m.id, label: m.name),
    ];
    return [
      AppSection(
        title: l10n.settingsApiKey,
        trailing: FilledButton(
          onPressed: () => _saveApiKey(cubit),
          child: Text(l10n.commonSave),
        ),
        children: [
          AppTextField(
            controller: _apiKey,
            obscure: true,
            label: l10n.apiKeyLabel,
            hint: state.apiKeySet ? '••••••••' : l10n.apiKeyHint,
            prefixIcon: Icons.key_outlined,
          ),
          if (state.keyError != null)
            AppBanner(
              margin: EdgeInsets.zero,
              tone: AppTone.danger,
              icon: Icons.error_outline,
              message: l10n.commonError(
                TextClip.headTail(state.keyError!, maxChars: 300),
              ),
            ),
        ],
      ),
      AppSection(
        title: l10n.settingsDefaultModel,
        children: [
          DropdownMenu<String>(
            expandedInsets: EdgeInsets.zero,
            enableFilter: true,
            initialSelection: state.defaultModel.isEmpty
                ? null
                : state.defaultModel,
            dropdownMenuEntries: defaultEntries,
            trailingIcon: catalog.initialLoading
                ? const _LoadingSpinner()
                : null,
            label: Text(l10n.settingsDefaultModel),
            onSelected: (value) => cubit.saveModels(
              defaultModel: value ?? '',
              titleModel: state.titleModel,
            ),
          ),
          if (defaultLacksTools)
            Text(
              l10n.settingsNoToolsWarning,
              style: TextStyle(color: scheme.error),
            ),
          if (defaultUnavailable)
            Text(
              l10n.settingsModelUnavailable,
              style: TextStyle(color: scheme.error),
            ),
          DropdownMenu<String>(
            expandedInsets: EdgeInsets.zero,
            enableFilter: true,
            initialSelection: state.titleModel.isEmpty
                ? null
                : state.titleModel,
            dropdownMenuEntries: titleEntries,
            trailingIcon: catalog.initialLoading
                ? const _LoadingSpinner()
                : null,
            label: Text(l10n.settingsTitleModel),
            onSelected: (value) => cubit.saveModels(
              defaultModel: state.defaultModel,
              titleModel: value ?? '',
            ),
          ),
          if (titleUnavailable)
            Text(
              l10n.settingsModelUnavailable,
              style: TextStyle(color: scheme.error),
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
                label: Text(l10n.settingsModelsRefresh),
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
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
              ),
            ],
          ),
        ],
      ),
      AppSection(
        title: l10n.settingsPinnedModels,
        description: l10n.settingsPinnedHint,
        children: [
          Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final id in state.pinnedModels)
                InputChip(
                  label: Text(_modelName(id, catalog)),
                  onDeleted: () => cubit.togglePin(id),
                ),
            ],
          ),
          DropdownMenu<String>(
            key: ValueKey('pin-${state.pinnedModels.length}'),
            expandedInsets: EdgeInsets.zero,
            enableFilter: true,
            label: Text(l10n.settingsPinnedModels),
            dropdownMenuEntries: unpinned,
            onSelected: (value) => _onPinModelSelected(cubit, value),
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
        DropdownMenu<String>(
          expandedInsets: EdgeInsets.zero,
          initialSelection: state.language,
          label: Text(l10n.settingsLanguage),
          dropdownMenuEntries: [
            DropdownMenuEntry(
              value: 'system',
              label: l10n.settingsLanguageSystem,
            ),
            const DropdownMenuEntry(value: 'en', label: 'English'),
            const DropdownMenuEntry(value: 'ru', label: 'Русский'),
          ],
          onSelected: (value) => cubit.saveLanguage(value ?? 'system'),
        ),
      ],
    ),
    AppSection(
      title: l10n.settingsStepsGroup,
      description: l10n.settingsStepsGroupHint,
      children: [
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: true, label: Text(l10n.settingsStepsGroupOn)),
            ButtonSegment(
              value: false,
              label: Text(l10n.settingsStepsGroupOff),
            ),
          ],
          selected: {state.stepsDisplay.group},
          onSelectionChanged: (value) => cubit.saveStepsDisplay(
            state.stepsDisplay.copyWith(group: value.first),
          ),
        ),
      ],
    ),
    AppSection(
      title: l10n.settingsStepsExpandWhileActive,
      description: l10n.settingsStepsExpandWhileActiveHint,
      children: [
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: true, label: Text(l10n.settingsStepsExpandOn)),
            ButtonSegment(
              value: false,
              label: Text(l10n.settingsStepsExpandOff),
            ),
          ],
          selected: {state.stepsDisplay.expandWhileActive},
          onSelectionChanged: (value) => cubit.saveStepsDisplay(
            state.stepsDisplay.copyWith(expandWhileActive: value.first),
          ),
        ),
      ],
    ),
    AppSection(
      title: l10n.settingsStepsThoughts,
      description: l10n.settingsStepsThoughtsHint,
      children: [
        SegmentedButton<ThoughtsVisibility>(
          segments: [
            ButtonSegment(
              value: ThoughtsVisibility.current,
              label: Text(l10n.settingsStepsThoughtsCurrent),
            ),
            ButtonSegment(
              value: ThoughtsVisibility.all,
              label: Text(l10n.settingsStepsHide),
            ),
            ButtonSegment(
              value: ThoughtsVisibility.expanded,
              label: Text(l10n.settingsStepsThoughtsAll),
            ),
          ],
          selected: {state.stepsDisplay.thoughts},
          onSelectionChanged: (value) => cubit.saveStepsDisplay(
            state.stepsDisplay.copyWith(thoughts: value.first),
          ),
        ),
      ],
    ),
    AppSection(
      title: l10n.settingsStepsTools,
      description: l10n.settingsStepsToolsHint,
      children: [
        SegmentedButton<ToolsVisibility>(
          segments: [
            ButtonSegment(
              value: ToolsVisibility.active,
              label: Text(l10n.settingsStepsToolsActive),
            ),
            ButtonSegment(
              value: ToolsVisibility.all,
              label: Text(l10n.settingsStepsHide),
            ),
            ButtonSegment(
              value: ToolsVisibility.expanded,
              label: Text(l10n.settingsStepsToolsAll),
            ),
          ],
          selected: {state.stepsDisplay.tools},
          onSelectionChanged: (value) => cubit.saveStepsDisplay(
            state.stepsDisplay.copyWith(tools: value.first),
          ),
        ),
      ],
    ),
  ];

  List<Widget> _safetySections(
    SettingsState state,
    SettingsCubit cubit,
    AppLocalizations l10n,
  ) => [
    AppSection(
      title: l10n.settingsDefaultPolicy,
      children: [
        SegmentedButton<PolicyMode>(
          segments: [
            ButtonSegment(value: PolicyMode.ask, label: Text(l10n.policyAsk)),
            ButtonSegment(value: PolicyMode.yolo, label: Text(l10n.policyYolo)),
          ],
          selected: {state.defaultPolicy},
          onSelectionChanged: (value) => cubit.saveDefaultPolicy(value.first),
        ),
      ],
    ),
    AppSection(
      title: l10n.settingsDenylist,
      trailing: FilledButton(
        onPressed: () => cubit.saveDenylist(_denylist.text),
        child: Text(l10n.commonSave),
      ),
      children: [
        AppTextField(
          controller: _denylist,
          minLines: 3,
          maxLines: 8,
          mono: true,
        ),
      ],
    ),
  ];

  List<Widget> _advancedSections(
    SettingsState state,
    SettingsCubit cubit,
    AppLocalizations l10n,
  ) => [
    AppSection(
      title: l10n.settingsAttachLimits,
      trailing: FilledButton(
        onPressed: () => _saveAttachLimits(cubit, l10n),
        child: Text(l10n.commonSave),
      ),
      children: [
        Row(
          children: [
            Expanded(
              child: AppTextField(
                controller: _attachPerMessage,
                label: l10n.settingsAttachPerMessage,
                error: _attachError,
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: AppTextField(
                controller: _attachMaxBytes,
                label: l10n.settingsAttachMaxBytes,
                error: _attachError,
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
      ],
    ),
    AppSection(
      title: l10n.settingsLimits,
      trailing: FilledButton(
        onPressed: () => cubit.saveLimits(_limits.text),
        child: Text(l10n.commonSave),
      ),
      children: [
        AppTextField(
          controller: _limits,
          minLines: 6,
          maxLines: 16,
          mono: true,
          error: state.limitsError ? l10n.settingsLimitsInvalid : null,
        ),
      ],
    ),
  ];

  static IconData _groupIcon(_Group group) => switch (group) {
    _Group.account => Icons.key_outlined,
    _Group.interface => Icons.translate,
    _Group.safety => Icons.shield_outlined,
    _Group.advanced => Icons.tune,
  };
}

/// Спиннер в поле выбора, пока список грузится впервые.
class _LoadingSpinner extends StatelessWidget {
  const _LoadingSpinner();

  @override
  Widget build(BuildContext context) => const SizedBox.square(
    dimension: 16,
    child: CircularProgressIndicator(strokeWidth: 2),
  );
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
        Text(title, style: theme.textTheme.titleLarge),
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
