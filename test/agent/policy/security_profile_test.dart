import 'package:command_shield/command_shield.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/policy/command_catalog.dart';
import 'package:pw_agent/agent/policy/command_risk.dart';
import 'package:pw_agent/agent/policy/security_profile.dart';

void main() {
  const profile = SecurityProfile();

  test('an argument replaces the command and the stricter match wins', () {
    expect(
      profile.levelFor(
        executable: 'ls',
        args: const [],
        category: KnowledgeCategory.filesystem,
      ),
      CommandRisk.auto,
    );
    expect(
      profile.levelFor(
        executable: 'sort',
        args: const ['-ofile'],
        category: KnowledgeCategory.filesystem,
      ),
      CommandRisk.ask,
    );
    expect(
      profile.levelFor(
        executable: 'git',
        args: const ['status'],
        category: KnowledgeCategory.versionControl,
      ),
      CommandRisk.auto,
    );
    expect(
      profile.levelFor(
        executable: 'git',
        args: const ['commit'],
        category: KnowledgeCategory.versionControl,
      ),
      CommandRisk.ask,
    );
    final both = profile.withArgument(
      const ArgumentRuleConfig(
        executable: 'sort',
        kind: ArgumentMatchKind.flag,
        token: '-n',
        risk: CommandRisk.deny,
      ),
    );
    expect(
      both.levelFor(
        executable: 'sort',
        args: const ['-n', '-o', 'out'],
        category: KnowledgeCategory.filesystem,
      ),
      CommandRisk.deny,
    );
  });

  test('unknown commands ask and a command replaces its category', () {
    expect(
      profile.levelFor(executable: 'nope', args: const [], category: null),
      CommandRisk.ask,
    );
    final raised = profile.withCategory(
      KnowledgeCategory.filesystem,
      CommandRisk.deny,
    );
    expect(
      raised.levelFor(
        executable: 'mkdir',
        args: const ['a'],
        category: KnowledgeCategory.filesystem,
      ),
      CommandRisk.deny,
    );
    expect(
      raised
          .withCommand('mkdir', CommandRisk.auto)
          .levelFor(
            executable: 'mkdir',
            args: const ['a'],
            category: KnowledgeCategory.filesystem,
          ),
      CommandRisk.auto,
    );
  });

  test('json round-trips and a bad document stays at the baseline', () {
    final changed = profile
        .withCategory(KnowledgeCategory.network, CommandRisk.deny)
        .withCommand('ls', CommandRisk.deny)
        .withoutCommand('cat');
    expect(SecurityProfile.decode(changed.encode()), changed);
    expect(SecurityProfile.decode('nope'), profile);
    expect(SecurityProfile.decode('{"version": 2}'), profile);
  });

  test('restoring a category leaves the other categories alone', () {
    final names = CommandCatalog.instance
        .namesIn(KnowledgeCategory.filesystem)
        .toSet();
    final changed = profile
        .withCategory(KnowledgeCategory.filesystem, CommandRisk.deny)
        .withCategory(KnowledgeCategory.network, CommandRisk.deny)
        .withCommand('ls', CommandRisk.deny)
        .withCommand('curl', CommandRisk.deny);
    final restored = changed.restoreCategory(
      KnowledgeCategory.filesystem,
      names,
    );

    expect(restored.categories[KnowledgeCategory.filesystem], CommandRisk.ask);
    expect(restored.categories[KnowledgeCategory.network], CommandRisk.deny);
    expect(restored.commands['ls'], CommandRisk.auto);
    expect(restored.commands['curl'], CommandRisk.deny);
  });
}
