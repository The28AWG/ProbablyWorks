import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:probably_works/app/ui/ui.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:probably_works/core/util/at_query.dart';
import 'package:probably_works/core/util/search_text.dart';
import 'package:probably_works/features/models/domain/model_id.dart';
import 'package:probably_works/features/models/domain/model_list_query.dart';
import 'package:probably_works/features/models/domain/model_picker_sort_store.dart';
import 'package:probably_works/features/models/domain/model_query_parser.dart';
import 'package:probably_works/features/models/presentation/model_format.dart';
import 'package:probably_works/l10n/generated/app_localizations.dart';
import 'package:pw_agent/core/logging/app_log.dart';
import 'package:pw_agent/core/util/text_clip.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:pw_agent/providers/ai/model_runtime.dart';

/// Выбор модели: поиск по имени и id, фильтры `@provider:`, `@free` и `@tools`,
/// сортировка, закреплённые сверху и обновление списка.
///
/// Свободный текст ищет по имени, id и провайдеру с учётом опечаток. Фильтры
/// вводятся прямо в поле: `@` открывает подсказку, `@provider:` — список
/// провайдеров с количеством моделей. Значение провайдера сопоставляется по
/// точной подписи или единственному префиксу; неоднозначный префикс
/// (`@provider:llama` при `llama.cpp` и `llamadart`) не применяется и
/// показывает оба варианта.
///
/// Стрелки ↑/↓ двигают подсветку (или подсказку фильтра, пока она открыта),
/// Enter выбирает, Escape закрывает подсказку, а без неё — диалог. Фокус при
/// открытии стоит в поле поиска и возвращается туда после смены сортировки.
///
/// Возвращает выбранную модель или null.
/// [onTogglePin] задан — у каждой строки есть кнопка закрепления, которая сохраняет закрепление вне диалога.
/// Null — кнопки нет (настройки), закреплённые всё равно показываются сверху по [pinned].
/// [requireTools] — выбирать только модели с tool calling (нужно агенту). Для заголовков чатов не нужно.
/// [managePins] — режим управления закреплениями (настройки): нажатие на строку закрепляет или
/// открепляет модель, диалог остаётся открытым и ничего не возвращает. Требует [onTogglePin].
/// Недоступная текущая модель показывается отдельно и не выбирается.
/// [sortStore] — где запоминать выбранную сортировку. Null — `ClientSettings`
/// приложения, если они зарегистрированы; иначе порядок живёт только в диалоге.
Future<LlmModelInfo?> showModelPickerDialog(
  BuildContext context, {
  required ModelCatalogSource catalog,
  required List<String> pinned,
  required String? currentId,
  ModelRuntimeSource? runtime,
  void Function(String modelId)? onTogglePin,
  bool requireTools = true,
  bool managePins = false,
  ModelPickerSortStore? sortStore,
}) {
  assert(!managePins || onTogglePin != null, 'managePins нужен onTogglePin');
  return showDialog<LlmModelInfo>(
    context: context,
    builder: (_) => _ModelPickerDialog(
      catalog: catalog,
      runtime: runtime,
      pinned: pinned,
      currentId: currentId,
      onTogglePin: onTogglePin,
      requireTools: requireTools,
      managePins: managePins,
      sortStore: sortStore ?? _defaultSortStore(),
    ),
  );
}

/// Сортировка запоминается в клиентских настройках, если приложение их зарегистрировало.
/// В тестах и на экранах без DI порядок остаётся в памяти диалога.
ModelPickerSortStore _defaultSortStore() => ModelPickerSortStore(
  getIt.isRegistered<ClientSettings>() ? getIt<ClientSettings>() : null,
);

class _ModelPickerDialog extends StatefulWidget {
  const _ModelPickerDialog({
    required this.catalog,
    required this.runtime,
    required this.pinned,
    required this.currentId,
    required this.onTogglePin,
    required this.requireTools,
    required this.managePins,
    required this.sortStore,
  });

  final ModelCatalogSource catalog;
  final ModelRuntimeSource? runtime;
  final List<String> pinned;
  final String? currentId;
  final void Function(String modelId)? onTogglePin;
  final bool requireTools;
  final bool managePins;
  final ModelPickerSortStore sortStore;

  @override
  State<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

/// Секция списка: закреплённые, недоступная текущая модель или группа провайдера.
class _Section {
  const _Section(this.title, this.models, {this.unavailable = false});

  /// Null — секция без заголовка (плоский список).
  final String? title;
  final List<LlmModelInfo> models;

  /// Модели этой секции больше нет в списке: видны с маркером, но не выбираются.
  final bool unavailable;
}

/// Подсказка автодополнения `@`-фильтра.
class _Suggestion {
  const _Suggestion({
    required this.replacement,
    required this.title,
    this.subtitle,
    this.icon,
  });

  /// Что вставить вместо введённого токена.
  final String replacement;
  final String title;
  final String? subtitle;
  final IconData? icon;
}

class _ModelPickerDialogState extends State<_ModelPickerDialog> {
  /// Высота строки модели. Фиксированная, чтобы прокрутка к строке с клавиатуры
  /// не зависела от того, построена ли она: подпись занимает не больше двух строк.
  static const _rowExtent = 72.0;

  /// Высота заголовка секции: входит в расчёт прокрутки.
  static const _headerExtent = 36.0;

  static const _suggestionExtent = 52.0;

  final _search = TextEditingController();
  final _scroll = ScrollController();
  final _suggestionScroll = ScrollController();
  final _overlay = OverlayPortalController();
  final _tapGroup = Object();
  final _rowKeys = <String, GlobalKey>{};
  late final _searchFocus = FocusNode(onKeyEvent: _onKey);

  late final List<String> _pinned = [...widget.pinned];
  late final StreamSubscription<ModelCatalogState> _catalogSub;
  StreamSubscription<ModelRuntimeState>? _runtimeSub;

  late ModelCatalogState _catalog = widget.catalog.state;
  late ModelRuntimeState _runtime =
      widget.runtime?.runtime ?? const ModelRuntimeState();
  final _runtimeBusy = <String>{};
  String? _runtimeError;

  /// Сортировка: выбранная пользователем или сохранённая в настройках.
  var _sort = ModelSort.provider;
  var _sortTouched = false;

  var _query = const ModelListQuery();
  ModelProviderProblem? _providerProblem;
  var _lastText = '';
  var _suggestions = const <_Suggestion>[];
  var _suggestionSignature = '';
  var _suggestionIndex = 0;
  AtToken? _autocomplete;
  String? _highlightId;
  var _highlightPrimed = false;

  @override
  void initState() {
    super.initState();
    _query = ModelListQuery(toolsOnly: widget.requireTools);
    _search.addListener(_onSearchChanged);
    _catalogSub = widget.catalog.watch().listen(_onCatalogChanged);
    final runtime = widget.runtime;
    if (runtime != null) {
      _runtimeSub = runtime.watchRuntime().listen(
        (state) => setState(() => _runtime = state),
        onError: (Object error, StackTrace stack) {
          if (mounted) setState(() => _runtimeError = '$error');
        },
      );
    }
    unawaited(_loadSort());
    WidgetsBinding.instance.addPostFrameCallback((_) => _primeHighlight());
  }

  @override
  void dispose() {
    unawaited(_catalogSub.cancel());
    unawaited(_runtimeSub?.cancel());
    _search
      ..removeListener(_onSearchChanged)
      ..dispose();
    _scroll.dispose();
    _suggestionScroll.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Сохранённая сортировка приходит асинхронно. Пока пользователь не выбрал
  /// своё, диалог подстраивается под настройку.
  Future<void> _loadSort() async {
    try {
      final sort = await widget.sortStore.load();
      if (!mounted || _sortTouched || sort == _sort) return;
      setState(() => _sort = sort);
    } on Object catch (error) {
      AppLog.root.warning('cannot read model sort', error);
    }
  }

  void _changeSort(ModelSort sort) {
    if (sort == _sort) return;
    setState(() {
      _sort = sort;
      _sortTouched = true;
      _highlightId = null;
    });
    _scrollToTop();
    _searchFocus.requestFocus();
    unawaited(
      widget.sortStore.save(sort).catchError((Object error) {
        AppLog.root.warning('cannot save model sort', error);
      }),
    );
  }

  void _onCatalogChanged(ModelCatalogState catalog) {
    setState(() => _catalog = catalog);
    _refreshQuery();
    _primeHighlight();
  }

  /// При открытии подсвечиваем и прокручиваем к текущей модели, чтобы выбор
  /// начинался с того, что уже стоит в чате.
  void _primeHighlight() {
    if (_highlightPrimed || !_catalog.loaded || !mounted) return;
    _highlightPrimed = true;
    final id = widget.currentId;
    if (id == null) return;
    final sections = _sections(AppLocalizations.of(context));
    if (!_selectable(sections).any((model) => model.id == id)) return;
    setState(() => _highlightId = id);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ensureVisible(id, sections);
    });
  }

  /// Доступные модели каталога: провайдеры offline скрыты и перечислены баннером.
  List<LlmModelInfo> _availableModels() => [
    for (final model in _catalog.models)
      if (!_catalog.providerUnavailableFor(model.id)) model,
  ];

  /// Подписи провайдеров для фильтра и подсказок.
  List<String> get _providers =>
      providersOf(_availableModels(), providers: _catalog.providers);

  void _onSearchChanged() {
    if (_search.text != _lastText) {
      _lastText = _search.text;
      _scrollToTop();
    }
    _refreshQuery();
  }

  /// Пересобирает запрос, подсказки и подсветку после ввода или смены каталога.
  void _refreshQuery() {
    final autocomplete = _detectAutocomplete();
    // Пока токен набирается, он не участвует в запросе: иначе `@provider:`
    // на середине ввода показывал бы пустой список поверх подсказок.
    final raw = autocomplete == null
        ? _search.text
        : _search.text.replaceRange(autocomplete.start, autocomplete.end, '');
    final parse = ModelQueryParser.parse(raw, providers: _providers);
    _query = parse.query.copyWith(
      toolsOnly: parse.query.toolsOnly || widget.requireTools,
    );
    // Незавершённый провайдер не фильтрует список, но о неверном значении
    // сообщаем сразу: иначе пользователь не поймёт, почему фильтр не сработал.
    var problem = parse.providerProblem;
    if (problem == null &&
        autocomplete != null &&
        ModelQueryParser.canonicalFilter(autocomplete.name) == 'provider' &&
        autocomplete.value.isNotEmpty) {
      problem = _providerProblemOf(_valuePrefix(autocomplete));
    }
    final suggestions = autocomplete == null
        ? const <_Suggestion>[]
        : _suggestionsFor(autocomplete);
    final signature = _signatureOf(suggestions);
    // Секции считаем после смены запроса: подсветка не должна указывать на скрытую строку.
    final selectable = _selectable(_sections(AppLocalizations.of(context)));
    final highlighted = _highlightId;
    setState(() {
      _providerProblem = problem;
      _autocomplete = autocomplete;
      if (signature != _suggestionSignature) {
        _suggestionSignature = signature;
        _suggestionIndex = 0;
      }
      _suggestions = suggestions;
      if (highlighted != null && !selectable.any((m) => m.id == highlighted)) {
        _highlightId = null;
      }
    });
    _syncOverlay();
  }

  /// Предупреждение о том, почему `@provider:` не применён.
  ModelProviderProblem? _providerProblemOf(String value) =>
      switch (matchProvider(value, _providers)) {
        ProviderMatchFound() => null,
        ProviderMatchAmbiguous(:final candidates) => ModelProviderProblem(
          value: value,
          kind: ModelProviderProblemKind.ambiguous,
          candidates: candidates,
        ),
        ProviderMatchNotFound() => ModelProviderProblem(
          value: value,
          kind: ModelProviderProblemKind.unknown,
        ),
      };

  static String _signatureOf(List<_Suggestion> suggestions) =>
      suggestions.map((item) => item.replacement).join('\u0000');

  void _syncOverlay() {
    final show = _suggestions.isNotEmpty;
    if (show && !_overlay.isShowing) _overlay.show();
    if (!show && _overlay.isShowing) _overlay.hide();
  }

  void _dismissSuggestions() {
    if (_suggestions.isEmpty) return;
    setState(() {
      _suggestions = const [];
      _autocomplete = null;
      _suggestionSignature = '';
    });
    _syncOverlay();
  }

  /// Вставляет подсказку вместо активного `@`-токена.
  void _applySuggestion(_Suggestion suggestion) {
    final token = _autocomplete;
    if (token == null) return;
    // `@provider:` оставляем открытым, чтобы сразу показать провайдеров.
    final inserted = suggestion.replacement.endsWith(':')
        ? suggestion.replacement
        : '${suggestion.replacement} ';
    final next = _search.text.replaceRange(token.start, token.end, inserted);
    setState(() {
      _suggestions = const [];
      _autocomplete = null;
      _suggestionSignature = '';
    });
    _syncOverlay();
    _search.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: token.start + inserted.length),
    );
    _searchFocus.requestFocus();
  }

  /// Токен под кареткой, для которого нужно автодополнение.
  AtToken? _detectAutocomplete() {
    final text = _search.text;
    final caret = _search.selection.baseOffset;
    if (caret < 0 || caret > text.length) return null;
    var start = -1;
    for (var i = caret - 1; i >= 0; i--) {
      final char = text[i];
      if (AtQuery.isTokenStart(text, i)) {
        start = i;
        break;
      }
      if (AtQuery.isSpace(char)) break;
    }
    if (start < 0) return null;
    final end = AtQuery.tokenEnd(text, start);
    if (caret != end) return null;
    final token = AtQuery.parse(text, start, end);
    if (!token.hasValue) {
      if (token.name.isEmpty) return token;
      // Полное имя фильтра (`@free`) уже введено: подсказывать нечего.
      if (ModelQueryParser.canonicalFilter(token.name) == null &&
          ModelQueryParser.isAliasPrefix(token.name)) {
        return token;
      }
      return null;
    }
    if (ModelQueryParser.canonicalFilter(token.name) != 'provider') {
      return null;
    }
    // Значение уже однозначно указывает на провайдера: фильтр применён,
    // Enter должен выбирать модель, а не подсказку.
    if (matchProvider(_valuePrefix(token), _providers) is ProviderMatchFound) {
      return null;
    }
    return _isClosedQuote(token) ? null : token;
  }

  /// Значение провайдера уже закрыто кавычкой: ввод закончен.
  bool _isClosedQuote(AtToken token) {
    final rawValue = AtQuery.textOf(
      token.raw,
      token.raw.indexOf(':') + 1,
      token.raw.length,
    ).trim();
    return rawValue.startsWith('"') &&
        rawValue.length >= 2 &&
        rawValue.endsWith('"');
  }

  /// Введённое значение без первой кавычки: незакрытое значение продолжает вводиться.
  String _valuePrefix(AtToken token) => token.value.startsWith('"')
      ? AtQuery.textOf(token.value, 1, token.value.length)
      : token.value;

  List<_Suggestion> _suggestionsFor(AtToken token) {
    final l10n = AppLocalizations.of(context);
    if (!token.hasValue) {
      return [
        for (final name in ModelQueryParser.filterNames)
          // В режиме агента инструменты обязательны: подсказка @tools была бы ложной.
          if (!(widget.requireTools && name == 'tools') &&
              _matchesFilterName(name, token.name))
            _Suggestion(
              replacement: ModelQueryParser.tokenOf(name),
              title: switch (name) {
                'provider' => l10n.modelFilterProvider,
                'free' => l10n.modelFilterFree,
                _ => l10n.modelFilterToolsOnly,
              },
              subtitle: ModelQueryParser.tokenOf(name),
              icon: Icons.filter_alt_outlined,
            ),
      ];
    }
    if (ModelQueryParser.canonicalFilter(token.name) != 'provider') {
      return const [];
    }
    final needle = normalizeSearchText(_valuePrefix(token));
    final models = _availableModels();
    final providers = providersOf(models, providers: _catalog.providers);
    final counts = providerCountsOf(models, providers: _catalog.providers);
    return [
      for (final provider in providers)
        if (needle.isEmpty || normalizeSearchText(provider).startsWith(needle))
          _Suggestion(
            replacement: '@provider:"$provider"',
            title: provider,
            subtitle: l10n.modelPickerProviderCount(counts[provider] ?? 0),
            icon: Icons.dns_outlined,
          ),
    ];
  }

  /// Совпадает ли имя фильтра с введённым префиксом: `@б` находит «бесплатные».
  static bool _matchesFilterName(String canonical, String prefix) {
    if (prefix.isEmpty) return true;
    for (final alias in ModelQueryParser.aliasesOf(canonical)) {
      if (alias.startsWith(prefix)) return true;
    }
    return false;
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

  Future<void> _loadModel(String modelId) => _runRuntime(modelId, load: true);

  Future<void> _unloadModel(String modelId) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await ConfirmDialog.confirm(
      context,
      title: l10n.modelRuntimeUnloadTitle(_catalog.nameOf(modelId)),
      message: l10n.modelRuntimeUnloadBody,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.modelRuntimeUnload,
    );
    if (!confirmed || !mounted) return;
    await _runRuntime(modelId, load: false);
  }

  Future<void> _runRuntime(String modelId, {required bool load}) async {
    final runtime = widget.runtime;
    if (runtime == null) return;
    setState(() {
      _runtimeBusy.add(modelId);
      _runtimeError = null;
    });
    try {
      if (load) {
        await runtime.loadModel(modelId);
      } else {
        await runtime.unloadModel(modelId);
      }
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _runtimeError = '$error');
    } finally {
      if (mounted) setState(() => _runtimeBusy.remove(modelId));
    }
  }

  /// Текущая модель, если её больше нет в списке: показываем с маркером, выбрать нельзя.
  /// Детали берём из сохранённых, поэтому название видно даже без списка.
  LlmModelInfo? _unavailableCurrent() {
    final id = widget.currentId;
    if (id == null) return null;
    final status = _catalog.statusOf(id);
    if (status == ModelStatus.unknown || status == ModelStatus.available) {
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

  /// Модели после фильтров, без недоступной текущей.
  List<LlmModelInfo> _visibleModels() => applyModelQuery(
    _availableModels(),
    _query,
    providers: _catalog.providers,
  );

  List<_Section> _sections(AppLocalizations l10n) {
    final visible = _visibleModels();
    final pinnedModels = [
      for (final id in _pinned)
        for (final model in visible)
          if (model.id == id) model,
    ];
    final pinnedIds = {for (final model in pinnedModels) model.id};
    final rest = [
      for (final model in visible)
        if (!pinnedIds.contains(model.id)) model,
    ];
    final unavailable = _unavailableCurrent();
    // Группы по провайдеру нужны только без поиска: найденные модели сортируются
    // по релевантности, и заголовки групп разбросали бы лучшие совпадения.
    final grouped =
        _query.sort == ModelSort.provider && _query.search.trim().isEmpty;
    return [
      if (unavailable != null)
        _Section(l10n.modelCurrentUnavailable, [
          unavailable,
        ], unavailable: true),
      if (pinnedModels.isNotEmpty)
        _Section(l10n.modelPinnedSection, pinnedModels),
      if (grouped)
        ..._groupByProvider(rest)
      else if (rest.isNotEmpty)
        _Section(null, rest),
    ];
  }

  List<_Section> _groupByProvider(List<LlmModelInfo> models) {
    if (models.isEmpty) return const [];
    final groups = <String, List<LlmModelInfo>>{};
    for (final model in models) {
      final label = providerOf(model.id, providers: _catalog.providers);
      groups.putIfAbsent(label, () => []).add(model);
    }
    return [
      for (final label in providersOf(models, providers: _catalog.providers))
        _Section(label, groups[label] ?? const []),
    ];
  }

  /// Подсвечиваемые строки в порядке показа; недоступная текущая не выбирается.
  List<LlmModelInfo> _selectable(List<_Section> sections) => [
    for (final section in sections)
      if (!section.unavailable) ...section.models,
  ];

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (_suggestions.isNotEmpty) {
      if (key == LogicalKeyboardKey.arrowDown) {
        setState(
          () => _suggestionIndex = (_suggestionIndex + 1) % _suggestions.length,
        );
        _ensureSuggestionVisible();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        setState(
          () => _suggestionIndex =
              (_suggestionIndex - 1 + _suggestions.length) %
              _suggestions.length,
        );
        _ensureSuggestionVisible();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter) {
        _applySuggestion(_suggestions[_suggestionIndex]);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape) {
        _dismissSuggestions();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final sections = _sections(AppLocalizations.of(context));
    final selectable = _selectable(sections);
    if (selectable.isEmpty) return KeyEventResult.ignored;
    if (key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp) {
      final current = selectable.indexWhere((m) => m.id == _highlightId);
      final step = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
      final next = current < 0
          ? (step > 0 ? 0 : selectable.length - 1)
          : (current + step).clamp(0, selectable.length - 1);
      setState(() => _highlightId = selectable[next].id);
      _ensureVisible(selectable[next].id, sections);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      // Без подсветки Enter выбирает первый результат: так поиск работает сразу.
      final index = selectable.indexWhere((m) => m.id == _highlightId);
      final match = selectable[index < 0 ? 0 : index];
      if (widget.managePins) {
        _togglePin(match.id);
      } else {
        Navigator.pop(context, match);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onSuggestionHover(int index, bool hovered) {
    if (!hovered || index == _suggestionIndex) return;
    setState(() => _suggestionIndex = index);
  }

  void _ensureSuggestionVisible() {
    if (!_suggestionScroll.hasClients) return;
    final target = (_suggestionIndex * _suggestionExtent).clamp(
      0.0,
      _suggestionScroll.position.maxScrollExtent,
    );
    unawaited(
      _suggestionScroll.animateTo(
        target,
        duration: AppDurations.fast,
        curve: Curves.easeOut,
      ),
    );
  }

  /// Строка может быть не построена (ленивый список), тогда прокручиваем по
  /// точной оценке: каждая секция — заголовок и строки одной высоты.
  void _ensureVisible(String id, List<_Section> sections) {
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
    final offset = _offsetOf(id, sections);
    if (offset == null) return;
    final viewport = _scroll.position.viewportDimension;
    final target = offset - (viewport - _rowExtent) / 2;
    unawaited(
      _scroll.animateTo(
        target.clamp(0.0, _scroll.position.maxScrollExtent),
        duration: AppDurations.fast,
        curve: Curves.easeOut,
      ),
    );
  }

  double? _offsetOf(String id, List<_Section> sections) {
    var offset = 0.0;
    for (final section in sections) {
      if (section.title != null) offset += _headerExtent;
      for (final model in section.models) {
        if (model.id == id) return offset;
        offset += _rowExtent;
      }
    }
    return null;
  }

  void _scrollToTop() {
    if (!_scroll.hasClients) return;
    _scroll.jumpTo(0);
  }

  /// Что можно сбросить кнопкой: текст и пользовательские фильтры.
  /// Обязательные инструменты агента сбросом не снимаются.
  bool get _canReset =>
      _search.text.trim().isNotEmpty ||
      _query.freeOnly ||
      _query.provider.isNotEmpty;

  void _resetFilters() {
    _search.clear();
    _searchFocus.requestFocus();
    _scrollToTop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    // Узкое окно: убираем всё, что дублирует смысл, чтобы списку осталось место.
    // Порог считается по ширине диалога, а не окна: он ограничен 620.
    final compact = size.width - AppSpacing.lg * 2 < 500;
    final inset = compact ? AppSpacing.sm : AppSpacing.lg;
    final sections = _sections(l10n);
    final visible = _visibleModels();
    final total = _availableModels().length;
    final error = _catalog.error;

    final Widget body;
    if (!_catalog.loaded && _catalog.initialLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (!_catalog.loaded) {
      body = AppEmptyState(
        icon: Icons.cloud_off_outlined,
        title: l10n.modelsNeverSynced,
        message: error == null ? null : l10n.commonError(error),
        action: FilledButton(
          onPressed: _catalog.loading ? null : _refresh,
          child: Text(l10n.commonRetry),
        ),
      );
    } else if (sections.isEmpty) {
      body = AppEmptyState(
        icon: Icons.search_off,
        title: l10n.modelPickerEmpty,
        message: l10n.modelPickerEmptyHint,
        action: _canReset
            ? TextButton(
                onPressed: _resetFilters,
                child: Text(l10n.modelPickerResetFilters),
              )
            : null,
      );
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
                      count: section.models.length,
                      height: _headerExtent,
                      background: scheme.surfaceContainerHigh,
                      border: scheme.outlineVariant,
                    ),
                  ),
                SliverFixedExtentList(
                  itemExtent: _rowExtent,
                  delegate: SliverChildBuilderDelegate((context, i) {
                    final model = section.models[i];
                    final key = _rowKeys.putIfAbsent(model.id, GlobalKey.new);
                    final descriptor = _catalog.descriptorOf(model.id);
                    return _ModelTile(
                      key: key,
                      model: model,
                      l10n: l10n,
                      providers: _catalog.providers,
                      unavailable: section.unavailable,
                      current: model.id == widget.currentId,
                      highlighted: model.id == _highlightId,
                      pinned: _pinned.contains(model.id),
                      compact: compact,
                      runtime: _runtime.modelOf(model.id),
                      capabilities: descriptor == null
                          ? null
                          : _runtime.capabilitiesOf(descriptor.id),
                      runtimeBusy: _runtimeBusy.contains(model.id),
                      onLoadRuntime: widget.runtime == null
                          ? null
                          : () => _loadModel(model.id),
                      onUnloadRuntime: widget.runtime == null
                          ? null
                          : () => _unloadModel(model.id),
                      onTogglePin: widget.onTogglePin == null
                          ? null
                          : () => _togglePin(model.id),
                      onSelect: widget.managePins
                          ? () => _togglePin(model.id)
                          : () => Navigator.pop(context, model),
                    );
                  }, childCount: section.models.length),
                ),
              ],
            ),
        ],
      );
    }

    final problem = _providerProblem;
    final syncText = _catalog.syncedAt == null
        ? l10n.modelsNeverSynced
        : l10n.modelsSyncedAt(formatModelSyncTime(_catalog.syncedAt!));
    final showCount =
        visible.length != total ||
        _query.search.trim().isNotEmpty ||
        _query.freeOnly ||
        _query.provider.isNotEmpty;
    return Dialog(
      insetPadding: EdgeInsets.all(inset),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: AppLayout.modelPickerWidth,
          maxHeight: math.max(AppSpacing.xxl * 6, size.height - inset * 2),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.only(
                left: AppSpacing.lg,
                top: AppSpacing.md,
                right: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.modelPickerTitle,
                      style: theme.textTheme.titleLarge,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // В узком окне строка подсказки не помещается: полный текст
                  // фильтров уходит в значок рядом с заголовком.
                  if (compact)
                    Tooltip(
                      message: _filterHint(l10n),
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        child: Icon(
                          Icons.info_outline,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: l10n.commonClose,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: OverlayPortal.overlayChildLayoutBuilder(
                controller: _overlay,
                overlayChildBuilder: _buildSuggestions,
                child: TapRegion(
                  groupId: _tapGroup,
                  child: AppTextField(
                    controller: _search,
                    focusNode: _searchFocus,
                    autofocus: true,
                    hint: l10n.modelSearchHint,
                    prefixIcon: Icons.search,
                    suffix: _search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: l10n.modelPickerClearSearch,
                            onPressed: _resetFilters,
                            icon: const Icon(Icons.close),
                          ),
                  ),
                ),
              ),
            ),
            if (!compact)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: Text(
                  _filterHint(l10n),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (problem != null)
              Padding(
                padding: const EdgeInsets.only(
                  left: AppSpacing.lg,
                  top: AppSpacing.sm,
                  right: AppSpacing.lg,
                ),
                child: AppBanner(
                  margin: EdgeInsets.zero,
                  tone: AppTone.warning,
                  icon: Icons.filter_alt_off_outlined,
                  message: _providerProblemText(problem, l10n),
                ),
              ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                compact ? AppSpacing.md : AppSpacing.lg,
                AppSpacing.sm,
                compact ? AppSpacing.md : AppSpacing.sm,
                AppSpacing.xs,
              ),
              // В узком окне подпись «Сортировка» и селект не помещаются в одну
              // строку и занимают две: подпись убираем, значение говорит само.
              child: compact
                  ? AppSelect<ModelSort>(
                      value: _sort,
                      entries: _sortEntries(l10n),
                      tooltip: l10n.modelSortLabel,
                      onChanged: _changeSort,
                    )
                  : Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.xs,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          l10n.modelSortLabel,
                          style: theme.textTheme.labelLarge,
                        ),
                        AppSelect<ModelSort>(
                          value: _sort,
                          entries: _sortEntries(l10n),
                          width: AppLayout.selectWidth,
                          onChanged: _changeSort,
                        ),
                      ],
                    ),
            ),
            if (_runtimeError case final runtimeError?)
              Padding(
                padding: const EdgeInsets.only(
                  left: AppSpacing.lg,
                  right: AppSpacing.lg,
                  bottom: AppSpacing.sm,
                ),
                child: AppBanner(
                  margin: EdgeInsets.zero,
                  tone: AppTone.danger,
                  icon: Icons.error_outline,
                  message: l10n.modelRuntimeActionError(
                    TextClip.headTail(runtimeError, maxChars: 240),
                  ),
                ),
              ),
            if (error != null && _catalog.loaded)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  AppSpacing.xs,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: AppBanner(
                  margin: EdgeInsets.zero,
                  tone: AppTone.danger,
                  icon: Icons.error_outline,
                  message: l10n.commonError(error),
                  action: TextButton(
                    onPressed: _catalog.loading ? null : _refresh,
                    child: Text(l10n.commonRetry),
                  ),
                ),
              ),
            if (_catalog.unavailableProviders.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(
                  left: AppSpacing.lg,
                  right: AppSpacing.lg,
                  bottom: AppSpacing.sm,
                ),
                child: AppBanner(
                  margin: EdgeInsets.zero,
                  tone: AppTone.warning,
                  icon: Icons.cloud_off_outlined,
                  message: l10n.modelPickerProviderOffline(
                    _catalog.unavailableProviders
                        .map((provider) => provider.label)
                        .join(', '),
                  ),
                ),
              ),
            if (widget.managePins)
              Padding(
                padding: const EdgeInsets.only(
                  left: AppSpacing.lg,
                  right: AppSpacing.lg,
                  bottom: AppSpacing.sm,
                ),
                child: Text(
                  l10n.modelPinManageHint,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            const Divider(height: 1),
            Expanded(child: body),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                children: [
                  // В узком окне строка подвала вмещает только одно значение:
                  // счётчик важнее времени синхронизации, а без фильтров
                  // показываем время.
                  Expanded(
                    child: Text(
                      compact && showCount
                          ? l10n.modelPickerResultCount(visible.length, total)
                          : syncText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (!compact && showCount) ...[
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      l10n.modelPickerResultCount(visible.length, total),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  IconButton(
                    tooltip: l10n.settingsModelsRefresh,
                    onPressed: _catalog.loading ? null : _refresh,
                    icon: _catalog.loading
                        ? const SizedBox.square(
                            dimension: AppSpacing.lg,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Подсказки `@`-фильтра под полем поиска: ширина как у поля, поверх списка.
  Widget _buildSuggestions(BuildContext context, OverlayChildLayoutInfo info) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final origin = MatrixUtils.transformPoint(
      info.childPaintTransform,
      Offset.zero,
    );
    final top = origin.dy + info.childSize.height + AppSpacing.xs;
    final available = math.max(
      0.0,
      info.overlaySize.height - top - AppSpacing.md,
    );
    return Positioned(
      left: origin.dx,
      top: top,
      width: info.childSize.width,
      child: TapRegion(
        groupId: _tapGroup,
        onTapOutside: (_) => _dismissSuggestions(),
        child: Material(
          color: scheme.surfaceContainerHigh,
          elevation: 8,
          shadowColor: scheme.shadow.withValues(alpha: 0.3),
          shape: RoundedRectangleBorder(
            borderRadius: AppRadius.mdAll,
            side: BorderSide(color: scheme.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: math.min(
                _suggestionExtent * 5,
                math.max(available, _suggestionExtent),
              ),
            ),
            child: ListView.builder(
              controller: _suggestionScroll,
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              itemExtent: _suggestionExtent,
              itemCount: _suggestions.length,
              itemBuilder: (context, index) => _SuggestionTile(
                suggestion: _suggestions[index],
                selected: index == _suggestionIndex,
                onTap: () => _applySuggestion(_suggestions[index]),
                onHover: (hovered) => _onSuggestionHover(index, hovered),
              ),
            ),
          ),
        ),
      ),
    );
  }

  static String _providerProblemText(
    ModelProviderProblem problem,
    AppLocalizations l10n,
  ) => switch (problem.kind) {
    ModelProviderProblemKind.unknown => l10n.modelPickerProviderUnknown(
      problem.value,
    ),
    ModelProviderProblemKind.ambiguous => l10n.modelPickerProviderAmbiguous(
      problem.value,
      problem.candidates.join(', '),
    ),
  };

  static String _sortLabel(ModelSort sort, AppLocalizations l10n) =>
      switch (sort) {
        ModelSort.provider => l10n.modelSortProvider,
        ModelSort.name => l10n.modelSortName,
        ModelSort.context => l10n.modelSortContext,
        ModelSort.price => l10n.modelSortPrice,
        ModelSort.newest => l10n.modelSortNewest,
      };

  /// Подсказка доступных `@`-фильтров. На широком окне стоит строкой под полем,
  /// на узком — в подсказке значка рядом с заголовком.
  String _filterHint(AppLocalizations l10n) => widget.requireTools
      ? l10n.modelPickerFilterHintTools
      : l10n.modelPickerFilterHint;

  static List<AppSelectEntry<ModelSort>> _sortEntries(AppLocalizations l10n) =>
      [
        for (final sort in ModelSort.values)
          AppSelectEntry(value: sort, label: _sortLabel(sort, l10n)),
      ];
}

class _HeaderDelegate extends SliverPersistentHeaderDelegate {
  const _HeaderDelegate({
    required this.title,
    required this.count,
    required this.height,
    required this.background,
    required this.border,
  });

  final String title;
  final int count;
  final double height;
  final Color background;
  final Color border;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final theme = Theme.of(context);
    // Высота фиксирована: заголовок входит в расчёт прокрутки к строке.
    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: background,
          border: Border(bottom: BorderSide(color: border)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.labelLarge,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '$count',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_HeaderDelegate oldDelegate) =>
      oldDelegate.title != title ||
      oldDelegate.count != count ||
      oldDelegate.height != height ||
      oldDelegate.background != background ||
      oldDelegate.border != border;
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
    required this.compact,
    required this.runtime,
    required this.capabilities,
    required this.runtimeBusy,
    required this.onLoadRuntime,
    required this.onUnloadRuntime,
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

  /// Узкое окно: id модели скрыт, его заменяет подсказка названия.
  final bool compact;

  final ModelRuntime? runtime;
  final ModelRuntimeCapabilities? capabilities;
  final bool runtimeBusy;
  final VoidCallback? onLoadRuntime;
  final VoidCallback? onUnloadRuntime;

  /// Null — кнопки закрепления нет (диалог настроек).
  final VoidCallback? onTogglePin;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = scheme.onSurfaceVariant;
    final phase = runtime?.phase;
    final loading =
        phase == ModelRuntimePhase.loading ||
        phase == ModelRuntimePhase.unloading;
    final canLoad = capabilities?.canLoad == true && onLoadRuntime != null;
    final canUnload =
        capabilities?.canUnload == true && onUnloadRuntime != null;
    final Widget? runtimeAction;
    if (runtimeBusy || loading) {
      runtimeAction = SizedBox.square(
        dimension: AppSpacing.xxl + AppSpacing.sm,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: phase == ModelRuntimePhase.loading
                ? runtime?.progress?.fraction
                : null,
          ),
        ),
      );
    } else if (canUnload &&
        (phase == ModelRuntimePhase.loaded ||
            phase == ModelRuntimePhase.sleeping)) {
      runtimeAction = IconButton(
        tooltip: l10n.modelRuntimeUnload,
        icon: const Icon(Icons.power_settings_new, size: 20),
        onPressed: onUnloadRuntime,
      );
    } else if (canLoad &&
        (phase == ModelRuntimePhase.unloaded ||
            phase == ModelRuntimePhase.failed ||
            phase == ModelRuntimePhase.incomplete ||
            phase == ModelRuntimePhase.unknown ||
            phase == ModelRuntimePhase.sleeping)) {
      runtimeAction = IconButton(
        tooltip: l10n.modelRuntimeLoad,
        icon: const Icon(Icons.play_circle_outline, size: 20),
        onPressed: onLoadRuntime,
      );
    } else {
      runtimeAction = null;
    }
    // ignore: avoid-returning-widgets, бейдж собирается из состояния строки и не переиспользуется
    final runtimeBadge = _runtimeBadge(l10n);
    final nameColor = unavailable ? muted : (current ? scheme.primary : null);
    return Material(
      color: highlighted ? scheme.surfaceContainerHighest : Colors.transparent,
      child: InkWell(
        // Список ведётся стрелками и Enter из поля поиска: строки не должны
        // разрывать обход Tab между полем и кнопками строки.
        canRequestFocus: false,
        onTap: unavailable ? null : onSelect,
        child: Padding(
          padding: EdgeInsets.only(
            left: compact ? AppSpacing.md : AppSpacing.lg,
            right: AppSpacing.xs,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        // ignore: avoid-returning-widgets, подсказка зависит от режима строки и не переиспользуется
                        Flexible(child: _name(theme, nameColor)),
                        if (current) ...[
                          const SizedBox(width: AppSpacing.xs),
                          Tooltip(
                            message: l10n.modelCurrentTooltip,
                            child: Icon(
                              Icons.check_circle,
                              size: 16,
                              color: scheme.primary,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    // Подпись занимает не больше двух строк: высота строки фиксирована,
                    // лишние бейджи обрезаются, а не ломают прокрутку. Высота не
                    // резервируется заранее, иначе строка с одной подписью выглядела бы
                    // прижатой к верху.
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 48),
                      child: ClipRect(
                        child: Wrap(
                          spacing: AppSpacing.xs,
                          runSpacing: AppSpacing.xs,
                          clipBehavior: Clip.hardEdge,
                          children: [
                            // В узком окне id не помещается и вытесняет контекст
                            // с ценой: он остаётся в подсказке названия.
                            if (!compact)
                              MetaChip(
                                label: modelIdForDisplay(
                                  model.id,
                                  providers: providers,
                                ),
                                mono: true,
                              ),
                            // Значок окна контекста тот же, что у заполнения
                            // контекста в строке настроек чата (ChatMetaBar).
                            if (model.contextLength != null)
                              MetaChip(
                                icon: Icons.data_usage,
                                label: _modelPickerCompact(
                                  model.contextLength!,
                                ),
                                tooltip: l10n.modelMetaContext(
                                  _modelPickerCompact(model.contextLength!),
                                ),
                              ),
                            // Значок денег взят из окна контекста.
                            // Цена за 1M токенов остаётся в подсказке.
                            if (model.promptPrice != null &&
                                model.completionPrice != null)
                              MetaChip(
                                icon: Icons.savings_outlined,
                                label: l10n.modelMetaPriceShort(
                                  _modelPickerPerMillion(model.promptPrice!),
                                  _modelPickerPerMillion(
                                    model.completionPrice!,
                                  ),
                                ),
                                tooltip: l10n.modelMetaPrice(
                                  _modelPickerPerMillion(model.promptPrice!),
                                  _modelPickerPerMillion(
                                    model.completionPrice!,
                                  ),
                                ),
                              ),
                            // Размышления — тот же значок, что у чипа модели
                            // с включённым уровнем в ChatMetaBar.
                            if (model.reasoning?.supported == true)
                              MetaChip(
                                icon: Icons.psychology,
                                tooltip: model.reasoning?.mandatory ?? false
                                    ? l10n.reasoningAlwaysBadge
                                    : l10n.reasoningModelBadge,
                              ),
                            ?runtimeBadge,
                            if (unavailable)
                              StatusChip(
                                label: l10n.modelUnavailableBadge,
                                tone: AppTone.warning,
                                icon: Icons.block,
                              ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (!unavailable &&
                  (onTogglePin != null || runtimeAction != null))
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ?runtimeAction,
                    if (onTogglePin != null)
                      IconButton(
                        tooltip: pinned ? l10n.modelUnpin : l10n.modelPin,
                        icon: Icon(pinned ? Icons.star : Icons.star_border),
                        onPressed: onTogglePin,
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Название модели. В узком окне id скрыт, поэтому название несёт подсказку
  /// с полным id: иначе длинное имя обрезается без возможности узнать модель.
  Widget _name(ThemeData theme, Color? color) {
    final text = Text(
      model.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.titleSmall?.copyWith(color: color),
    );
    if (!compact) return text;
    return Tooltip(
      message:
          '${model.name}\n'
          '${modelIdForDisplay(model.id, providers: providers)}',
      child: text,
    );
  }

  /// Бейдж состояния модели. Для `loaded` он полезен: видно, что занимает
  /// память. Для `unloaded` бейджа нет — это обычное состояние.
  Widget? _runtimeBadge(AppLocalizations l10n) {
    final phase = runtime?.phase;
    final percent = runtime?.progress?.fraction == null
        ? null
        : (runtime!.progress!.fraction! * 100).round();
    return switch (phase) {
      ModelRuntimePhase.loading => StatusChip(
        label: percent == null
            ? l10n.modelRuntimeBadgeLoading
            : l10n.modelRuntimeBadgePercent('$percent'),
        tone: AppTone.progress,
      ),
      ModelRuntimePhase.unloading => StatusChip(
        label: l10n.modelRuntimeBadgeUnloading,
        tone: AppTone.progress,
      ),
      ModelRuntimePhase.downloading => StatusChip(
        label: percent == null
            ? l10n.modelRuntimeBadgeDownloading
            : l10n.modelRuntimeBadgeDownloadingPercent('$percent'),
        tone: AppTone.progress,
      ),
      ModelRuntimePhase.loaded => StatusChip(
        label: l10n.modelRuntimeBadgeLoaded,
        tone: AppTone.success,
      ),
      ModelRuntimePhase.sleeping => StatusChip(
        label: l10n.modelRuntimeBadgeSleeping,
      ),
      ModelRuntimePhase.failed => StatusChip(
        label: l10n.modelRuntimeBadgeFailed,
        tone: AppTone.warning,
      ),
      ModelRuntimePhase.incomplete => StatusChip(
        label: l10n.modelRuntimeBadgeIncomplete,
        tone: AppTone.warning,
      ),
      ModelRuntimePhase.unloaded || ModelRuntimePhase.unknown || null => null,
    };
  }
}

/// Строка подсказки `@`-фильтра. Живёт в оверлее над списком моделей.
class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({
    required this.suggestion,
    required this.selected,
    required this.onTap,
    required this.onHover,
  });

  final _Suggestion suggestion;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tooltip = suggestion.subtitle == null
        ? suggestion.title
        : '${suggestion.title}\n${suggestion.subtitle}';
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: MouseRegion(
        onEnter: (_) => onHover(true),
        onExit: (_) => onHover(false),
        child: Material(
          color: selected ? scheme.surfaceContainerHighest : Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Row(
                children: [
                  Icon(
                    suggestion.icon ?? Icons.filter_alt_outlined,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          suggestion.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                        if (suggestion.subtitle case final subtitle?)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontFamily: AppTheme.monoFamily,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
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
