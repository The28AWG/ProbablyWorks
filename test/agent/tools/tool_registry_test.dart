import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/agent/tools/tool_registry.dart';
import 'package:probably_works/agent/tools/tool_source.dart';
import 'package:probably_works/agent/tools/tool_types.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

final class _FakeSource extends ToolSource {
  _FakeSource(this.id, this.toolName);

  @override
  final String id;

  final String toolName;

  @override
  List<LlmToolSpec> get specs => [
    LlmToolSpec(
      name: toolName,
      description: 'fake',
      parameters: const {'type': 'object'},
    ),
  ];

  @override
  Future<ToolResult> call(
    LlmToolCall call,
    Map<String, dynamic> arguments,
    ToolContext context,
  ) async => const ToolResult('ok');
}

void main() {
  test('registry adds external specs after built-in ones', () {
    final registry = ToolRegistry();
    final source = _FakeSource('fake', 'fake_tool');
    registry.register(source);

    expect(registry.specs.first.name, ToolCatalog.specs.first.name);
    expect(registry.specs.last.name, 'fake_tool');
    expect(registry.sourceFor('fake_tool'), same(source));
    expect(registry.sourceFor(ToolNames.readFile), isNull);
  });

  test('registry rejects duplicate ids and tool names', () {
    final registry = ToolRegistry()..register(_FakeSource('fake', 'fake_tool'));

    expect(
      () => registry.register(_FakeSource('fake', 'other_tool')),
      throwsArgumentError,
    );
    expect(
      () => registry.register(_FakeSource('other', 'fake_tool')),
      throwsStateError,
    );
    expect(
      () => registry.register(_FakeSource('builtin', ToolNames.readFile)),
      throwsStateError,
    );
  });

  test('unregister removes the source and its tools', () {
    final registry = ToolRegistry()
      ..register(_FakeSource('fake', 'fake_tool'))
      ..unregister('fake');

    expect(registry.sourceFor('fake_tool'), isNull);
    expect(
      registry.specs.map((spec) => spec.name),
      isNot(contains('fake_tool')),
    );
  });
}
