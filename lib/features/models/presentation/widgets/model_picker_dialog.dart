import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/theme/app_theme.dart';
import 'package:probably_works/app/theme/app_tokens.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/util/char_substring.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

/// Выбор модели: поиск по id/имени, фильтр tool calling, закреплённые сверху, группы по провайдеру.
/// Стрелки ↑/↓ двигают подсветку, Enter выбирает. Возвращает выбранную модель или null.
/// [onTogglePin] сохраняет закрепление вне диалога.
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

class _Section {
  const _Section(this.title, this.models);

  final String title;
  final List<LlmModelInfo> models;
}

class _ModelPickerDialogState extends State<_ModelPickerDialog> {
  static const _rowHeight = 64.0;
  static const _headerHeight = 36.0;

  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _rowKeys = <String, GlobalKey>{};
  late final _searchFocus = FocusNode(onKeyEvent: _onKey);
  late final List<String> _pinned = [...widget.pinned];
  var _toolsOnly = true;
  var _query = '';
  String? _highlightId;

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
    _scroll.dispose();
    _searchFocus.dispose();
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

  List<_Section> _sections() {
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
    final l10n = AppLocalizations.of(context);
    return [
      if (pinnedModels.isNotEmpty)
        _Section(l10n.modelPinnedSection, pinnedModels),
      for (final entry in groups.entries) _Section(entry.key, entry.value),
    ];
  }

  /// Подсвечиваемые строки в порядке показа; модели без tool calling не выбираются.
  List<LlmModelInfo> _selectable(List<_Section> sections) => [
    for (final section in sections)
      for (final model in section.models)
        if (model.supportsTools) model,
  ];

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final selectable = _selectable(_sections());
    if (selectable.isEmpty) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final current = selectable.indexWhere((m) => m.id == _highlightId);
      final step = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      final next = current < 0
          ? (step > 0 ? 0 : selectable.length - 1)
          : (current + step).clamp(0, selectable.length - 1);
      setState(() => _highlightId = selectable[next].id);
      _ensureVisible(selectable[next].id, next);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      final match = selectable.where((m) => m.id == _highlightId);
      if (match.isEmpty) return KeyEventResult.ignored;
      Navigator.pop(context, match.first);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Строка может быть не построена (ленивый список), тогда прокручиваем по оценке высоты.
  void _ensureVisible(String id, int index) {
    final rowContext = _rowKeys[id]?.currentContext;
    if (rowContext != null) {
      unawaited(
        Scrollable.ensureVisible(
          rowContext,
          duration: AppDurations.fast,
          alignment: 0.5,
        ),
      );
      return;
    }
    if (!_scroll.hasClients) return;
    final target = (index * _rowHeight)
        .clamp(0, _scroll.position.maxScrollExtent)
        .toDouble();
    unawaited(
      _scroll.animateTo(
        target,
        duration: AppDurations.fast,
        curve: Curves.easeOut,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    final sections = _sections();
    return Dialog(
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      child: SizedBox(
        width: (size.width - 48).clamp(0, 620).toDouble(),
        height: (size.height - 96).clamp(0, 600).toDouble(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: AppTextField(
                controller: _search,
                focusNode: _searchFocus,
                autofocus: true,
                hint: l10n.modelSearchHint,
                prefixIcon: Icons.search,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.xs,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilterChip(
                  label: Text(l10n.modelFilterToolsOnly),
                  selected: _toolsOnly,
                  onSelected: (value) => setState(() => _toolsOnly = value),
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: sections.isEmpty
                  ? Center(child: Text(l10n.modelPickerEmpty))
                  : CustomScrollView(
                      controller: _scroll,
                      slivers: [
                        for (final section in sections)
                          SliverMainAxisGroup(
                            slivers: [
                              SliverPersistentHeader(
                                pinned: true,
                                delegate: _HeaderDelegate(
                                  title: section.title,
                                  height: _headerHeight,
                                  background: scheme.surfaceContainerLow,
                                ),
                              ),
                              SliverList.builder(
                                itemCount: section.models.length,
                                itemBuilder: (context, i) {
                                  final model = section.models[i];
                                  final key = _rowKeys.putIfAbsent(
                                    model.id,
                                    GlobalKey.new,
                                  );
                                  return _ModelTile(
                                    key: key,
                                    model: model,
                                    l10n: l10n,
                                    current: model.id == widget.currentId,
                                    highlighted: model.id == _highlightId,
                                    pinned: _pinned.contains(model.id),
                                    onTogglePin: () => _togglePin(model.id),
                                    onSelect: () =>
                                        Navigator.pop(context, model),
                                  );
                                },
                              ),
                            ],
                          ),
                      ],
                    ),
            ),
            const Divider(height: 1),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
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

class _HeaderDelegate extends SliverPersistentHeaderDelegate {
  const _HeaderDelegate({
    required this.title,
    required this.height,
    required this.background,
  });

  final String title;
  final double height;
  final Color background;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => ColoredBox(
    color: background,
    child: Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        child: Text(
          title,
          style: Theme.of(context).textTheme.labelLarge,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ),
  );

  @override
  bool shouldRebuild(_HeaderDelegate oldDelegate) =>
      oldDelegate.title != title ||
      oldDelegate.height != height ||
      oldDelegate.background != background;
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.model,
    required this.l10n,
    required this.current,
    required this.highlighted,
    required this.pinned,
    required this.onTogglePin,
    required this.onSelect,
    super.key,
  });

  final LlmModelInfo model;
  final AppLocalizations l10n;
  final bool current;
  final bool highlighted;
  final bool pinned;
  final VoidCallback onTogglePin;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final usable = model.supportsTools;
    return ListTile(
      selected: current,
      selectedTileColor: scheme.secondaryContainer,
      tileColor: highlighted ? scheme.surfaceContainerHighest : null,
      enabled: usable,
      contentPadding: const EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.xs,
      ),
      title: Text(model.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [
          _Badge(text: model.id, mono: true),
          if (model.contextLength != null)
            _Badge(
              text: l10n.modelMetaContext(
                _modelPickerCompact(model.contextLength!),
              ),
            ),
          if (model.promptPrice != null && model.completionPrice != null)
            _Badge(
              text: l10n.modelMetaPrice(
                _modelPickerPerMillion(model.promptPrice!),
                _modelPickerPerMillion(model.completionPrice!),
              ),
            ),
          if (!usable) _Badge(text: l10n.modelNoTools, tone: AppTone.warning),
        ],
      ),
      trailing: IconButton(
        tooltip: pinned ? l10n.modelUnpin : l10n.modelPin,
        icon: Icon(pinned ? Icons.star : Icons.star_border),
        onPressed: onTogglePin,
      ),
      onTap: usable ? onSelect : null,
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, this.mono = false, this.tone});

  final String text;
  final bool mono;
  final AppTone? tone;

  @override
  Widget build(BuildContext context) {
    final colors = tone == null
        ? (
            foreground: Theme.of(context).colorScheme.onSurfaceVariant,
            background: Theme.of(context).colorScheme.surfaceContainerHighest,
          )
        : toneColors(context, tone!);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: AppRadius.smAll,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 2,
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: mono ? AppTheme.monoFamily : null,
            fontSize: 11,
            color: colors.foreground,
          ),
        ),
      ),
    );
  }
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
