import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/domain/workspace_entry.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/project_repository.dart';
import 'package:pw_agent/core/util/mention_text.dart';
import 'package:pw_agent/host/host_capture.dart';
import 'package:pw_agent/host/host_op.dart';
import 'package:pw_agent/host/host_runtime_factory.dart';
import 'package:pw_agent/host/workspace_search_pattern.dart';

/// Поиск файлов и каталогов проекта для `@`-упоминаний.
///
/// Клиент не управляет глубиной, лимитом или таймаутом: это внутренние
/// константы агента. Так один запрос не может заставить Host обойти всё дерево
/// или вернуть неограниченный ответ. Поиск всегда идёт по папке проекта, а не
/// по произвольному пути из запроса.
@lazySingleton
class MentionSearchService {
  MentionSearchService(this._projects, this._hosts, this._runtimes);

  final ProjectRepository _projects;
  final HostRepository _hosts;
  final HostRuntimeFactory _runtimes;

  /// Пустой запрос показывает только верхние уровни: этого достаточно для
  /// первого списка и это заведомо быстро.
  static const shallowDepth = 2;

  /// Обычный поиск ограничен шестью уровнями. Глубже — только по более
  /// точному запросу, чтобы большой workspace не превращался в минуты обхода.
  static const maxDepth = 6;

  static const maxResults = 200;
  static const timeout = Duration(seconds: 4);
  static const _cacheTtl = Duration(seconds: 15);
  static const _cacheLimit = 100;

  final _cache = <String, ({List<WorkspaceEntry> entries, DateTime at})>{};

  Future<List<WorkspaceEntry>> search(String projectId, String query) async {
    final project = await _projects.byId(projectId);
    if (project == null) {
      throw const AgentApiException(
        404,
        'project_not_found',
        'project not found',
      );
    }
    final host = await _hosts.byId(project.hostId);
    if (host == null) {
      throw const AgentApiException(404, 'host_not_found', 'host not found');
    }

    final trimmed = query.trim();
    final key = '$projectId\u0000$trimmed';
    final cached = _cache[key];
    if (cached != null && DateTime.now().difference(cached.at) < _cacheTtl) {
      return cached.entries;
    }
    final run = await captureOp(
      _runtimes.forHost(host),
      SearchWorkspaceOp(
        query: trimmed,
        maxDepth: trimmed.isEmpty ? shallowDepth : maxDepth,
        maxResults: maxResults,
        includeHidden: WorkspaceSearchPattern.searchesHidden(trimmed),
      ),
      cwd: project.workspace,
      timeout: timeout,
    );
    if (run.connectionLost) {
      throw const AgentApiException(
        503,
        'host_unavailable',
        'host is unavailable',
      );
    }
    final entries = _parse(run.stdout, trimmed);
    if (entries.isEmpty && !run.ok) {
      throw const AgentApiException(
        502,
        'mention_search_failed',
        'cannot search project workspace',
      );
    }
    final result = List<WorkspaceEntry>.unmodifiable(entries);
    _cache[key] = (entries: result, at: DateTime.now());
    if (_cache.length > _cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
    return result;
  }

  /// Разбирает построчный вывод [SearchWorkspaceOp]. Каталог отличается по
  /// хвостовому `/`; битые и небезопасные пути отбрасываются.
  List<WorkspaceEntry> _parse(String stdout, String query) {
    final found = <String, WorkspaceEntry>{};
    final includeHidden = WorkspaceSearchPattern.searchesHidden(query);
    for (final raw in stdout.split('\n')) {
      var line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('./')) line = line.replaceFirst('./', '');
      final isDirectory = line.endsWith('/');
      if (isDirectory) line = line.replaceFirst(RegExp(r'/+$'), '');
      line = line.replaceAll(r'\', '/');
      if (line.isEmpty || !MentionText.isSafePath(line)) continue;
      final parts = line.split('/');
      if (parts.any(WorkspaceSearchPattern.noiseDirectories.contains)) {
        continue;
      }
      if (!includeHidden && WorkspaceSearchPattern.isHidden(line)) continue;
      found[line] = WorkspaceEntry(path: line, isDirectory: isDirectory);
    }
    final result = found.values.toList()
      ..sort((a, b) {
        final byDepth = _depth(a.path).compareTo(_depth(b.path));
        return byDepth != 0 ? byDepth : a.path.compareTo(b.path);
      });
    return result.take(maxResults).toList();
  }

  static int _depth(String path) => path.split('/').length - 1;
}
