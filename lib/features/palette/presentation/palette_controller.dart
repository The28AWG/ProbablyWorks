import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:probably_works/features/palette/domain/command_registry.dart';
import 'package:probably_works/features/palette/domain/command_search.dart';
import 'package:probably_works/features/palette/domain/palette_command.dart';
import 'package:probably_works/features/palette/domain/palette_query_parser.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/domain/search.dart';
import 'package:pw_agent/core/util/char_substring.dart';

/// Тип строки результата палитры.
enum PaletteResultKind { command, chat, message, suggestion, back }

/// Одна строка результата: команда, чат или сообщение.
class PaletteResult {
  const PaletteResult({
    required this.kind,
    required this.id,
    required this.title,
    required this.score,
    this.subtitle,
    this.path,
    this.icon,
    this.command,
    this.hit,
    this.suggestion,
    this.isGroup = false,
  });

  final PaletteResultKind kind;
  final String id;
  final String title;
  final double score;
  final String? subtitle;
  final String? path;
  final IconData? icon;
  final PaletteCommand? command;
  final SearchHit? hit;
  final PaletteSuggestion? suggestion;

  /// Группа команд: Enter входит внутрь, а не выполняет действие.
  final bool isGroup;
}

/// Локализованные подписи подсказок. Передаются из UI, чтобы контроллер не
/// зависел от `BuildContext`.
class PaletteLabels {
  const PaletteLabels({
    required this.command,
    required this.project,
    required this.current,
    required this.currentProject,
    required this.chat,
    required this.scope,
    required this.allChats,
    required this.projectScope,
    required this.chatScope,
  });

  final String command;
  final String project;
  final String current;
  final String currentProject;
  final String chat;
  final String scope;
  final String allChats;
  final String projectScope;
  final String chatScope;
}

final class _AutocompleteToken {
  const _AutocompleteToken({
    required this.start,
    required this.end,
    required this.name,
    required this.value,
  });

  final int start;
  final int end;
  final String name;
  final String value;
}

/// Состояние и поиск палитры. UI только рисует и передаёт ввод.
class PaletteController extends ChangeNotifier {
  PaletteController({
    required this.registry,
    required this.searchApi,
    required this.projects,
    required this.chats,
    required this.labels,
    required this.languageCode,
    this.currentChatId,
    this.currentProjectId,
  }) {
    _rebuildTree();
    _loadSearch();
  }

  final CommandRegistry registry;
  final AgentApi searchApi;
  final List<Project> projects;
  final List<Chat> chats;
  final PaletteLabels labels;
  final String languageCode;
  final String? currentChatId;
  final String? currentProjectId;

  static const _debounce = Duration(milliseconds: 180);

  static const _filterNames = [
    'command',
    'project',
    'current',
    'current-project',
    'chat',
    'scope',
  ];

  static const _filterAliases = <String, List<String>>{
    'command': ['command', 'команда'],
    'project': ['project', 'проект'],
    'current': ['current', 'текущий'],
    'current-project': ['current-project', 'текущий-проект'],
    'chat': ['chat', 'чат'],
    'scope': ['scope', 'область'],
  };

  var _raw = '';
  var _query = const PaletteQuery(text: '');
  var _results = <PaletteResult>[];
  var _tree = <PaletteCommand>[];
  var _groupId = '';
  final _groupStack = <String>[];
  var _selected = 0;
  var _selectionVisible = false;
  _AutocompleteToken? _autocomplete;
  var _suggestions = <PaletteSuggestion>[];
  var _loading = false;
  var _searchFailed = false;
  var _generation = 0;
  Timer? _timer;
  var _disposed = false;

  String get raw => _raw;
  PaletteQuery get query => _query;
  List<PaletteResult> get results => _results;
  List<PaletteCommand> get tree => _tree;
  bool get loading => _loading;
  bool get searchFailed => _searchFailed;
  bool get isSearching => _query.text.isNotEmpty;
  bool get autocompleteActive => _autocomplete != null;
  List<PaletteSuggestion> get suggestions => _suggestions;

  bool get canGoBack =>
      _autocomplete == null && _query.text.isEmpty && _groupStack.isNotEmpty;
  String? get groupPath {
    if (_groupId.isEmpty) return null;
    final group = registry.byId(_groupId);
    return group == null ? null : registry.pathOf(group, languageCode);
  }

  int get selected => _selected;

  /// Показывать ли подсветку. При открытии она скрыта: пользователь может
  /// управлять только мышью, и случайно выбранная строка не должна бросаться
  /// в глаза.
  bool get selectionVisible => _selectionVisible;
  PaletteResult? get selectedResult =>
      _results.isEmpty || _selected >= _results.length
      ? null
      : _results[_selected];

  void setRaw(String value, {int? caretOffset}) {
    if (_raw == value) return;
    _raw = value;
    _updateInput(caretOffset ?? value.length, allowAutocomplete: true);
  }

  /// Скрывает подсказки, не трогая введённый текст. Следующий символ снова может
  /// открыть их: `Esc` закрывает только текущий список.
  void dismissAutocomplete() {
    if (_autocomplete == null) return;
    _autocomplete = null;
    _suggestions = const [];
    _updateInput(_raw.length, allowAutocomplete: false);
  }

  /// Общий разбор ввода: подсветки, фильтры, результаты и подсказки.
  /// [allowAutocomplete] выключается при `Esc`, чтобы список не открылся заново
  /// на том же тексте.
  void _updateInput(int caret, {required bool allowAutocomplete}) {
    _autocomplete = allowAutocomplete ? _detectAutocomplete(_raw, caret) : null;
    _suggestions = _autocomplete == null
        ? const []
        : _suggestionsFor(_autocomplete!);
    _query = PaletteQueryParser.parse(
      _raw,
      context: PaletteParseContext(
        currentChatId: currentChatId,
        currentProjectId: currentProjectId,
      ),
    );
    _resolveNames();
    _selected = 0;
    _selectionVisible = false;
    if (_autocomplete != null) {
      _searchFailed = false;
      _loading = false;
      _generation++;
      _timer?.cancel();
      notifyListeners();
      return;
    }
    if (_query.text.isEmpty) {
      _searchFailed = false;
      _loading = false;
      _generation++;
      _timer?.cancel();
      _rebuildTree();
      notifyListeners();
      return;
    }
    _rebuildResults();
    _loadSearch();
    notifyListeners();
  }

  /// Вставляет выбранную подсказку вместо активного @-токена.
  void applySuggestion(PaletteSuggestion suggestion) {
    final token = _autocomplete;
    if (token == null) return;
    var replacement = suggestion.replacement;
    if (!replacement.endsWith(':')) {
      replacement = '$replacement ';
    }
    final next = _raw.replaceRange(token.start, token.end, replacement);
    _autocomplete = null;
    _suggestions = const [];
    setRaw(next);
  }

  _AutocompleteToken? _detectAutocomplete(String raw, int caret) {
    if (caret < 0 || caret > raw.length) return null;
    var start = -1;
    for (var i = caret - 1; i >= 0; i--) {
      final char = raw[i];
      if (char == '@' && (i == 0 || _isSpace(raw[i - 1]))) {
        start = i;
        break;
      }
      if (_isSpace(char)) break;
    }
    if (start < 0) return null;
    final end = _tokenEnd(raw, start);
    if (caret != end) return null;
    final token = charRange(raw, start, end);
    final body = charFrom(token, 1);
    final split = body.indexOf(':');
    final rawName = (split < 0 ? body : charPrefix(body, split)).toLowerCase();
    final name = _canonicalFilter(rawName);
    final value = split < 0 ? '' : charFrom(body, split + 1);
    if (split < 0) {
      if (body.isEmpty) {
        return _AutocompleteToken(start: start, end: end, name: '', value: '');
      }
      if (name != null || !_isFilterPrefix(rawName)) return null;
      return _AutocompleteToken(
        start: start,
        end: end,
        name: rawName,
        value: '',
      );
    }
    if (name == null ||
        (name != 'project' && name != 'chat' && name != 'scope')) {
      return null;
    }
    var prefix = value;
    if (prefix.startsWith('"')) {
      if (prefix.length >= 2 && prefix.endsWith('"')) return null;
      prefix = charFrom(prefix, 1);
    }
    if (end < raw.length && _isSpace(raw[end])) return null;
    return _AutocompleteToken(
      start: start,
      end: end,
      name: name,
      value: prefix,
    );
  }

  List<PaletteSuggestion> _suggestionsFor(_AutocompleteToken token) {
    if (token.name.isEmpty) {
      return [for (final name in _filterNames) _filterSuggestion(name)];
    }
    if (token.name == 'project') {
      final needle = _normalize(token.value);
      final matches =
          projects
              .where(
                (project) =>
                    needle.isEmpty ||
                    _normalize(project.name).contains(needle) ||
                    project.id.toLowerCase().startsWith(needle),
              )
              .take(12)
              .toList()
            ..sort(
              (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            );
      return [
        for (final project in matches)
          PaletteSuggestion(
            kind: PaletteSuggestionKind.project,
            replacement: '@project:"${project.name}"',
            title: project.name,
            subtitle: '@project:"${project.name}"',
            icon: Icons.workspaces_outline,
          ),
      ];
    }
    if (token.name == 'chat') {
      final needle = _normalize(token.value);
      final matches =
          chats
              .where(
                (chat) =>
                    needle.isEmpty ||
                    _normalize(chat.title).contains(needle) ||
                    chat.id.toLowerCase().startsWith(needle),
              )
              .take(12)
              .toList()
            ..sort(
              (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
            );
      return [
        for (final chat in matches)
          PaletteSuggestion(
            kind: PaletteSuggestionKind.chat,
            replacement: '@chat:"${chat.title}"',
            title: chat.title,
            subtitle: '@chat:"${chat.title}"',
            icon: Icons.chat_bubble_outline,
          ),
      ];
    }
    if (token.name == 'scope') {
      final needle = token.value.toLowerCase();
      final values = <(String, String)>[
        ('all', labels.allChats),
        ('project', labels.projectScope),
        ('chat', labels.chatScope),
      ];
      return [
        for (final (value, label) in values)
          if (needle.isEmpty || value.startsWith(needle))
            PaletteSuggestion(
              kind: PaletteSuggestionKind.scope,
              replacement: '@scope:$value',
              title: label,
              subtitle: '@scope:$value',
              icon: Icons.tune,
            ),
      ];
    }
    return [
      for (final name in _filterNames)
        if (_filterAliases[name]!.any((alias) => alias.startsWith(token.name)))
          _filterSuggestion(name),
    ];
  }

  PaletteSuggestion _filterSuggestion(String name) {
    final replacement = _filterReplacement(name);
    return PaletteSuggestion(
      kind: PaletteSuggestionKind.filter,
      replacement: replacement,
      title: switch (name) {
        'command' => labels.command,
        'project' => labels.project,
        'current' => labels.current,
        'current-project' => labels.currentProject,
        'chat' => labels.chat,
        _ => labels.scope,
      },
      subtitle: replacement,
      icon: Icons.filter_alt_outlined,
    );
  }

  static String _filterReplacement(String name) => switch (name) {
    'command' => '@command',
    'project' => '@project:',
    'current' => '@current',
    'current-project' => '@current-project',
    'chat' => '@chat:',
    _ => '@scope:',
  };

  static String? _canonicalFilter(String name) {
    for (final entry in _filterAliases.entries) {
      if (entry.value.contains(name)) return entry.key;
    }
    return null;
  }

  static bool _isFilterPrefix(String value) {
    if (value.isEmpty) return true;
    for (final aliases in _filterAliases.values) {
      if (aliases.any((alias) => alias.startsWith(value))) return true;
    }
    return false;
  }

  static bool _isSpace(String char) => char.trim().isEmpty;

  static int _tokenEnd(String raw, int start) {
    var quoted = false;
    var escaped = false;
    for (var i = start + 1; i < raw.length; i++) {
      final char = raw[i];
      if (escaped) {
        escaped = false;
        continue;
      }
      if (char == r'\') {
        escaped = true;
        continue;
      }
      if (char == '"') {
        quoted = !quoted;
        continue;
      }
      if (!quoted && _isSpace(char)) return i;
    }
    return raw.length;
  }

  static String _normalize(String value) => normalizeSearchText(value);

  void enterGroup(PaletteCommand group) {
    if (!group.isGroup) return;
    _groupStack.add(_groupId);
    _groupId = group.id;
    _rebuildTree();
    _selected = 0;
    _selectionVisible = false;
    notifyListeners();
  }

  void goBack() {
    if (_query.text.isNotEmpty || _groupStack.isEmpty) return;
    _groupId = _groupStack.removeLast();
    _rebuildTree();
    _selected = 0;
    _selectionVisible = false;
    notifyListeners();
  }

  void resetGroup() {
    if (_groupId.isEmpty && _groupStack.isEmpty) return;
    _groupId = '';
    _groupStack.clear();
    _rebuildTree();
    _selected = 0;
    _selectionVisible = false;
    notifyListeners();
  }

  void moveSelection(int delta) {
    if (_results.isEmpty) return;
    // Первое движение только показывает выделение на текущей строке.
    // Иначе ArrowDown после открытия сразу уводил бы на второй пункт.
    if (!_selectionVisible) {
      _selectionVisible = true;
      if (delta < 0) _selected = _results.length - 1;
      notifyListeners();
      return;
    }
    final next = (_selected + delta).clamp(0, _results.length - 1);
    if (next == _selected) {
      notifyListeners();
      return;
    }
    _selected = next;
    notifyListeners();
  }

  void selectIndex(int index) {
    if (index < 0 || index >= _results.length) return;
    _selectionVisible = true;
    if (index == _selected) {
      notifyListeners();
      return;
    }
    _selected = index;
    notifyListeners();
  }

  void _rebuildTree() {
    _tree = registry.childrenOf(
      _groupId.isEmpty ? null : _groupId,
      languageCode,
    );
    _results = [
      if (_groupStack.isNotEmpty)
        PaletteResult(
          kind: PaletteResultKind.back,
          id: 'back',
          title: '',
          score: 1,
          subtitle: groupPath,
          icon: Icons.arrow_back,
        ),
      for (final command in _tree)
        PaletteResult(
          kind: PaletteResultKind.command,
          id: command.id,
          title: command.titles.forLanguage(languageCode),
          score: 1,
          subtitle: command.isGroup
              ? registry.pathOf(command, languageCode)
              : null,
          path: registry.pathOf(command, languageCode),
          icon: command.icon,
          command: command,
          isGroup: command.isGroup,
        ),
    ];
  }

  void _rebuildResults() {
    final matches = registry.search(_query.text, languageCode);
    _results = [
      for (final match in matches)
        PaletteResult(
          kind: PaletteResultKind.command,
          id: match.command.id,
          title: match.command.titles.forLanguage(languageCode),
          score: match.score,
          subtitle: match.path,
          path: match.path,
          icon: match.command.icon,
          command: match.command,
        ),
    ];
  }

  /// Разрешает имена проекта и чата в id. Если имя не найдено или подходит
  /// нескольким объектам, фильтр не применяется: его токен возвращается в
  /// текст запроса и ищется как обычное слово.
  void _resolveNames() {
    var projectId = _query.projectId;
    var projectName = _query.projectName;
    var chatId = _query.chatId;
    var chatName = _query.chatName;
    final filters = [..._query.filters];
    final text = StringBuffer(_query.text);

    void appendToken(String raw) {
      if (text.length > 0) text.write(' ');
      text.write(raw);
    }

    if (projectName != null) {
      final needle = normalizeSearchText(projectName);
      final matching = projects
          .where(
            (project) =>
                project.id == projectName ||
                normalizeSearchText(project.name) == needle,
          )
          .toList();
      if (matching.length == 1) {
        projectId = matching.single.id;
        projectName = matching.single.name;
      } else {
        _dropFilters(
          filters,
          PaletteFilterKind.project,
          projectName,
          appendToken,
        );
        projectId = null;
        projectName = null;
      }
    }

    if (chatName != null) {
      final needle = normalizeSearchText(chatName);
      final matching = chats
          .where(
            (chat) =>
                chat.id == chatName ||
                normalizeSearchText(chat.title) == needle,
          )
          .toList();
      if (matching.length == 1) {
        chatId = matching.single.id;
        chatName = matching.single.title;
      } else {
        _dropFilters(filters, PaletteFilterKind.chat, chatName, appendToken);
        chatId = null;
        chatName = null;
      }
    }

    _query = PaletteQuery(
      text: text.toString().replaceAll(RegExp(r'\s+'), ' ').trim(),
      commandsOnly: _query.commandsOnly,
      scope: _query.commandsOnly
          ? _query.scope
          : _scopeAfterResolution(
              currentChat: _query.currentChat,
              chatId: chatId,
              projectId: projectId,
              explicitScope: _explicitScope(filters),
            ),
      projectId: projectId,
      projectName: projectName,
      chatId: chatId,
      chatName: chatName,
      currentChat: _query.currentChat,
      filters: filters,
    );
  }

  /// Убирает фильтры указанного вида с тем же значением и отдаёт их токены
  /// в текст запроса через [appendToken].
  static void _dropFilters(
    List<PaletteFilter> filters,
    PaletteFilterKind kind,
    String value,
    void Function(String raw) appendToken,
  ) {
    final dropped = filters
        .where((filter) => filter.kind == kind && filter.value == value)
        .toList();
    for (final filter in dropped) {
      appendToken(filter.raw);
    }
    filters.removeWhere(dropped.contains);
  }

  /// Последний явный `@scope` после отбрасывания неприменимых фильтров.
  static SearchScope? _explicitScope(List<PaletteFilter> filters) {
    SearchScope? scope;
    for (final filter in filters) {
      if (filter.kind != PaletteFilterKind.scope) continue;
      final parsed = SearchScope.values.asNameMap()[filter.value];
      if (parsed != null) scope = parsed;
    }
    return scope;
  }

  /// Область поиска после разрешения фильтров: чат важнее проекта, проект
  /// важнее явного scope, иначе остаётся `all`.
  static SearchScope _scopeAfterResolution({
    required bool currentChat,
    required String? chatId,
    required String? projectId,
    required SearchScope? explicitScope,
  }) {
    if (currentChat || chatId != null) return SearchScope.chat;
    if (projectId != null) return SearchScope.project;
    return explicitScope ?? SearchScope.all;
  }

  void _loadSearch() {
    _timer?.cancel();
    if (_query.text.isEmpty || _query.commandsOnly) {
      _loading = false;
      _searchFailed = false;
      notifyListeners();
      return;
    }
    final generation = ++_generation;
    _timer = Timer(_debounce, () async {
      _loading = true;
      _searchFailed = false;
      notifyListeners();
      try {
        final hits = await searchApi.search(
          SearchQuery(
            text: _query.text,
            scope: _query.scope,
            projectId: _query.projectId,
            chatId: _query.chatId,
            limit: 20,
          ),
        );
        if (_disposed || generation != _generation) return;
        _applyHits(hits);
        _loading = false;
      } on Object {
        if (_disposed || generation != _generation) return;
        _searchFailed = true;
        _loading = false;
      }
      notifyListeners();
    });
  }

  void _applyHits(List<SearchHit> hits) {
    final commandResults = [
      for (final result in _results)
        if (result.kind == PaletteResultKind.command) result,
    ];
    final chatResults = [
      for (final hit in hits)
        PaletteResult(
          kind: hit.kind == SearchHitKind.chat
              ? PaletteResultKind.chat
              : PaletteResultKind.message,
          id: hit.messageId ?? hit.chatId ?? hit.title,
          title: hit.title,
          score: hit.score,
          subtitle: hit.chatTitle ?? hit.snippet,
          path: hit.chatTitle,
          hit: hit,
        ),
    ];
    _results = [...commandResults, ...chatResults]
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        return a.title.toLowerCase().compareTo(b.title.toLowerCase());
      });
    if (_selected >= _results.length) _selected = _results.length - 1;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
