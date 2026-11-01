import 'package:injectable/injectable.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/util/char_substring.dart';
import 'package:probably_works/core/util/shell_quote.dart';
import 'package:probably_works/host/host_capture.dart';
import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/shell_adapter.dart';

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
@lazySingleton
class WorkspaceContextLoader {
  WorkspaceContextLoader(this._settings);

  final SettingsRepository _settings;

  final Map<String, ({int mtime, String content})> _agentsCache = {};

  static const _maxAgentsBytes = 20000;
  static const _maxSkillBytes = 3000;

  Future<WorkspaceSnapshot> load(
    Chat chat,
    HostRuntime runtime,
    HostOs os,
  ) async {
    final workspace = chat.workspace;
    if (workspace == null || workspace.isEmpty) return WorkspaceSnapshot.empty;
    if (os == HostOs.windows) return WorkspaceSnapshot(workspace: workspace);

    final shell = ShellAdapter(os);
    final skillsDirs = [
      '$workspace/.probablyworks/skills',
      '$workspace/.cursor/skills',
    ];
    final quotedWorkspace = shQuote(workspace);
    // Первый найденный файл из порядка: AGENTS.md, agents.md (любой регистр), .probablyworks/AGENTS.md.
    final presence = await captureRun(
      runtime,
      'W=$quotedWorkspace; '
      'for f in "\$W/AGENTS.md" "\$W"/[Aa][Gg][Ee][Nn][Tt][Ss].[Mm][Dd] "\$W/.probablyworks/AGENTS.md"; do '
      '[ -f "\$f" ] && { echo "agents=\$f"; break; }; done; '
      '${skillsDirs.map((d) => '[ -d ${shQuote(d)} ] && echo skills=1; ').join()}true',
    );
    final agentsLine = presence.stdout
        .split('\n')
        .where((line) => line.startsWith('agents='))
        .firstOrNull;
    final agentsPath = agentsLine == null
        ? null
        : charFrom(agentsLine, 'agents='.length).trim();
    final hasAgents = agentsPath != null && agentsPath.isNotEmpty;
    final hasSkills = presence.stdout.contains('skills=1');
    if (!hasAgents && !hasSkills) {
      return WorkspaceSnapshot(workspace: workspace, trusted: true);
    }

    final trusted = await _settings.isTrusted(chat.hostId, workspace);
    if (!trusted) {
      return WorkspaceSnapshot(workspace: workspace, needsTrust: true);
    }

    final agentsMd = agentsPath == null
        ? null
        : await _readAgents(runtime, shell, chat.hostId, agentsPath);
    final skills = hasSkills
        ? await _scanSkills(runtime, skillsDirs)
        : const <SkillInfo>[];
    return WorkspaceSnapshot(
      workspace: workspace,
      trusted: true,
      agentsMd: agentsMd,
      skills: skills,
    );
  }

  /// Тело skill для load_skill. Путь берётся из результата сканирования.
  Future<String?> loadSkillBody(HostRuntime runtime, SkillInfo skill) async {
    final run = await captureRun(
      runtime,
      'head -c $_maxSkillBytes -- ${shQuote(skill.path)} 2>/dev/null',
    );
    return run.ok ? run.stdout : null;
  }

  Future<String?> _readAgents(
    HostRuntime runtime,
    ShellAdapter shell,
    String hostId,
    String path,
  ) async {
    final mtimeRun = await captureRun(runtime, shell.statMtime(path));
    final mtime = int.tryParse(mtimeRun.stdout.trim());
    if (mtime == null) return null;
    final key = '$hostId|$path';
    final cached = _agentsCache[key];
    if (cached != null && cached.mtime == mtime) return cached.content;
    final run = await captureRun(
      runtime,
      'head -c $_maxAgentsBytes -- ${shQuote(path)}',
    );
    if (!run.ok) return null;
    _agentsCache[key] = (mtime: mtime, content: run.stdout);
    return run.stdout;
  }

  Future<List<SkillInfo>> _scanSkills(
    HostRuntime runtime,
    List<String> skillsDirs,
  ) async {
    final globs = [for (final dir in skillsDirs) '${shQuote(dir)}/*/SKILL.md']
        .join(' ');
    final run = await captureRun(
      runtime,
      'for f in $globs; do [ -f "\$f" ] && { echo "@@@ \$f"; head -c $_maxSkillBytes "\$f"; echo; }; done',
    );
    if (!run.ok) return const [];
    final skills = <SkillInfo>[];
    for (final block in run.stdout.split('@@@ ').skip(1)) {
      final newline = block.indexOf('\n');
      if (newline == -1) continue;
      final path = charRange(block, 0, newline).trim();
      final body = charFrom(block, newline + 1);
      final meta = _frontmatter(body);
      final name = meta['name'] ?? path.split('/').reversed.elementAt(1);
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
