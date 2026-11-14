import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/features/models/domain/model_list_query.dart';
import 'package:probably_works/features/models/presentation/model_format.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';

/// Выбор модели: поиск по id/имени, фильтры (tool calling, бесплатные, провайдер), сортировка,
/// закреплённые сверху и обновление списка из OpenRouter. Стрелки ↑/↓ двигают подсветку, Enter выбирает.
/// Возвращает выбранную модель или null.
/// [onTogglePin] задан — у каждой строки есть кнопка закрепления, которая сохраняет закрепление вне диалога.
/// Null — кнопки нет (настройки), закреплённые всё равно показываются сверху по [pinned].
/// [requireTools] — выбирать только модели с tool calling (нужно агенту). Для заголовков чатов не нужно.
/// [managePins] — режим управления закреплениями (настройки): нажатие на строку закрепляет или
/// открепляет модель, диалог остаётся открытым и ничего не возвращает. Требует [onTogglePin].
/// Недоступная текущая модель показывается отдельно и не выбирается.
Future<LlmModelInfo?> showModelPickerDialog(
  BuildContext context, {
  required ModelCatalogSource catalog,
  required List<String> pinned,
  required String? currentId,
  void Function(String modelId)? onTogglePin,
  bool requireTools = true,
  bool managePins = false,
}) {
  assert(!managePins || onTogglePin != null, 'managePins нужен onTogglePin');
  return showDialog<LlmModelInfo>(
    context: context,
    builder: (_) => _ModelPickerDialog(
      catalog: catalog,
      pinned: pinned,
      currentId: currentId,
      onTogglePin: onTogglePin,
      requireTools: requireTools,
      managePins: managePins,
    ),
  );
}

class _ModelPickerDialog extends StatefulWidget {
  const _ModelPickerDialog({
    required this.catalog,
    required this.pinned,
    required this.currentId,
    required this.onTogglePin,
    required this.requireTools,
    required this.managePins,
  });

  final ModelCatalogSource catalog;
  final List<String> pinned;
  final String? currentId;
  final void Function(String modelId)? onTogglePin;
  final bool requireTools;
  final bool managePins;

  @override
  State<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _Section {
  const _Section(this.title, this.models, {this.unavailable = false});

  /// Null — секция без заголовка (плоский список).
  final String? title;
  final List<LlmModelInfo> models;

  /// Модели этой секции больше нет в списке: видны с маркером, но не выбираются.
  final bool unavailable;
}

class _ModelPickerDialogState extends State<_ModelPickerDialog> {
  static const _rowHeight = 64.0;
  static const _headerHeight = 36.0;

  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _rowKeys = <String, GlobalKey>{};
  late final _searchFocus = FocusNode(onKeyEvent: _onKey);
  late final List<String> _pinned = [...widget.pinned];
  late final StreamSubscription<ModelCatalogState> _catalogSub;
  late ModelCatalogState _catalog = widget.catalog.state;
  // Фильтр «с tool calling» по умолчанию включён только если диалог этого требует:
  // иначе для заголовков чатов модели без инструментов были бы скрыты без видимой причины.
  late ModelListQuery _query;
  String? _highlightId;

  @override
  void initState() {
    super.initState();
    _query = ModelListQuery(toolsOnly: widget.requireTools);
    _search.addListener(
      () => setState(() => _query = _query.copyWith(search: _search.text)),
    );
    _catalogSub = widget.catalog.watch().listen(
      (catalog) => setState(() => _catalog = catalog),
    );
  }

  @override
  void dispose() {
    unawaited(_catalogSub.cancel());
    _search.dispose();
    _scroll.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _togglePin(String id) {
    setState(() {
      if (!_pinned.remove(id)) _pinned.add(id);
    });
    widget.onTogglePin?.call(id);
  }

  /// Ошибка и статус загрузки приходят из состояния каталога; здесь только запускаем обновление.
  Future<void> _refresh() async {
    try {
      await widget.catalog.refresh();
    } on Object {
      // Ошибка уже в состоянии каталога и показана в диалоге.
    }
  }

  /// Текущая модель, если её больше нет в списке: показываем с маркером, выбрать нельзя.
  /// Детали берём из сохранённых, поэтому название видно даже без списка.
  LlmModelInfo? _unavailableCurrent() {
    final id = widget.currentId;
    if (id == null || _catalog.statusOf(id) != ModelStatus.unavailable) {
      return null;
    }
    final saved = _catalog.saved[id];
    return LlmModelInfo(
      id: id,
      name: saved?.name ?? _catalog.modelIdForDisplay(id),
      contextLength: saved?.contextLength,
      supportsTools: saved?.supportsTools ?? false,
    );
  }

  List<_Section> _sections(AppLocalizations l10n) {
    final visible = applyModelQuery(
      _catalog.models,
      _query,
      providers: _catalog.providers,
    );
    final pinnedModels = [
      for (final id in _pinned)
        for (final model in visible)
          if (model.id == id) model,
    ];
    final rest = [
      for (final model in visible)
        if (!pinnedModels.contains(model)) model,
    ];
    final unavailable = _unavailableCurrent();
    return [
      if (unavailable != null)
        _Section(l10n.modelCurrentUnavailable, [
          unavailable,
        ], unavailable: true),
      if (pinnedModels.isNotEmpty)
        _Section(l10n.modelPinnedSection, pinnedModels),
      if (_query.sort == ModelSort.provider)
        ..._groupByProvider(rest, _catalog.providers)
      else if (rest.isNotEmpty)
        _Section(null, rest),
    ];
  }

  static List<_Section> _groupByProvider(
    List<LlmModelInfo> models,
    List<LlmProviderDescriptor> providers,
  ) {
    final groups = <String, List<LlmModelInfo>>{};
    for (final model in models) {
      groups
          .putIfAbsent(providerOf(model.id, providers: providers), () => [])
          .add(model);
    }
    return [
      for (final entry in groups.entries) _Section(entry.key, entry.value),
    ];
  }

  /// Подсвечиваемые строки в порядке показа; недоступные и (если нужно агенту) без tool calling не выбираются.
  List<LlmModelInfo> _selectable(List<_Section> sections) => [
    for (final section in sections)
      if (!section.unavailable)
        for (final model in section.models)
          if (_usable(model)) model,
  ];

  /// Модель можно выбрать: с tool calling, если диалог этого требует.
  bool _usable(LlmModelInfo model) =>
      model.supportsTools || !widget.requireTools;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final selectable = _selectable(_sections(AppLocalizations.of(context)));
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
      if (widget.managePins) {
        _togglePin(match.first.id);
      } else {
        Navigator.pop(context, match.first);
      }
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
    final sections = _sections(l10n);
    final providers = providersOf(
      _catalog.models,
      providers: _catalog.providers,
    );
    // Каталог ещё не загружали: показываем загрузку или причину, а не пустой список.
    final Widget body;
    if (!_catalog.loaded && _catalog.loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (!_catalog.loaded) {
      body = Center(
        child: Text(
          _catalog.error != null
              ? l10n.commonError(_catalog.error!)
              : l10n.modelsNeverSynced,
        ),
      );
    } else if (sections.isEmpty) {
      body = Center(child: Text(l10n.modelPickerEmpty));
    } else {
      body = CustomScrollView(
        controller: _scroll,
        slivers: [
          for (final section in sections)
            SliverMainAxisGroup(
              slivers: [
                if (section.title != null)
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _HeaderDelegate(
                      title: section.title!,
                      height: _headerHeight,
                      background: scheme.surfaceContainerLow,
                    ),
                  ),
                SliverList.builder(
                  itemCount: section.models.length,
                  itemBuilder: (context, i) {
                    final model = section.models[i];
                    final key = _rowKeys.putIfAbsent(model.id, GlobalKey.new);
                    return _ModelTile(
                      key: key,
                      model: model,
                      l10n: l10n,
                      providers: _catalog.providers,
                      unavailable: section.unavailable,
                      current: model.id == widget.currentId,
                      highlighted: model.id == _highlightId,
                      pinned: _pinned.contains(model.id),
                      requireTools: widget.requireTools,
                      onTogglePin: widget.onTogglePin == null
                          ? null
                          : () => _togglePin(model.id),
                      onSelect: widget.managePins
                          ? () => _togglePin(model.id)
                          : () => Navigator.pop(context, model),
                    );
                  },
                ),
              ],
            ),
        ],
      );
    }
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
            if (widget.managePins)
              Padding(
                padding: const EdgeInsets.only(
                  left: AppSpacing.lg,
                  right: AppSpacing.lg,
                  bottom: AppSpacing.xs,
                ),
                child: Text(
                  l10n.modelPinManageHint,
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.xs,
              ),
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.xs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  FilterChip(
                    label: Text(
                      l10n.modelFilterToolsOnly,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: _query.toolsOnly,
                    onSelected: (value) => setState(
                      () => _query = _query.copyWith(toolsOnly: value),
                    ),
                  ),
                  FilterChip(
                    label: Text(
                      l10n.modelFilterFree,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    selected: _query.freeOnly,
                    onSelected: (value) => setState(
                      () => _query = _query.copyWith(freeOnly: value),
                    ),
                  ),
                  DropdownMenu<String>(
                    width: 200,
                    enableFilter: true,
                    initialSelection: _query.provider,
                    label: Text(
                      l10n.modelFilterProvider,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    dropdownMenuEntries: [
                      DropdownMenuEntry(
                        value: '',
                        label: l10n.modelFilterAllProviders,
                      ),
                      for (final provider in providers)
                        DropdownMenuEntry(value: provider, label: provider),
                    ],
                    onSelected: (value) => setState(
                      () => _query = _query.copyWith(provider: value ?? ''),
                    ),
                  ),
                  DropdownMenu<ModelSort>(
                    width: 200,
                    initialSelection: _query.sort,
                    label: Text(
                      l10n.modelSortLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    dropdownMenuEntries: [
                      for (final sort in ModelSort.values)
                        DropdownMenuEntry(
                          value: sort,
                          label: _sortLabel(sort, l10n),
                        ),
                    ],
                    onSelected: (value) => setState(
                      () => _query = _query.copyWith(
                        sort: value ?? ModelSort.provider,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(
                left: AppSpacing.lg,
                right: AppSpacing.xs,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _catalog.syncedAt == null
                          ? l10n.modelsNeverSynced
                          : l10n.modelsSyncedAt(
                              formatModelSyncTime(_catalog.syncedAt!),
                            ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.settingsModelsRefresh,
                    onPressed: _catalog.loading ? null : _refresh,
                    icon: _catalog.loading
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
            if (_catalog.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: Text(
                  l10n.commonError(_catalog.error!),
                  style: TextStyle(color: scheme.error),
                ),
              ),
            const Divider(height: 1),
            Expanded(child: body),
            const Divider(height: 1),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.sm),
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    l10n.commonClose,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _sortLabel(ModelSort sort, AppLocalizations l10n) =>
      switch (sort) {
        ModelSort.provider => l10n.modelSortProvider,
        ModelSort.name => l10n.modelSortName,
        ModelSort.context => l10n.modelSortContext,
        ModelSort.price => l10n.modelSortPrice,
        ModelSort.newest => l10n.modelSortNewest,
      };
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
    required this.providers,
    required this.unavailable,
    required this.current,
    required this.highlighted,
    required this.pinned,
    required this.requireTools,
    required this.onTogglePin,
    required this.onSelect,
    super.key,
  });

  final LlmModelInfo model;
  final AppLocalizations l10n;

  /// Дескрипторы провайдеров: из них снимается служебный префикс id.
  final List<LlmProviderDescriptor> providers;
  final bool unavailable;
  final bool current;
  final bool highlighted;
  final bool pinned;

  /// Выбирать только модели с tool calling. Без этого бейдж «нет tool calling» не показывается.
  final bool requireTools;

  /// Null — кнопки закрепления нет (диалог настроек).
  final VoidCallback? onTogglePin;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final usable = !unavailable && (model.supportsTools || !requireTools);
    return ListTile(
      selected: current,
      selectedTileColor: scheme.secondaryContainer,
      tileColor: highlighted ? scheme.surfaceContainerHighest : null,
      enabled: usable,
      contentPadding: const EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.xs,
      ),
      title: Text(
        unavailable ? '! ${model.name}' : model.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Wrap(
        spacing: AppSpacing.xs,
        runSpacing: AppSpacing.xs,
        children: [
          _Badge(
            text: modelIdForDisplay(model.id, providers: providers),
            mono: true,
          ),
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
          if (requireTools && !model.supportsTools)
            _Badge(text: l10n.modelNoTools, tone: AppTone.warning),
          if (unavailable)
            _Badge(
              text: '! ${l10n.modelUnavailableBadge}',
              tone: AppTone.warning,
            ),
        ],
      ),
      trailing: unavailable || onTogglePin == null
          ? null
          : IconButton(
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
