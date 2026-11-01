import 'package:auto_route/auto_route.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/locale/locale_controller.dart';
import 'package:probably_works/core/config/app_limits.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/features/settings/presentation/bloc/settings_cubit.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

@RoutePage()
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) => BlocProvider(
    create: (_) => SettingsCubit(
      getIt<SettingsRepository>(),
      getIt<SecretStore>(),
      getIt<LlmProvider>(),
      getIt<LocaleController>(),
    )..load(),
    child: const _SettingsView(),
  );
}

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

  @override
  void dispose() {
    _apiKey.dispose();
    _denylist.dispose();
    _limits.dispose();
    _attachPerMessage.dispose();
    _attachMaxBytes.dispose();
    super.dispose();
  }

  Future<void> _saveApiKey(SettingsCubit cubit) async {
    await cubit.saveApiKey(_apiKey.text);
    _apiKey.clear();
  }

  void _onPinSelected(SettingsCubit cubit, String? value) {
    if (value != null) cubit.togglePin(value);
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

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return BlocConsumer<SettingsCubit, SettingsState>(
      listenWhen: (previous, current) => current.saved != previous.saved,
      listener: (context, state) =>
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(l10n.settingsSaved))),
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
        // Модель по умолчанию ведёт агента, поэтому без tool calling она недоступна; для заголовков подходит любая.
        final defaultEntries = [
          for (final m in state.models)
            DropdownMenuEntry(
              value: m.id,
              label: m.supportsTools
                  ? m.name
                  : '${m.name} · ${l10n.modelNoTools}',
              enabled: m.supportsTools,
            ),
        ];
        final titleEntries = [
          for (final m in state.models)
            DropdownMenuEntry(value: m.id, label: m.name),
        ];
        final defaultLacksTools = state.models.any(
          (m) => m.id == state.defaultModel && !m.supportsTools,
        );
        final unpinned = [
          for (final m in state.models)
            if (!state.pinnedModels.contains(m.id))
              DropdownMenuEntry(value: m.id, label: m.name),
        ];
        return Scaffold(
          appBar: AppBar(title: Text(l10n.settingsTitle)),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _Section(
                title: l10n.settingsApiKey,
                children: [
                  TextField(
                    controller: _apiKey,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l10n.apiKeyLabel,
                      hintText: state.apiKeySet ? '••••••••' : l10n.apiKeyHint,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () => _saveApiKey(cubit),
                      child: Text(l10n.commonSave),
                    ),
                  ),
                ],
              ),
              _Section(
                title: l10n.settingsDefaultModel,
                children: [
                  DropdownMenu<String>(
                    width: 420,
                    enableFilter: true,
                    initialSelection: state.defaultModel.isEmpty
                        ? null
                        : state.defaultModel,
                    dropdownMenuEntries: defaultEntries,
                    label: Text(l10n.settingsDefaultModel),
                    onSelected: (value) => cubit.saveModels(
                      defaultModel: value ?? '',
                      titleModel: state.titleModel,
                    ),
                  ),
                  if (defaultLacksTools)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        l10n.settingsNoToolsWarning,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  DropdownMenu<String>(
                    width: 420,
                    enableFilter: true,
                    initialSelection: state.titleModel.isEmpty
                        ? null
                        : state.titleModel,
                    dropdownMenuEntries: titleEntries,
                    label: Text(l10n.settingsTitleModel),
                    onSelected: (value) => cubit.saveModels(
                      defaultModel: state.defaultModel,
                      titleModel: value ?? '',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        icon: state.modelsLoading
                            ? const SizedBox.square(
                                dimension: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh),
                        label: Text(l10n.settingsModelsRefresh),
                        onPressed: state.modelsLoading
                            ? null
                            : cubit.refreshModels,
                      ),
                      if (state.modelsError != null) ...[
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            l10n.commonError(state.modelsError!),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
              _Section(
                title: l10n.settingsPinnedModels,
                children: [
                  Text(l10n.settingsPinnedHint),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final id in state.pinnedModels)
                        InputChip(
                          label: Text(_modelName(id, state.models)),
                          onDeleted: () => cubit.togglePin(id),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  DropdownMenu<String>(
                    key: ValueKey('pin-${state.pinnedModels.length}'),
                    width: 420,
                    enableFilter: true,
                    label: Text(l10n.settingsPinnedModels),
                    dropdownMenuEntries: unpinned,
                    onSelected: (value) => _onPinSelected(cubit, value),
                  ),
                ],
              ),
              _Section(
                title: l10n.settingsLanguage,
                children: [
                  DropdownMenu<String>(
                    initialSelection: state.language,
                    dropdownMenuEntries: [
                      DropdownMenuEntry(
                        value: 'system',
                        label: l10n.settingsLanguageSystem,
                      ),
                      const DropdownMenuEntry(value: 'en', label: 'English'),
                      const DropdownMenuEntry(value: 'ru', label: 'Русский'),
                    ],
                    onSelected: (value) =>
                        cubit.saveLanguage(value ?? 'system'),
                  ),
                ],
              ),
              _Section(
                title: l10n.settingsDefaultPolicy,
                children: [
                  SegmentedButton<PolicyMode>(
                    segments: [
                      ButtonSegment(
                        value: PolicyMode.ask,
                        label: Text(l10n.policyAsk),
                      ),
                      ButtonSegment(
                        value: PolicyMode.yolo,
                        label: Text(l10n.policyYolo),
                      ),
                    ],
                    selected: {state.defaultPolicy},
                    onSelectionChanged: (value) =>
                        cubit.saveDefaultPolicy(value.first),
                  ),
                ],
              ),
              _Section(
                title: l10n.settingsDenylist,
                children: [
                  TextField(
                    controller: _denylist,
                    minLines: 3,
                    maxLines: 8,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () => cubit.saveDenylist(_denylist.text),
                      child: Text(l10n.commonSave),
                    ),
                  ),
                ],
              ),
              _Section(
                title: l10n.settingsAttachLimits,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _attachPerMessage,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: l10n.settingsAttachPerMessage,
                            errorText: _attachError,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _attachMaxBytes,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: l10n.settingsAttachMaxBytes,
                            errorText: _attachError,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () => _saveAttachLimits(cubit, l10n),
                      child: Text(l10n.commonSave),
                    ),
                  ),
                ],
              ),
              _Section(
                title: l10n.settingsLimits,
                children: [
                  TextField(
                    controller: _limits,
                    minLines: 6,
                    maxLines: 16,
                    style: const TextStyle(fontFamily: 'monospace'),
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      errorText: state.limitsError
                          ? l10n.settingsLimitsInvalid
                          : null,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton(
                      onPressed: () => cubit.saveLimits(_limits.text),
                      child: Text(l10n.commonSave),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

String _modelName(String id, List<LlmModelInfo> models) {
  for (final model in models) {
    if (model.id == id) return model.name;
  }
  return id;
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    ),
  );
}
