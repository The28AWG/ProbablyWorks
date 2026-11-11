import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/tools/tool_name.dart';

void main() {
  test('short names are unchanged', () {
    expect(fitToolName('read_file'), 'read_file');
  });

  test('long names fit the provider limit and stay deterministic', () {
    final first = fitToolName('mcp_${'a' * 80}');
    final second = fitToolName('mcp_${'b' * 80}');

    expect(first.length, maxToolNameLength);
    expect(second.length, maxToolNameLength);
    expect(first, fitToolName('mcp_${'a' * 80}'));
    expect(first, isNot(second));
  });
}
