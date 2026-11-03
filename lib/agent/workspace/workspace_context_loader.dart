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

    final shell = ShellAdapter(os);
    final skillsDirs = [
      '$workspace/.probablyworks/skills',
      '$workspace/.cursor/skills',
    ];
    final presence = os == HostOs.windows
        ? await _presenceWindows(runtime, shell, workspace, skillsDirs)
        : await _presencePosix(runtime, shell, workspace, skillsDirs);
    if (!presence.hasAgents && !presence.hasSkills) {
      return WorkspaceSnapshot(workspace: workspace, trusted: true);
    }

    final trusted = await _settings.isTrusted(chat.hostId, workspace);
    if (!trusted) {
      return WorkspaceSnapshot(workspace: workspace, needsTrust: true);
    }

    final agentsMd = presence.agentsPath == null
        ? null
        : await _readAgents(runtime, shell, chat.hostId, presence.agentsPath!);
    final skills = presence.hasSkills
        ? await _scanSkills(runtime, shell, skillsDirs)
        : const <SkillInfo>[];
    return WorkspaceSnapshot(
      workspace: workspace,
      trusted: true,
      agentsMd: agentsMd,
      skills: skills,
    );
  }

  /// Тело skill для load_skill. Путь берётся из результата сканирования (абсолютный, без `~`).
  Future<String?> loadSkillBody(
    HostRuntime runtime,
    SkillInfo skill,
    HostOs os,
  ) async {
    final run = await captureRun(
      runtime,
      ShellAdapter(os).readHead(skill.path, maxBytes: _maxSkillBytes),
    );
    return run.ok ? run.stdout : null;
  }

  Future<_Presence> _presencePosix(
    HostRuntime runtime,
    ShellAdapter shell,
    String workspace,
    List<String> skillsDirs,
  ) async {
    final quotedWorkspace = shell.quotePath(workspace);
    // Первый найденный файл из порядка: AGENTS.md, agents.md (любой регистр), .probablyworks/AGENTS.md.
    final run = await captureRun(
      runtime,
      'W=$quotedWorkspace; '
      'for f in "\$W/AGENTS.md" "\$W"/[Aa][Gg][Ee][Nn][Tt][Ss].[Mm][Dd] "\$W/.probablyworks/AGENTS.md"; do '
      '[ -f "\$f" ] && { echo "agents=\$f"; break; }; done; '
      '${skillsDirs.map((d) => '[ -d ${shell.quotePath(d)} ] && echo skills=1; ').join()}true',
    );
    final agentsLine = run.stdout
        .split('\n')
        .where((line) => line.startsWith('agents='))
        .firstOrNull;
    final agentsPath = agentsLine == null
        ? null
        : charFrom(agentsLine, 'agents='.length).trim();
    return _Presence(
      agentsPath: agentsPath == null || agentsPath.isEmpty ? null : agentsPath,
      hasSkills: run.stdout.contains('skills=1'),
    );
  }

  /// Windows: одна PowerShell-команда проверяет наличие AGENTS.md и каталогов skills.
  Future<_Presence> _presenceWindows(
    HostRuntime runtime,
    ShellAdapter shell,
    String workspace,
    List<String> skillsDirs,
  ) async {
    final dirs = [for (final d in skillsDirs) psQuote(d)].join(',');
    final run = await captureRun(
      runtime,
      shell.powershell(
        '\$w = ${psQuote(workspace)}; '
        '\$agents = (Join-Path \$w "AGENTS.md"), (Join-Path \$w ".probablyworks/AGENTS.md") | '
        'Where-Object { Test-Path -LiteralPath \$_ -PathType Leaf } | Select-Object -First 1; '
        'if (\$agents) { Write-Output ("agents=" + \$agents) }; '
        'foreach (\$d in @($dirs)) { if (Test-Path -LiteralPath \$d -PathType Container) { Write-Output "skills=1" } }',
      ),
    );
    final agentsLine = run.stdout
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.startsWith('agents='))
        .firstOrNull;
    final agentsPath = agentsLine == null
        ? null
        : charFrom(agentsLine, 'agents='.length).trim();
    return _Presence(
      agentsPath: agentsPath == null || agentsPath.isEmpty ? null : agentsPath,
      hasSkills: run.stdout.contains('skills=1'),
    );
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
      shell.readHead(path, maxBytes: _maxAgentsBytes),
    );
    if (!run.ok) return null;
    _agentsCache[key] = (mtime: mtime, content: run.stdout);
    return run.stdout;
  }

  Future<List<SkillInfo>> _scanSkills(
    HostRuntime runtime,
    ShellAdapter shell,
    List<String> skillsDirs,
  ) async {
    final run = await captureRun(
      runtime,
      shell.scanSkills(skillsDirs, maxBytes: _maxSkillBytes),
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

class _Presence {
  const _Presence({this.agentsPath, this.hasSkills = false});

  final String? agentsPath;
  final bool hasSkills;

  bool get hasAgents => agentsPath != null;
}
