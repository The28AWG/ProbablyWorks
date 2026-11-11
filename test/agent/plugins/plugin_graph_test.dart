import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_api/plugin_api.dart';
import 'package:probably_works/agent/plugins/plugin_graph.dart';

final class _FakePlugin implements Plugin {
  const _FakePlugin(this.id, {this.dependsOn = const {}});

  @override
  final String id;

  @override
  final Set<String> dependsOn;

  @override
  bool get defaultEnabled => true;

  @override
  LocalizationsDelegate<dynamic> get localizations =>
      DefaultWidgetsLocalizations.delegate;

  @override
  Widget? buildSettings(BuildContext context, PluginSettings settings) => null;

  @override
  String descriptionOf(BuildContext context) => id;

  @override
  String titleOf(BuildContext context) => id;

  @override
  Future<List<PluginTool>> createTools(PluginSettings settings) async =>
      const [];
}

void main() {
  const a = _FakePlugin('a');
  const b = _FakePlugin('b', dependsOn: {'a'});
  const c = _FakePlugin('c', dependsOn: {'b'});
  const d = _FakePlugin('d');
  final graph = PluginGraph([a, b, c, d]);

  test('finds transitive missing dependencies', () {
    expect(graph.missingDependencies('c', const {}), {'a', 'b'});
    expect(graph.missingDependencies('c', const {'a'}), {'b'});
    expect(graph.missingDependencies('c', const {'a', 'b'}), isEmpty);
    expect(graph.missingDependencies('d', const {}), isEmpty);
  });

  test('finds transitive dependents among enabled plugins', () {
    expect(graph.dependents('a', const {'a', 'b', 'c', 'd'}), {'b', 'c'});
    expect(graph.dependents('b', const {'a', 'b', 'c', 'd'}), {'c'});
    expect(graph.dependents('d', const {'a', 'b', 'c', 'd'}), isEmpty);
  });
}
