import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/domain/session_state.dart';

void main() {
  final now = DateTime(2026, 11, 4);

  test('fork inherits unlocked skills as an independent copy', () {
    final root = SessionStateRevision(id: 'r1', chatId: 'c1', createdAt: now)
      ..unlockedSkills.add('probablyworks');
    final child = root.forkInto(newId: 'r2', triggeredBy: 'm1', at: now);

    expect(child.unlockedSkills, {'probablyworks'});
    child.unlockedSkills.clear();
    expect(root.unlockedSkills, {'probablyworks'});
  });

  test('unlocked skills survive a state json round trip', () {
    final rev = SessionStateRevision(id: 'r1', chatId: 'c1', createdAt: now)
      ..unlockedSkills.add('probablyworks');
    final restored = SessionStateRevision(
      id: 'r1',
      chatId: 'c1',
      createdAt: now,
    )..applyStateJson(rev.stateToJson());

    expect(restored.unlockedSkills, {'probablyworks'});
  });

  test('state json without the field means nothing is unlocked', () {
    final rev = SessionStateRevision(id: 'r1', chatId: 'c1', createdAt: now)
      ..applyStateJson({'goal': null, 'taskStatus': 'idle'});

    expect(rev.unlockedSkills, isEmpty);
  });
}
