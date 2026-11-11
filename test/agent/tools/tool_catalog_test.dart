import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';

void main() {
  test('get_state_revision is exposed and requires the revision id', () {
    final spec = ToolCatalog.specs.firstWhere(
      (s) => s.name == ToolNames.getStateRevision,
    );
    expect(spec.parameters['required'], contains('id'));
  });

  test('write_file documents turn rollback storage', () {
    final spec = ToolCatalog.specs.firstWhere(
      (s) => s.name == ToolNames.writeFile,
    );
    expect(spec.description, contains('rollback'));
  });
}
