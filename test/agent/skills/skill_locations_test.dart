import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/skills/skill_locations.dart';

void main() {
  test('app directory goes first and every workspace path is unique', () {
    final paths = SkillLocations.forWorkspace('/ws');

    expect(paths.first, '/ws/.probablyworks/skills');
    expect(paths, contains('/ws/.claude/skills'));
    expect(paths, contains('/ws/.opencode/skills'));
    expect(paths.toSet(), hasLength(paths.length));
  });
}
