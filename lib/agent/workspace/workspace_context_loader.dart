import 'package:injectable/injectable.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/util/char_substring.dart';
import 'package:probably_works/host/host_capture.dart';
import 'package:probably_works/host/host_op.dart';
import 'package:probably_works/host/host_runtime.dart';

class SkillInfo {
  const SkillInfo({
    required this.name,
    required this.description,
    required this.path,
  });

  final String name;
  final String description;
  final String path;
}

/// Содержимое workspace, доступное модели. Пусто, пока workspace не доверен.
class WorkspaceSnapshot {
  const WorkspaceSnapshot({
    this.workspace,
    this.trusted = false,
    this.needsTrust = false,
    this.agentsMd,
    this.skills = const [],
  });

  static const empty = WorkspaceSnapshot();

  final String? workspace;
  final bool trusted;

  /// В workspace есть AGENTS.md или skills, но пользователь ещё не доверил каталог.
  final bool needsTrust;
  final String? agentsMd;
  final List<SkillInfo> skills;
}

/// Читает AGENTS.md и skills (.probablyworks/skills, .cursor/skills) с Host. Гейт доверия: без подтверждения
/// пользователя содержимое не попадает в контекст. Кэш — по mtime файла.
///
/// Работает только через типизированные операции [HostOp], поэтому одинаково служит реальным Host и
/// виртуальному: ни одного shell-скрипта здесь нет.
@lazySingleton
class WorkspaceContextLoader {
  WorkspaceContextLoader(this._settings);

  final SettingsRepository _settings;

  final Map<String, ({String mtime, String content})> _agentsCache = {};

  static const _maxAgentsBytes = 20000;
  static const _maxSkillBytes = 3000;

  Future<WorkspaceSnapshot> load(Chat chat, HostRuntime runtime) async {
    final workspace = chat.workspace;
    if (workspace == null || workspace.isEmpty) return WorkspaceSnapshot.empty;

    final skillsDirs = [
      '$workspace/.probablyworks/skills',
      '$workspace/.cursor/skills',
    ];
    final presence = await _presence(runtime, workspace, skillsDirs);
    if (!presence.hasAgents && !presence.hasSkills) {
      return WorkspaceSnapshot(workspace: workspace, trusted: true);
    }

    final trusted = await _settings.isTrusted(chat.hostId, workspace);
    if (!trusted) {
      return WorkspaceSnapshot(workspace: workspace, needsTrust: true);
    }

    final agentsMd = presence.agentsPath == null
        ? null
        : await _readAgents(runtime, chat.hostId, presence.agentsPath!);
    final skills = presence.hasSkills
        ? await _scanSkills(runtime, skillsDirs)
        : const <SkillInfo>[];
    return WorkspaceSnapshot(
      workspace: workspace,
      trusted: true,
      agentsMd: agentsMd,
      skills: skills,
    );
  }

  /// Тело skill для load_skill. Путь берётся из результата сканирования (абсолютный, без `~`).
  Future<String?> loadSkillBody(HostRuntime runtime, SkillInfo skill) async {
    final run = await captureOp(
      runtime,
      ReadHeadOp(skill.path, maxBytes: _maxSkillBytes),
    );
    return run.ok ? run.stdout : null;
  }

  /// Ищет AGENTS.md и каталоги skills. Содержимое не читает: это делает [load] только после доверия.
  Future<_Presence> _presence(
    HostRuntime runtime,
    String workspace,
    List<String> skillsDirs,
  ) async {
    // Порядок важен: первый найденный файл побеждает. Варианты регистра перечислены явно.
    final agents = await captureOp(
      runtime,
      FirstFileOp([
        '$workspace/AGENTS.md',
        '$workspace/agents.md',
        '$workspace/Agents.md',
        '$workspace/.probablyworks/AGENTS.md',
      ]),
    );
    final agentsPath = agents.ok ? agents.stdout.trim() : '';
    var hasSkills = false;
    for (final dir in skillsDirs) {
      final stat = await captureOp(runtime, StatOp(dir));
      if (stat.ok && (StatResult.parse(stat.stdout)?.isDir ?? false)) {
        hasSkills = true;
        break;
      }
    }
    return _Presence(
      agentsPath: agentsPath.isEmpty ? null : agentsPath,
      hasSkills: hasSkills,
    );
  }

  Future<String?> _readAgents(
    HostRuntime runtime,
    String hostId,
    String path,
  ) async {
    final stat = await captureOp(runtime, StatOp(path));
    final mtime = stat.ok ? StatResult.parse(stat.stdout)?.mtime : null;
    if (mtime == null) return null;
    final key = '$hostId|$path';
    final cached = _agentsCache[key];
    if (cached != null && cached.mtime == mtime) return cached.content;
    final run = await captureOp(
      runtime,
      ReadHeadOp(path, maxBytes: _maxAgentsBytes),
    );
    if (!run.ok) return null;
    _agentsCache[key] = (mtime: mtime, content: run.stdout);
    return run.stdout;
  }

  Future<List<SkillInfo>> _scanSkills(
    HostRuntime runtime,
    List<String> skillsDirs,
  ) async {
    final run = await captureOp(
      runtime,
      ScanSkillsOp(skillsDirs, maxBytes: _maxSkillBytes),
    );
    if (!run.ok) return const [];
    final skills = <SkillInfo>[];
    for (final block in run.stdout.split('@@@ ').skip(1)) {
      final newline = block.indexOf('\n');
      if (newline == -1) continue;
      final path = charRange(block, 0, newline).trim();
      final body = charFrom(block, newline + 1);
      final meta = _frontmatter(body);
      final parts = path.split(RegExp(r'[\\/]'));
      final name =
          meta['name'] ?? (parts.length >= 2 ? parts[parts.length - 2] : path);
      skills.add(
        SkillInfo(
          name: name,
          description: meta['description'] ?? '',
          path: path,
        ),
      );
    }
    return skills;
  }

  static Map<String, String> _frontmatter(String body) {
    final result = <String, String>{};
    if (!body.startsWith('---')) return result;
    final end = body.indexOf('\n---', 3);
    if (end == -1) return result;
    for (final line in charRange(body, 3, end).split('\n')) {
      final colon = line.indexOf(':');
      if (colon == -1) continue;
      result[charRange(line, 0, colon).trim()] = charFrom(
        line,
        colon + 1,
      ).trim();
    }
    return result;
  }
}

/// Что нашлось в workspace: путь AGENTS.md и наличие каталогов skills.
class _Presence {
  const _Presence({this.agentsPath, this.hasSkills = false});

  final String? agentsPath;
  final bool hasSkills;

  bool get hasAgents => agentsPath != null;
}
