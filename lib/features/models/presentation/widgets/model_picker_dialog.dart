import 'package:material_ui/material_ui.dart';
import 'package:probably_works/core/util/char_substring.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Выбор модели: поиск по id/имени, фильтр tool calling, закреплённые сверху, группы по провайдеру, метаданные.
/// Возвращает выбранную модель или null. [onTogglePin] сохраняет закрепление вне диалога.
Future<LlmModelInfo?> showModelPickerDialog(
  BuildContext context, {
  required List<LlmModelInfo> models,
  required List<String> pinned,
  required String? currentId,
  required void Function(String modelId) onTogglePin,
}) => showDialog<LlmModelInfo>(
  context: context,
  builder: (_) => _ModelPickerDialog(
    models: models,
    pinned: pinned,
    currentId: currentId,
    onTogglePin: onTogglePin,
  ),
);

class _ModelPickerDialog extends StatefulWidget {
  const _ModelPickerDialog({
    required this.models,
    required this.pinned,
    required this.currentId,
    required this.onTogglePin,
  });

  final List<LlmModelInfo> models;
  final List<String> pinned;
  final String? currentId;
  final void Function(String modelId) onTogglePin;

  @override
  State<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<_ModelPickerDialog> {
  final _search = TextEditingController();
  late final List<String> _pinned = [...widget.pinned];
  var _toolsOnly = true;
  var _query = '';

  @override
  void initState() {
    super.initState();
    _search.addListener(
      () => setState(() => _query = _search.text.trim().toLowerCase()),
    );
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(LlmModelInfo model) {
    if (_toolsOnly && !model.supportsTools) return false;
    if (_query.isEmpty) return true;
    return model.id.toLowerCase().contains(_query) ||
        model.name.toLowerCase().contains(_query);
  }

  void _togglePin(String id) {
    setState(() {
      if (!_pinned.remove(id)) _pinned.add(id);
    });
    widget.onTogglePin(id);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final visible = [
      for (final model in widget.models)
        if (_matches(model)) model,
    ];
    final pinnedModels = [
      for (final id in _pinned)
        for (final model in visible)
          if (model.id == id) model,
    ];
    final groups = <String, List<LlmModelInfo>>{};
    for (final model in visible) {
      if (pinnedModels.contains(model)) continue;
      groups.putIfAbsent(_provider(model.id), () => []).add(model);
    }
    final rows = <Widget>[
      if (pinnedModels.isNotEmpty)
        _SectionHeader(title: l10n.modelPinnedSection),
      for (final model in pinnedModels)
        _ModelListTile(
          model: model,
          l10n: l10n,
          currentId: widget.currentId,
          pinned: _pinned.contains(model.id),
          onTogglePin: _togglePin,
          onSelect: (m) => Navigator.pop(context, m),
        ),
      for (final entry in groups.entries) ...[
        _SectionHeader(title: entry.key),
        for (final model in entry.value)
          _ModelListTile(
            model: model,
            l10n: l10n,
            currentId: widget.currentId,
            pinned: _pinned.contains(model.id),
            onTogglePin: _togglePin,
            onSelect: (m) => Navigator.pop(context, m),
          ),
      ],
    ];
    return Dialog(
      child: SizedBox(
        width: 620,
        height: 560,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: TextField(
                controller: _search,
                autofocus: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: l10n.modelSearchHint,
                  isDense: true,
                ),
              ),
            ),
            SwitchListTile(
              dense: true,
              title: Text(l10n.modelFilterToolsOnly),
              value: _toolsOnly,
              onChanged: (value) => setState(() => _toolsOnly = value),
            ),
            const Divider(height: 1),
            Expanded(
              child: rows.isEmpty
                  ? Center(child: Text(l10n.modelPickerEmpty))
                  : ListView(children: rows),
            ),
            const Divider(height: 1),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.commonClose),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _provider(String id) {
    final slash = id.indexOf('/');
    return slash <= 0 ? id : charPrefix(id, slash);
  }
}

String _modelPickerMeta(LlmModelInfo model, AppLocalizations l10n) {
  final parts = <String>[
    model.id,
    if (model.contextLength != null)
      l10n.modelMetaContext(_modelPickerCompact(model.contextLength!)),
    if (model.promptPrice != null && model.completionPrice != null)
      l10n.modelMetaPrice(
        _modelPickerPerMillion(model.promptPrice!),
        _modelPickerPerMillion(model.completionPrice!),
      ),
  ];
  return parts.join(' · ');
}

/// `128000` → `128k`, `1000000` → `1M`.
String _modelPickerCompact(int tokens) {
  if (tokens >= 1000000) {
    return '${(tokens / 1000000).toStringAsFixed(tokens % 1000000 == 0 ? 0 : 1)}M';
  }
  if (tokens >= 1000) return '${(tokens / 1000).round()}k';
  return '$tokens';
}

/// Цена за токен (строка из OpenRouter) → `$1.25` за 1M токенов.
String _modelPickerPerMillion(String perToken) {
  final value = double.tryParse(perToken);
  if (value == null) return '—';
  return '\$${(value * 1000000).toStringAsFixed(2)}';
}

class _ModelListTile extends StatelessWidget {
  const _ModelListTile({
    required this.model,
    required this.l10n,
    required this.currentId,
    required this.pinned,
    required this.onTogglePin,
    required this.onSelect,
  });

  final LlmModelInfo model;
  final AppLocalizations l10n;
  final String? currentId;
  final bool pinned;
  final void Function(String id) onTogglePin;
  final void Function(LlmModelInfo model) onSelect;

  @override
  Widget build(BuildContext context) {
    final meta = _modelPickerMeta(model, l10n);
    return ListTile(
      dense: true,
      selected: model.id == currentId,
      enabled: model.supportsTools,
      title: Text(model.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        model.supportsTools ? meta : '$meta · ${l10n.modelNoTools}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: pinned ? l10n.modelUnpin : l10n.modelPin,
        icon: Icon(pinned ? Icons.star : Icons.star_border),
        onPressed: () => onTogglePin(model.id),
      ),
      onTap: model.supportsTools ? () => onSelect(model) : null,
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
    child: Text(title, style: Theme.of(context).textTheme.labelLarge),
  );
}
