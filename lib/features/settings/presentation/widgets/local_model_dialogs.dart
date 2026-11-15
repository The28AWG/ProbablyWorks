import 'package:app_ui/app_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/providers/ai/local_models.dart';

/// Что ввёл пользователь в диалоге установки модели.
class LocalModelInstallRequest {
  const LocalModelInstallRequest({
    required this.source,
    this.name,
    this.sha256,
  });

  final String source;
  final String? name;
  final String? sha256;
}

/// Диалог установки файла модели: ссылка Hugging Face, HTTP(S) или путь.
class LocalModelInstallDialog extends StatefulWidget {
  const LocalModelInstallDialog({super.key});

  @override
  State<LocalModelInstallDialog> createState() => _InstallState();
}

class _InstallState extends State<LocalModelInstallDialog> {
  final _source = TextEditingController();
  final _name = TextEditingController();
  final _sha = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _source.dispose();
    _name.dispose();
    _sha.dispose();
    super.dispose();
  }

  void _submit(AppLocalizations l10n) {
    final source = _source.text.trim();
    if (source.isEmpty) {
      setState(() => _error = l10n.localModelsSourceRequired);
      return;
    }
    final name = _name.text.trim();
    final sha = _sha.text.trim();
    Navigator.of(context).pop(
      LocalModelInstallRequest(
        source: source,
        name: name.isEmpty ? null : name,
        sha256: sha.isEmpty ? null : sha,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(
        l10n.localModelsInstallTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: AppLayout.dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.localModelsInstallHint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                controller: _source,
                label: l10n.localModelsSource,
                hint: 'hf://owner/repo/model.gguf',
                autofocus: true,
                mono: true,
                error: _error,
                onSubmitted: (_) => _submit(l10n),
              ),
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                controller: _name,
                label: l10n.localModelsName,
                hint: l10n.localModelsNameHint,
              ),
              const SizedBox(height: AppSpacing.md),
              AppTextField(
                controller: _sha,
                label: l10n.localModelsSha,
                hint: l10n.localModelsShaHint,
                mono: true,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            l10n.commonCancel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        FilledButton(
          onPressed: () => _submit(l10n),
          child: Text(
            l10n.localModelsInstall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Параметры запуска и генерации одного файла модели.
///
/// Это настройки среды выполнения, а не провайдера: они сохраняются у файла и
/// применяются при следующей загрузке в память.
class LocalModelSettingsDialog extends StatefulWidget {
  const LocalModelSettingsDialog({
    required this.modelName,
    required this.initial,
    super.key,
  });

  final String modelName;
  final LocalModelSettings initial;

  @override
  State<LocalModelSettingsDialog> createState() => _SettingsState();
}

class _SettingsState extends State<LocalModelSettingsDialog> {
  late final _context = _controller(widget.initial.contextSize);
  late final _gpuLayers = _controller(widget.initial.gpuLayers);
  late final _threads = _controller(widget.initial.threads);
  late final _batchSize = _controller(widget.initial.batchSize);
  late final _maxTokens = _controller(widget.initial.maxTokens);
  late final _temperature = _controller(widget.initial.temperature);
  late final _topK = _controller(widget.initial.topK);
  late final _topP = _controller(widget.initial.topP);
  late final _minP = _controller(widget.initial.minP);
  late final _penalty = _controller(widget.initial.penalty);
  late final _presence = _controller(widget.initial.presencePenalty);
  late final _thinking = _controller(widget.initial.thinkingBudget);
  late final _projector = TextEditingController(
    text: widget.initial.projectorSource ?? '',
  );
  late final _stop = TextEditingController(
    text: widget.initial.stopSequences.join(', '),
  );
  late var _tools = widget.initial.supportsTools;
  late var _projectorAudio = widget.initial.projectorAudio;
  late var _mmap = widget.initial.useMmap;
  String? _error;

  static TextEditingController _controller(Object? value) =>
      TextEditingController(text: value?.toString() ?? '');

  @override
  void dispose() {
    for (final controller in [
      _context,
      _gpuLayers,
      _threads,
      _batchSize,
      _maxTokens,
      _temperature,
      _topK,
      _topP,
      _minP,
      _penalty,
      _presence,
      _thinking,
      _projector,
      _stop,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit(AppLocalizations l10n) {
    final contextSize = int.tryParse(_context.text.trim());
    final gpuLayers = int.tryParse(_gpuLayers.text.trim());
    final threads = int.tryParse(_threads.text.trim());
    final batchSize = int.tryParse(_batchSize.text.trim());
    final maxTokens = int.tryParse(_maxTokens.text.trim());
    final temperature = double.tryParse(_temperature.text.trim());
    final topK = int.tryParse(_topK.text.trim());
    final topP = double.tryParse(_topP.text.trim());
    final minP = double.tryParse(_minP.text.trim());
    final penalty = double.tryParse(_penalty.text.trim());
    final presence = double.tryParse(_presence.text.trim());
    final thinkingText = _thinking.text.trim();
    final thinking = thinkingText.isEmpty ? null : int.tryParse(thinkingText);
    final projector = _projector.text.trim();
    if (contextSize == null ||
        gpuLayers == null ||
        threads == null ||
        batchSize == null ||
        maxTokens == null ||
        temperature == null ||
        topK == null ||
        topP == null ||
        minP == null ||
        penalty == null ||
        presence == null ||
        (thinkingText.isNotEmpty && thinking == null)) {
      setState(() => _error = l10n.localModelsNumberRequired);
      return;
    }
    final settings = LocalModelSettings(
      contextSize: contextSize,
      gpuLayers: gpuLayers,
      threads: threads,
      batchSize: batchSize,
      useMmap: _mmap,
      maxTokens: maxTokens,
      temperature: temperature,
      topK: topK,
      topP: topP,
      minP: minP,
      penalty: penalty,
      presencePenalty: presence,
      supportsTools: _tools,
      projectorSource: projector.isEmpty ? null : projector,
      projectorAudio: _projectorAudio,
      thinkingBudget: thinking,
      stopSequences: [
        for (final part in _stop.text.split(','))
          if (part.trim().isNotEmpty) part.trim(),
      ],
    );
    final error = settings.validate();
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(settings);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(
        l10n.localModelsSettingsTitle(widget.modelName),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: AppLayout.dialogWidth,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error case final error?) ...[
                AppBanner(
                  margin: EdgeInsets.zero,
                  tone: AppTone.danger,
                  icon: Icons.error_outline,
                  message: error,
                ),
                const SizedBox(height: AppSpacing.md),
              ],
              _SettingsField(
                label: l10n.localModelsContext,
                helper: l10n.localModelsContextHint,
                controller: _context,
                keyboardType: TextInputType.number,
              ),
              _SettingsField(
                label: l10n.localModelsGpuLayers,
                helper: l10n.localModelsGpuLayersHint,
                controller: _gpuLayers,
                keyboardType: const TextInputType.numberWithOptions(
                  signed: true,
                ),
              ),
              _SettingsField(
                label: l10n.localModelsThreads,
                helper: l10n.localModelsThreadsHint,
                controller: _threads,
                keyboardType: TextInputType.number,
              ),
              _SettingsField(
                label: l10n.localModelsBatchSize,
                helper: l10n.localModelsBatchSizeHint,
                controller: _batchSize,
                keyboardType: TextInputType.number,
              ),
              _SettingsToggle(
                label: l10n.localModelsMmap,
                description: l10n.localModelsMmapHint,
                value: _mmap,
                onChanged: (value) => setState(() => _mmap = value),
              ),
              _SettingsField(
                label: l10n.localModelsMaxTokens,
                controller: _maxTokens,
                keyboardType: TextInputType.number,
              ),
              _SettingsField(
                label: l10n.localModelsTemperature,
                controller: _temperature,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
              _SettingsField(
                label: l10n.localModelsTopP,
                controller: _topP,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
              _SettingsField(
                label: l10n.localModelsTopK,
                controller: _topK,
                keyboardType: TextInputType.number,
              ),
              _SettingsField(
                label: l10n.localModelsMinP,
                controller: _minP,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
              _SettingsField(
                label: l10n.localModelsPenalty,
                controller: _penalty,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
              _SettingsField(
                label: l10n.localModelsPresencePenalty,
                controller: _presence,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
              _SettingsField(
                label: l10n.localModelsThinkingBudget,
                helper: l10n.localModelsThinkingBudgetHint,
                controller: _thinking,
                keyboardType: TextInputType.number,
              ),
              _SettingsField(
                label: l10n.localModelsStopSequences,
                helper: l10n.localModelsStopSequencesHint,
                controller: _stop,
                mono: true,
              ),
              _SettingsToggle(
                label: l10n.localModelsTools,
                description: l10n.localModelsToolsHint,
                value: _tools,
                onChanged: (value) => setState(() => _tools = value),
              ),
              _SettingsField(
                label: l10n.localModelsProjector,
                helper: l10n.localModelsProjectorHint,
                hint: 'hf://owner/repo/mmproj.gguf',
                controller: _projector,
                mono: true,
              ),
              _SettingsToggle(
                label: l10n.localModelsProjectorAudio,
                description: l10n.localModelsProjectorAudioHint,
                value: _projectorAudio,
                onChanged: (value) => setState(() => _projectorAudio = value),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            l10n.commonCancel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        FilledButton(
          onPressed: () => _submit(l10n),
          child: Text(
            l10n.commonSave,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Поле с подписью над ним: как строка настроек, но без плавающей подписи.
class _SettingsField extends StatelessWidget {
  const _SettingsField({
    required this.label,
    required this.controller,
    this.helper,
    this.hint,
    this.keyboardType,
    this.mono = false,
  });

  final String label;
  final TextEditingController controller;
  final String? helper;
  final String? hint;
  final TextInputType? keyboardType;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.xs),
          AppTextField(
            controller: controller,
            hint: hint,
            helper: helper,
            keyboardType: keyboardType,
            mono: mono,
          ),
        ],
      ),
    );
  }
}

/// Переключатель с пояснением: подпись слева, `Switch` справа.
class _SettingsToggle extends StatelessWidget {
  const _SettingsToggle({
    required this.label,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.titleSmall),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  description,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
