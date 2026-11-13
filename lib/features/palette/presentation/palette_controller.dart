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

/// Тип строки результата палитры.
enum PaletteResultKind { command, chat, message, back }

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

  /// Группа команд: Enter входит внутрь, а не выполняет действие.
  final bool isGroup;
}

/// Состояние и поиск палитры. UI только рисует и передаёт ввод.
class PaletteController extends ChangeNotifier {
  PaletteController({
    required this.registry,
    required this.searchApi,
    required this.projects,
    required this.chats,
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
  final String languageCode;
  final String? currentChatId;
  final String? currentProjectId;

  static const _debounce = Duration(milliseconds: 180);

  var _raw = '';
  var _query = const PaletteQuery(text: '');
  var _results = <PaletteResult>[];
  var _tree = <PaletteCommand>[];
  var _groupId = '';
  final _groupStack = <String>[];
  var _selected = 0;
  var _selectionVisible = false;
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
  bool get canGoBack => _query.text.isEmpty && _groupStack.isNotEmpty;
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

  void setRaw(String value) {
    if (_raw == value) return;
    _raw = value;
    _query = PaletteQueryParser.parse(
      value,
      context: PaletteParseContext(
        currentChatId: currentChatId,
        currentProjectId: currentProjectId,
      ),
    );
    _resolveNames();
    if (_query.text.isEmpty) {
      _searchFailed = false;
      _loading = false;
      _generation++;
      _timer?.cancel();
      _rebuildTree();
      _selected = 0;
      _selectionVisible = false;
      notifyListeners();
      return;
    }
    _rebuildResults();
    _selected = 0;
    _selectionVisible = false;
    _loadSearch();
    notifyListeners();
  }

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

  /// Убирает фильтр из строки, сохраняя остальной текст.
  void removeFilter(PaletteFilter filter) {
    final value = _raw.replaceFirst(filter.raw, '');
    setRaw(value.replaceAll(RegExp(r'\s+'), ' ').trim());
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

  void _resolveNames() {
    var projectId = _query.projectId;
    var projectName = _query.projectName;
    var errors = [..._query.errors];
    if (projectName != null) {
      final matching = projects.where((project) {
        final needle = normalizeSearchText(projectName!);
        return project.id == projectName ||
            normalizeSearchText(project.name) == needle;
      }).toList();
      if (matching.length == 1) {
        projectId = matching.single.id;
        projectName = matching.single.name;
      } else {
        errors = [
          ...errors,
          matching.isEmpty
              ? PaletteQueryError.projectNotFound
              : PaletteQueryError.projectAmbiguous,
        ];
      }
    }

    var chatId = _query.chatId;
    var chatName = _query.chatName;
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
        errors = [
          ...errors,
          matching.isEmpty
              ? PaletteQueryError.chatNotFound
              : PaletteQueryError.chatAmbiguous,
        ];
      }
    }

    if (chatId != null && projectId != null) {
      final chat = chats.where((chat) => chat.id == chatId).firstOrNull;
      if (chat != null &&
          chat.projectId != null &&
          chat.projectId != projectId) {
        errors = [...errors, PaletteQueryError.conflictingScope];
      }
    }

    _query = PaletteQuery(
      text: _query.text,
      commandsOnly: _query.commandsOnly,
      scope: _query.scope,
      projectId: projectId,
      projectName: projectName,
      chatId: chatId,
      chatName: chatName,
      currentChat: _query.currentChat,
      filters: _query.filters,
      errors: errors.toSet().toList(),
    );
  }

  void _loadSearch() {
    _timer?.cancel();
    if (_query.text.isEmpty || _query.commandsOnly || _query.hasErrors) {
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
