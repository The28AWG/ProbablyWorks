import 'package:probably_works/agent/workspace/workspace_context_loader.dart';

/// Скилл, который поставляется с приложением. Это не файл на Host, поэтому он не зависит от доверия workspace.
class BuiltinSkill {
  const BuiltinSkill({
    required this.name,
    required this.description,
    required this.body,
  });

  final String name;

  /// Одна строка для каталога: по ней модель решает, загружать ли скилл.
  final String description;

  /// Инструкции, которые получает модель после load_skill.
  final String body;
}

abstract final class BuiltinSkills {
  const BuiltinSkills._();

  static const _pathPrefix = 'builtin:';

  static const probablyWorks = BuiltinSkill(
    name: 'probablyworks',
    description:
        'Use when the user asks to view, add or rename hosts (хосты), host notes, '
        'or to view or change ProbablyWorks app settings (язык, модели, лимиты, шаги). '
        'Not for commands or files on the remote machine.',
    body: '''
You manage ProbablyWorks itself: its hosts, host notes and app settings. These are not the machines your shell commands run on.

Tools available now:
- host_list: list hosts with ids, notes, default workspace and last check result. Call it before changing anything.
- host_add: add an SSH host (only ssh kind).
- host_update: rename a host, replace its notes, or change its default workspace. Other host fields are changed on the Hosts page.
- host_test: quick connection check of a host.
- host_diagnose: step-by-step connection diagnostics of a host.
- settings_read: read the app settings you may change.
- settings_update: change one setting by its key.

Rules:
- Writes (host_add, host_update, settings_update) may show an approval card to the user. Say what you are going to change before calling them.
- Never ask for, print or store passwords, passphrases or private keys in the chat. If a host needs one, tell the user to enter it on the Hosts page.
- keyPath: pass the path exactly as the user wrote it, including ~. Do not search for keys and do not expand ~ yourself. If you found a path on your own, say so: the user will be asked to approve it.
- host_update replaces the whole notes text. Read the current notes with host_list first and keep what must stay.
- If a host key changed or is unknown, tell the user to check the host on the Hosts page. Never try to accept a host key yourself.
- Answer in the user's language.
''',
  );

  static const all = [probablyWorks];

  static BuiltinSkill? byName(String name) =>
      all.where((skill) => skill.name == name).firstOrNull;

  /// Каталог для модели: встроенные скиллы всегда, workspace-скилл с тем же именем скрывается.
  static List<SkillInfo> catalog(List<SkillInfo> workspace) => [
    for (final skill in all)
      SkillInfo(
        name: skill.name,
        description: skill.description,
        path: '$_pathPrefix${skill.name}',
      ),
    for (final skill in workspace)
      if (byName(skill.name) == null) skill,
  ];
}
