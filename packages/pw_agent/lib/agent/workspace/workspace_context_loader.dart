import 'package:injectable/injectable.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/skills/skill_locations.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/util/char_substring.dart';
import 'package:pw_agent/host/host_capture.dart';
import 'package:pw_agent/host/host_op.dart';
import 'package:pw_agent/host/host_runtime.dart';

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
    this.untrustedSkills = const [],
  });

  static const empty = WorkspaceSnapshot();

  final String? workspace;
  final bool trusted;

  /// В workspace есть AGENTS.md или skills, но пользователь ещё не доверил каталог.
  final bool needsTrust;
  final String? agentsMd;

  /// Skills, доверенные проектом: попадают в каталог и доступны для load_skill.
  final List<SkillInfo> skills;

  /// Skills, найденные в workspace, но не доверенные. Нужны бейджу и карточке проекта.
  final List<SkillInfo> untrustedSkills;
}

/// Читает AGENTS.md и skills с Host. Каталог приложения — `.probablyworks/skills`;
/// совместимые каталоги других агентов ищутся через [SkillLocations].
/// Гейт доверия: без подтверждения пользователя содержимое не попадает в контекст.
/// Кэш AGENTS.md — по mtime файла.
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

  Future<WorkspaceSnapshot> load(
    Chat chat,
    HostRuntime runtime, {
    Project? project,
    Set<String> trustedSkills = const {},
  }) async {
    final workspace = project?.workspace ?? chat.workspace;
    if (workspace == null || workspace.isEmpty) return WorkspaceSnapshot.empty;

    // Один скан на все каталоги: отдельный stat на каждый путь был бы лишним
    // сетевым запросом на каждом шаге модели.
    final found = await _scanSkills(
      runtime,
      SkillLocations.forWorkspace(workspace),
    );
    final agentsPath = await _findAgents(runtime, workspace);
    if (agentsPath == null && found.isEmpty) {
      return WorkspaceSnapshot(workspace: workspace, trusted: true);
    }

    // Проект хранит доверие отдельно для AGENTS.md и каждого skill. Старые чаты без проекта
    // читают прежний ключ доверия целиком, чтобы поведение до миграции не изменилось.
    final legacyTrust =
        project == null && await _settings.isTrusted(chat.hostId, workspace);
    final agentsTrusted = project?.trustAgentsMd ?? legacyTrust;
    final trusted = project == null && legacyTrust
        ? found
        : [
            for (final skill in found)
              if (trustedSkills.contains(skill.name)) skill,
          ];
    final untrusted = [
      for (final skill in found)
        if (!trusted.contains(skill)) skill,
    ];
    final needsTrust =
        (agentsPath != null && !agentsTrusted) || untrusted.isNotEmpty;
    final agentsMd = agentsPath == null || !agentsTrusted
        ? null
        : await _readAgents(runtime, chat.hostId, agentsPath);
    return WorkspaceSnapshot(
      workspace: workspace,
      trusted: !needsTrust,
      needsTrust: needsTrust,
      agentsMd: agentsMd,
      skills: trusted,
      untrustedSkills: untrusted,
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

  /// Путь к AGENTS.md или null. Содержимое не читает: это делает [load] только
  /// после доверия. Порядок важен: первый найденный файл побеждает.
  Future<String?> _findAgents(HostRuntime runtime, String workspace) async {
    final agents = await captureOp(
      runtime,
      FirstFileOp([
        '$workspace/AGENTS.md',
        '$workspace/agents.md',
        '$workspace/Agents.md',
        '$workspace/.probablyworks/AGENTS.md',
      ]),
    );
    final path = agents.ok ? agents.stdout.trim() : '';
    return path.isEmpty ? null : path;
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
    final seen = <String>{};
    for (final block in run.stdout.split('@@@ ').skip(1)) {
      final newline = block.indexOf('\n');
      if (newline == -1) continue;
      final path = charRange(block, 0, newline).trim();
      final body = charFrom(block, newline + 1);
      final meta = _frontmatter(body);
      final parts = path.split(RegExp(r'[\\/]'));
      final name =
          meta['name'] ?? (parts.length >= 2 ? parts[parts.length - 2] : path);
      // Каталог приложения идёт первым, поэтому при одинаковом имени skill
      // из `.probablyworks` выигрывает, а дубликаты из других каталогов скрываются.
      if (!seen.add(name)) continue;
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
