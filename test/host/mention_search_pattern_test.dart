import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/host/workspace_search_pattern.dart';

void main() {
  test('rdm matches README.md as a subsequence', () {
    expect(WorkspaceSearchPattern.matches('README.md', 'rdm'), isTrue);
    expect(WorkspaceSearchPattern.glob('rdm'), '*r*d*m*');
    expect(WorkspaceSearchPattern.regex('rdm'), 'r.*d.*m');
  });

  test('path query is matched against the full relative path', () {
    expect(WorkspaceSearchPattern.matches('src/app.dart', 'src/app'), isTrue);
    expect(WorkspaceSearchPattern.matches('lib/app.dart', 'src/app'), isFalse);
    expect(WorkspaceSearchPattern.matches('src/app.dart', 'app'), isTrue);
  });

  test('hidden paths are detected by any dot segment', () {
    expect(WorkspaceSearchPattern.isHidden('.env'), isTrue);
    expect(WorkspaceSearchPattern.isHidden('src/.env'), isTrue);
    expect(WorkspaceSearchPattern.isHidden('src/app.dart'), isFalse);
    expect(WorkspaceSearchPattern.searchesHidden('.env'), isTrue);
    expect(WorkspaceSearchPattern.searchesHidden('src/.env'), isTrue);
    expect(WorkspaceSearchPattern.searchesHidden('rdm'), isFalse);
  });

  test('glob metacharacters in the query are literal', () {
    expect(WorkspaceSearchPattern.glob('a[1]'), '*a*\\[*1*\\]*');
  });

  test('noise directories are fixed', () {
    expect(WorkspaceSearchPattern.noiseDirectories, contains('.git'));
    expect(WorkspaceSearchPattern.noiseDirectories, contains('node_modules'));
    expect(WorkspaceSearchPattern.noiseDirectories, contains('build'));
  });
}
