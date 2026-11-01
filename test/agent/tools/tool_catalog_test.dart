import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';

void main() {
  test('get_state_revision is exposed and requires the revision id', () {
    final spec = ToolCatalog.specs.firstWhere(
      (s) => s.name == ToolNames.getStateRevision,
    );
    expect(spec.parameters['required'], contains('id'));
  });

  test('write_file documents the per-run backup naming', () {
    final spec = ToolCatalog.specs.firstWhere(
      (s) => s.name == ToolNames.writeFile,
    );
    expect(spec.description, contains('.pw-bak-'));
  });
}
